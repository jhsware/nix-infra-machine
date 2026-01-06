# CrowdSec Firewall Bouncer Module
# Provides firewall-level IP blocking using iptables/nftables/ipset
{ config, pkgs, lib, ... }:

let
  appName = "crowdsec";
  cfg = config.infrastructure.${appName};
  stateDir = "/var/lib/crowdsec";
  yamlFormat = pkgs.formats.yaml {};
in
{
  # ==========================================================================
  # Options
  # ==========================================================================
  options.infrastructure.${appName} = {
    features.firewallBouncer = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Enable the firewall bouncer to automatically block malicious IPs.
        
        The bouncer fetches decisions from the CrowdSec API and applies
        them to the system firewall (iptables/nftables). Available in
        nixpkgs as pkgs.crowdsec-firewall-bouncer starting from NixOS 25.11.
        
        When using nftables mode (default), the module creates declarative
        nftables tables that integrate properly with NixOS's firewall and
        survive system rebuilds.
        
        [NIS2 COMPLIANCE]
        Article 21(2)(b) - Incident Handling: Provides automated incident
        response by blocking identified threats in real-time.
        
        Article 21(2)(d) - Network Security: Implements active network
        protection through automated firewall rule management.
      '';
      default = false;
    };

    bouncer = {
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        description = ''
          CrowdSec firewall bouncer package to use.
          
          The package is available in nixpkgs as pkgs.crowdsec-firewall-bouncer
          starting from NixOS 25.11.
          
          Set to null to disable the bouncer even when features.firewallBouncer
          is enabled (useful for testing detection without blocking).
        '';
        default = pkgs.crowdsec-firewall-bouncer or null;
        defaultText = lib.literalExpression "pkgs.crowdsec-firewall-bouncer";
        example = lib.literalExpression "pkgs.crowdsec-firewall-bouncer";
      };

      mode = lib.mkOption {
        type = lib.types.enum [ "iptables" "nftables" "ipset" ];
        description = ''
          Firewall mode for the bouncer.
          
          - "nftables": Recommended for NixOS. Uses nftables sets which integrate
            well with NixOS declarative firewall. The module creates the necessary
            tables/chains declaratively, and the bouncer only manages set membership.
          
          - "iptables": Traditional iptables rules. May conflict with NixOS firewall
            on system rebuilds.
          
          - "ipset": Uses ipset for IP blocking. More compatible with iptables-based
            firewalls and survives rule flushes better.
          
          [NIS2 COMPLIANCE]
          All modes provide equivalent security protection. Choose based on your
          existing firewall infrastructure.
        '';
        default = "nftables";
      };

      nftablesIntegration = lib.mkOption {
        type = lib.types.bool;
        description = ''
          When using nftables mode, declaratively create the CrowdSec table
          structure in NixOS configuration. This ensures the tables/chains
          survive NixOS rebuilds and prevents conflicts with the declarative
          firewall.
          
          When enabled:
          - Creates "crowdsec" and "crowdsec6" tables declaratively
          - Configures bouncer in "set-only" mode
          - Bouncer only manages IP set membership, not table structure
          
          When disabled:
          - Bouncer creates and manages its own tables
          - May conflict with NixOS firewall rebuilds
        '';
        default = true;
      };

      denyAction = lib.mkOption {
        type = lib.types.enum [ "DROP" "REJECT" ];
        description = ''
          Action to take for blocked IPs.
          
          - "DROP": Silently drop packets (recommended for security)
          - "REJECT": Send rejection response to client
          
          DROP is generally preferred as it doesn't reveal firewall presence.
        '';
        default = "DROP";
      };

      denyLog = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Log blocked connections before dropping/rejecting.
          
          [NIS2 COMPLIANCE]
          Article 21(2)(g) - Security Monitoring: Maintains audit trail
          of blocked threats for incident analysis and reporting.
        '';
        default = true;
      };

      denyLogPrefix = lib.mkOption {
        type = lib.types.str;
        description = "Prefix for firewall log entries.";
        default = "crowdsec: ";
      };

      banDuration = lib.mkOption {
        type = lib.types.str;
        description = ''
          Default ban duration for blocked IPs.
          
          Format: Go duration string (e.g., "4h", "24h", "7d")
        '';
        default = "4h";
        example = "24h";
      };
    };
  };

  # ==========================================================================
  # Configuration
  # ==========================================================================
  config = lib.mkIf (cfg.enable && cfg.features.firewallBouncer && cfg.bouncer.package != null) (
    let
      useNftablesIntegration = cfg.bouncer.mode == "nftables" && cfg.bouncer.nftablesIntegration;

      # Bouncer config - uses set-only mode when nftablesIntegration is enabled
      bouncerConfigFile = yamlFormat.generate "crowdsec-firewall-bouncer.yaml" ({
        mode = cfg.bouncer.mode;
        update_frequency = "10s";
        api_url = "http://${cfg.api.listenAddr}:${toString cfg.api.listenPort}/";
        api_key = "\${BOUNCER_API_KEY}";
        disable_ipv6 = false;
        deny_action = cfg.bouncer.denyAction;
        deny_log = cfg.bouncer.denyLog;
        deny_log_prefix = cfg.bouncer.denyLogPrefix;
      } // lib.optionalAttrs (cfg.bouncer.mode == "nftables") {
        nftables = {
          ipv4 = {
            enabled = true;
            set-only = useNftablesIntegration;
            table = "crowdsec";
            chain = "crowdsec-chain";
            set = "crowdsec-blocklist";
          };
          ipv6 = {
            enabled = true;
            set-only = useNftablesIntegration;
            table = "crowdsec6";
            chain = "crowdsec6-chain";
            set = "crowdsec6-blocklist";
          };
        };
      } // lib.optionalAttrs (cfg.bouncer.mode == "iptables") {
        iptables_chains = [ "INPUT" "FORWARD" ];
      } // lib.optionalAttrs (cfg.bouncer.mode == "ipset") {
        ipset_type = "nethash";
        ipset = "crowdsec-blocklist";
        ipset6 = "crowdsec6-blocklist";
      });

      bouncerRegisterScript = pkgs.writeShellScript "crowdsec-bouncer-register" ''
        set -e
        export PATH="${lib.makeBinPath [ cfg.package pkgs.coreutils pkgs.gnugrep pkgs.gnused ]}:$PATH"
        
        CONFIG_DIR="${stateDir}/config"
        KEY_FILE="/var/lib/crowdsec-firewall-bouncer/api_key"
        
        # Wait for CrowdSec API to be ready
        for i in $(seq 1 60); do
          if cscli -c "$CONFIG_DIR/config.yaml" bouncers list >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        
        # Check if bouncer already registered
        if ! cscli -c "$CONFIG_DIR/config.yaml" bouncers list 2>/dev/null | grep -q "firewall-bouncer"; then
          # Register new bouncer and save key
          KEY=$(cscli -c "$CONFIG_DIR/config.yaml" bouncers add firewall-bouncer -o raw 2>/dev/null || echo "")
          if [ -n "$KEY" ]; then
            echo "$KEY" > "$KEY_FILE"
            chmod 600 "$KEY_FILE"
          fi
        fi
        
        # Read existing key
        if [ -f "$KEY_FILE" ]; then
          export BOUNCER_API_KEY=$(cat "$KEY_FILE")
        fi
        
        # Generate config with key substituted
        # Use | as sed delimiter since API keys may contain /
        if [ -n "$BOUNCER_API_KEY" ]; then
          sed "s|\''${BOUNCER_API_KEY}|$BOUNCER_API_KEY|g" ${bouncerConfigFile} > /var/lib/crowdsec-firewall-bouncer/config.yaml
        fi
      '';

    in lib.mkMerge [
      # Assertions
      {
        assertions = [
          {
            assertion = cfg.bouncer.package != null;
            message = ''
              CrowdSec firewall bouncer is enabled but no package is configured.
              
              The bouncer package should be available as pkgs.crowdsec-firewall-bouncer
              on NixOS 25.11+. If using an older NixOS version, you may need to:
              
              1. Upgrade to NixOS 25.11+
              2. Set infrastructure.crowdsec.features.firewallBouncer = false
              3. Provide the package from an external source
            '';
          }
        ];

        # Install CLI tools based on mode
        environment.systemPackages = 
          lib.optionals (cfg.bouncer.mode == "nftables") [ pkgs.nftables ]
          ++ lib.optionals (cfg.bouncer.mode == "iptables") [ pkgs.iptables ]
          ++ lib.optionals (cfg.bouncer.mode == "ipset") [ pkgs.ipset ];
      }

      # Declarative nftables Integration
      (lib.mkIf useNftablesIntegration {
        networking.nftables.enable = true;
        
        networking.nftables.tables = {
          # IPv4 CrowdSec table
          crowdsec = {
            family = "ip";
            content = ''
              set crowdsec-blocklist {
                type ipv4_addr
                flags timeout
              }
              
              chain crowdsec-chain {
                type filter hook input priority -1; policy accept;
                ${lib.optionalString cfg.bouncer.denyLog ''
                ip saddr @crowdsec-blocklist log prefix "${cfg.bouncer.denyLogPrefix}" 
                ''}
                ip saddr @crowdsec-blocklist ${lib.toLower cfg.bouncer.denyAction}
              }
            '';
          };
          
          # IPv6 CrowdSec table
          crowdsec6 = {
            family = "ip6";
            content = ''
              set crowdsec6-blocklist {
                type ipv6_addr
                flags timeout
              }
              
              chain crowdsec6-chain {
                type filter hook input priority -1; policy accept;
                ${lib.optionalString cfg.bouncer.denyLog ''
                ip6 saddr @crowdsec6-blocklist log prefix "${cfg.bouncer.denyLogPrefix}" 
                ''}
                ip6 saddr @crowdsec6-blocklist ${lib.toLower cfg.bouncer.denyAction}
              }
            '';
          };
        };
      })

      # Tmpfiles and service
      {
        systemd.tmpfiles.rules = [
          "d /var/lib/crowdsec-firewall-bouncer 0750 root root - -"
        ];

        # Firewall bouncer service
        systemd.services.crowdsec-firewall-bouncer = {
          description = "CrowdSec Firewall Bouncer";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "crowdsec.service" ];
          requires = [ "crowdsec.service" ];
          
          path = lib.optionals (cfg.bouncer.mode == "iptables") [ pkgs.iptables pkgs.ipset ];
          
          serviceConfig = {
            Type = "simple";
            ExecStartPre = "${bouncerRegisterScript}";
            ExecStart = "${cfg.bouncer.package}/bin/cs-firewall-bouncer -c /var/lib/crowdsec-firewall-bouncer/config.yaml";
            Restart = "always";
            RestartSec = "10s";
          };
        };
      }
    ]
  );
}
