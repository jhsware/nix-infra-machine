# CrowdSec HAProxy SPOA Bouncer Module
# Provides application-layer protection via HAProxy Stream Processing Offload API
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
    features.haproxyProtection = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Enable HAProxy security integration via SPOA (Stream Processing Offload API).
        
        The cs-haproxy-spoa-bouncer acts as a stream processing agent that checks
        each connection in real-time against CrowdSec's decision database before
        allowing traffic to reach your application servers.
        
        This provides layer 7 application-level protection, complementing the
        layer 3/4 protection from the firewall bouncer.
        
        [NIS2 COMPLIANCE]
        Article 21(2)(d) - Network Security: Provides application-layer protection
        for HTTP/HTTPS traffic through HAProxy integration.
        
        Article 21(2)(e) - Supply Chain Security: Protects web applications that
        may be part of the digital supply chain.
      '';
      default = false;
    };

    haproxy = {
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        description = ''
          CrowdSec HAProxy SPOA bouncer package to use.
          
          The package should be available as pkgs.cs-haproxy-spoa-bouncer.
          Set to null to disable the bouncer even when features.haproxyProtection
          is enabled.
        '';
        default = pkgs.cs-haproxy-spoa-bouncer or null;
        defaultText = lib.literalExpression "pkgs.cs-haproxy-spoa-bouncer";
        example = lib.literalExpression "pkgs.cs-haproxy-spoa-bouncer";
      };

      listenAddr = lib.mkOption {
        type = lib.types.str;
        description = ''
          Address for the SPOA bouncer to listen on.
          HAProxy will connect to this address to check decisions.
        '';
        default = "127.0.0.1";
        example = "0.0.0.0";
      };

      listenPort = lib.mkOption {
        type = lib.types.port;
        description = "Port for the SPOA bouncer to listen on.";
        default = 3000;
        example = 3000;
      };

      action = lib.mkOption {
        type = lib.types.enum [ "deny" "tarpit" ];
        description = ''
          Action to take for blocked requests in HAProxy.
          
          - "deny": Immediately reject the connection
          - "tarpit": Slow down the connection (tar pit)
        '';
        default = "deny";
      };

      logLevel = lib.mkOption {
        type = lib.types.enum [ "error" "warning" "info" "debug" ];
        description = "Log level for the SPOA bouncer.";
        default = "info";
      };
    };
  };

  # ==========================================================================
  # Configuration
  # ==========================================================================
  config = lib.mkIf (cfg.enable && cfg.features.haproxyProtection && cfg.haproxy.package != null) (
    let
      # HAProxy SPOA bouncer config file
      haproxyBouncerConfigFile = yamlFormat.generate "crowdsec-haproxy-spoa-bouncer.yaml" {
        lapi_url = "http://${cfg.api.listenAddr}:${toString cfg.api.listenPort}";
        lapi_key = "\${HAPROXY_SPOA_API_KEY}";
        action = cfg.haproxy.action;
        log_level = cfg.haproxy.logLevel;
        listen_addr = cfg.haproxy.listenAddr;
        listen_port = cfg.haproxy.listenPort;
        update_frequency = "10s";
      };

      haproxyBouncerRegisterScript = pkgs.writeShellScript "crowdsec-haproxy-bouncer-register" ''
        set -e
        export PATH="${lib.makeBinPath [ cfg.package pkgs.coreutils pkgs.gnugrep pkgs.gnused ]}:$PATH"
        
        CONFIG_DIR="${stateDir}/config"
        KEY_FILE="/var/lib/crowdsec-haproxy-bouncer/api_key"
        
        # Wait for CrowdSec API to be ready
        for i in $(seq 1 60); do
          if cscli -c "$CONFIG_DIR/config.yaml" bouncers list >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        
        # Check if bouncer already registered
        if ! cscli -c "$CONFIG_DIR/config.yaml" bouncers list 2>/dev/null | grep -q "haproxy-spoa-bouncer"; then
          # Register new bouncer and save key
          KEY=$(cscli -c "$CONFIG_DIR/config.yaml" bouncers add haproxy-spoa-bouncer -o raw 2>/dev/null || echo "")
          if [ -n "$KEY" ]; then
            echo "$KEY" > "$KEY_FILE"
            chmod 600 "$KEY_FILE"
          fi
        fi
        
        # Read existing key
        if [ -f "$KEY_FILE" ]; then
          export HAPROXY_SPOA_API_KEY=$(cat "$KEY_FILE")
        fi
        
        # Generate config with key substituted
        # Use | as sed delimiter since API keys may contain /
        if [ -n "$HAPROXY_SPOA_API_KEY" ]; then
          sed "s|\''${HAPROXY_SPOA_API_KEY}|$HAPROXY_SPOA_API_KEY|g" ${haproxyBouncerConfigFile} > /var/lib/crowdsec-haproxy-bouncer/config.yaml
        fi
      '';

    in {
      # Assertions
      assertions = [
        {
          assertion = cfg.haproxy.package != null;
          message = ''
            CrowdSec HAProxy SPOA bouncer is enabled but no package is configured.
            
            The bouncer package should be available as pkgs.cs-haproxy-spoa-bouncer.
            If the package is not available, you may need to:
            
            1. Set infrastructure.crowdsec.features.haproxyProtection = false
            2. Provide the package from an external source
          '';
        }
      ];

      # Tmpfiles
      systemd.tmpfiles.rules = [
        "d /var/lib/crowdsec-haproxy-bouncer 0750 root root - -"
      ];

      # HAProxy SPOA bouncer service
      systemd.services.crowdsec-haproxy-bouncer = {
        description = "CrowdSec HAProxy SPOA Bouncer";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "crowdsec.service" ];
        requires = [ "crowdsec.service" ];

        serviceConfig = {
          Type = "simple";
          ExecStartPre = "${haproxyBouncerRegisterScript}";
          ExecStart = "${cfg.haproxy.package}/bin/cs-haproxy-spoa-bouncer -c /var/lib/crowdsec-haproxy-bouncer/config.yaml";
          Restart = "always";
          RestartSec = "10s";
        };
      };
    }
  );
}
