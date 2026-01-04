{ config, pkgs, lib, options, ... }:

let
  appName = "crowdsec";
  cfg = config.infrastructure.${appName};

  # ==========================================================================
  # Version Detection (must not depend on cfg to avoid recursion)
  # ==========================================================================
  # Check if the native services.crowdsec module exists (NixOS 25.11+)
  hasNativeCrowdsecModule = options ? services && options.services ? crowdsec;

  # The native module in NixOS 25.11 has multiple bugs that make it unusable:
  # - #445342: Missing sensible defaults, API server disabled by default
  # - #446764: Console enrollment broken
  # - #459224: Cannot enable local API
  # - Missing hub.postoverflows, hub.scenarios, hub.parsers options
  # - Null coercion errors in systemd service generation
  #
  # We mark the native module as unstable until these are fixed.
  # Users can override with implementation = "native" to test.
  nativeModuleIsStable = false;

  # State directory for CrowdSec
  stateDir = "/var/lib/crowdsec";

  # Helper to generate YAML format
  yamlFormat = pkgs.formats.yaml {};

in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption ''
      CrowdSec - Collaborative Intrusion Prevention System.
      
      CrowdSec is an open-source security automation tool that detects and blocks
      malicious behavior by analyzing logs and sharing threat intelligence with
      the community.
      
      This module provides simplified boolean feature toggles for common use cases
      and can use either a custom implementation or the native NixOS module.
      
      [NIS2 COMPLIANCE]
      Article 21(2)(b) - Incident Handling: CrowdSec provides automated threat
      detection and response capabilities, helping organizations meet requirements
      for detecting, analyzing, and responding to cybersecurity incidents.
      
      Article 21(2)(d) - Network Security: Acts as an Intrusion Detection/Prevention
      System (IDS/IPS), a core requirement for protecting network infrastructure.
    '';

    implementation = lib.mkOption {
      type = lib.types.enum [ "auto" "native" "custom" ];
      description = ''
        Which implementation to use for CrowdSec.
        
        - "auto": Automatically select based on NixOS version and module stability.
          Currently defaults to "custom" because the native module has bugs.
        - "native": Force use of NixOS's native services.crowdsec module.
          Requires NixOS 25.11+. May have bugs - use for testing only.
        - "custom": Use the custom implementation that manages its own systemd
          service. Works on all NixOS versions with the crowdsec package.
        
        The native module in NixOS 25.11 has several known issues:
        - #445342: Missing sensible defaults
        - #446764: Console enrollment broken
        - #459224: Cannot enable local API
        
        When these are fixed, "auto" will switch to using the native module.
      '';
      default = "auto";
      example = "custom";
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "CrowdSec package to use.";
      default = pkgs.crowdsec;
      defaultText = lib.literalExpression "pkgs.crowdsec";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "trace" "debug" "info" "warning" "error" "fatal" ];
      description = ''
        Log level for CrowdSec.
        
        [NIS2 COMPLIANCE]
        Article 21(2)(g) - Security Monitoring: Appropriate logging level
        enables proper security event monitoring and incident investigation.
      '';
      default = "info";
      example = "debug";
    };

    # ==========================================================================
    # API Configuration
    # ==========================================================================

    api = {
      listenAddr = lib.mkOption {
        type = lib.types.str;
        description = ''
          Address for the CrowdSec Local API (LAPI) to listen on.
          Use "127.0.0.1" for local-only access or "0.0.0.0" for network access.
        '';
        default = "127.0.0.1";
        example = "0.0.0.0";
      };

      listenPort = lib.mkOption {
        type = lib.types.port;
        description = "Port for the CrowdSec Local API (LAPI) to listen on.";
        default = 8080;
        example = 8080;
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether to open the firewall port for the CrowdSec API.
          Only needed if bouncers from other machines need to connect.
        '';
        default = false;
      };
    };

    # ==========================================================================
    # Feature Toggles (Simple Boolean Options)
    # ==========================================================================

    features = {
      sshProtection = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Enable SSH brute-force detection and prevention.
          
          Monitors SSH authentication logs to detect and block IP addresses
          attempting password guessing or credential stuffing attacks.
          
          [NIS2 COMPLIANCE]
          Article 21(2)(i) - Human Resources Security: Protects authentication
          systems and helps prevent unauthorized access attempts.
          
          Article 21(2)(j) - Access Control: Provides automated protection
          against credential-based attacks on administrative interfaces.
        '';
        default = true;
      };

      nginxProtection = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Enable nginx/web server attack detection.
          
          Monitors nginx access and error logs to detect web-based attacks
          including SQL injection, XSS, path traversal, and more.
          
          [NIS2 COMPLIANCE]
          Article 21(2)(d) - Network Security: Provides web application
          firewall (WAF) capabilities to protect public-facing services.
          
          Article 21(2)(e) - Supply Chain Security: Helps protect web
          services that may be part of the digital supply chain.
        '';
        default = false;
      };

      nginxLogPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Paths to nginx log files to monitor.";
        default = [ "/var/log/nginx/*.log" ];
        example = [ "/var/log/nginx/access.log" "/var/log/nginx/error.log" ];
      };

      systemProtection = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Enable system/kernel-level threat detection.
          
          Monitors kernel and system logs for suspicious activity including
          privilege escalation attempts and system abuse.
          
          [NIS2 COMPLIANCE]
          Article 21(2)(a) - Risk Analysis: Provides continuous monitoring
          to identify and respond to system-level threats.
          
          Article 21(2)(g) - Security Monitoring: Implements comprehensive
          security monitoring across the system infrastructure.
        '';
        default = false;
      };

      firewallBouncer = lib.mkOption {
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


      communityBlocklists = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Enable community-contributed IP blocklists.
          
          When enrolled in the CrowdSec Console, your instance can receive
          curated blocklists of known malicious IPs from the community.
          
          [NIS2 COMPLIANCE]
          Article 21(2)(d) - Network Security: Leverages collective threat
          intelligence to proactively block known attackers.
          
          Article 14 - Information Sharing: Participates in cybersecurity
          information sharing to improve collective defense.
        '';
        default = true;
      };
    };

    # ==========================================================================
    # Console Enrollment (Optional)
    # ==========================================================================

    console = {
      enrollKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = ''
          Path to file containing the CrowdSec Console enrollment key.
          
          Enrolling connects your instance to the CrowdSec Console for:
          - Centralized monitoring and management
          - Access to community and commercial blocklists
          - Threat intelligence dashboards
          
          Get your enrollment key from: https://app.crowdsec.net/
          
          [NIS2 COMPLIANCE]
          Article 21(2)(g) - Security Monitoring: Provides centralized
          visibility into security events across infrastructure.
          
          Article 23 - Reporting: Facilitates incident documentation
          and reporting through centralized logging.
        '';
        default = null;
        example = "/run/secrets/crowdsec-enroll-key";
      };

      shareDecisions = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Share your detected threats with the CrowdSec community.
          
          When enabled, anonymized attack signals are shared to improve
          collective threat intelligence for all CrowdSec users.
          
          [NIS2 COMPLIANCE]
          Article 14 - Information Sharing: Contributes to EU-wide
          cybersecurity by participating in threat intelligence sharing.
        '';
        default = true;
      };
    };

    # ==========================================================================
    # Hub Configuration (Parsers, Scenarios, Collections)
    # ==========================================================================

    hub = {
      collections = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          Additional CrowdSec Hub collections to install.
          
          Collections bundle related parsers and scenarios together.
          Browse available collections at: https://hub.crowdsec.net/
        '';
        default = [];
        example = [ "crowdsecurity/apache2" "crowdsecurity/postfix" ];
      };

      scenarios = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          Additional CrowdSec Hub scenarios to install.
          
          Scenarios define detection rules for specific attack patterns.
        '';
        default = [];
        example = [ "crowdsecurity/http-bf-wordpress_bf" ];
      };

      parsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          Additional CrowdSec Hub parsers to install.
          
          Parsers extract structured data from log files.
        '';
        default = [];
        example = [ "crowdsecurity/docker-logs" ];
      };

      postoverflows = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Additional post-overflow parsers to install.";
        default = [];
        example = [ "crowdsecurity/cdn-whitelist" ];
      };
    };

    # ==========================================================================
    # Custom Acquisitions
    # ==========================================================================

    acquisitions = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      description = ''
        Additional log sources for CrowdSec to monitor.
        
        Each acquisition defines a log source (file, journalctl, etc.)
        and the parser type to use.
        
        [NIS2 COMPLIANCE]
        Article 21(2)(g) - Security Monitoring: Enables comprehensive
        log collection and monitoring across all systems.
      '';
      default = [];
      example = lib.literalExpression ''
        [
          {
            source = "journalctl";
            journalctl_filter = [ "_SYSTEMD_UNIT=postgresql.service" ];
            labels.type = "syslog";
          }
          {
            filenames = [ "/var/log/myapp/*.log" ];
            labels.type = "syslog";
          }
        ]
      '';
    };

    # ==========================================================================
    # Firewall Bouncer Configuration
    # ==========================================================================

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


    # ==========================================================================
    # Pass-through Configuration
    # ==========================================================================

    extraSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = ''
        Extra settings merged into the CrowdSec configuration.
        For native implementation: merged into services.crowdsec.settings.
        For custom implementation: merged into the generated config.yaml.
      '';
      default = {};
    };

    extraLocalConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = ''
        Extra settings merged into the local configuration.
        For native implementation: merged into services.crowdsec.localConfig.
        For custom implementation: not currently used.
      '';
      default = {};
    };
  };

  # ==========================================================================
  # Configuration
  # ==========================================================================
  config = lib.mkIf cfg.enable (
    let
      # ========================================================================
      # All cfg-dependent values MUST be defined inside this let block
      # to avoid infinite recursion during module evaluation
      # ========================================================================

      # Determine which implementation to use
      useNativeImplementation = 
        if cfg.implementation == "native" then true
        else if cfg.implementation == "custom" then false
        else if cfg.implementation == "auto" then 
          hasNativeCrowdsecModule && nativeModuleIsStable
        else false;

      # Build acquisitions list based on enabled features
      acquisitions = lib.flatten [
        # SSH acquisition (journalctl-based)
        (lib.optional cfg.features.sshProtection {
          source = "journalctl";
          journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
          labels.type = "syslog";
        })
        # Nginx acquisition (log file-based)
        (lib.optional cfg.features.nginxProtection {
          filenames = cfg.features.nginxLogPaths;
          labels.type = "nginx";
        })
        # System/kernel logs acquisition
        (lib.optional cfg.features.systemProtection {
          source = "journalctl";
          journalctl_filter = [ "_TRANSPORT=kernel" ];
          labels.type = "syslog";
        })
        # Custom acquisitions from user
        cfg.acquisitions
      ];

      # Build hub collections list based on enabled features
      hubCollections = lib.flatten [
        (lib.optional cfg.features.sshProtection "crowdsecurity/sshd")
        (lib.optional cfg.features.nginxProtection "crowdsecurity/nginx")
        (lib.optional cfg.features.systemProtection "crowdsecurity/linux")
        cfg.hub.collections
      ];

      # ========================================================================
      # Custom Implementation: Configuration Files
      # ========================================================================
      
      # Generate acquisitions file as multi-document YAML
      # CrowdSec expects each acquisition as a separate YAML document (separated by ---)
      # We use yamlFormat.generate for each acquisition and concatenate them
      acquisitionsFile = pkgs.writeText "acquisitions.yaml" (
        lib.concatMapStringsSep "\n---\n" (acq: 
          builtins.readFile (yamlFormat.generate "acq.yaml" acq)
        ) acquisitions
      );

      # Generate simulation file (CrowdSec requires this)
      simulationFile = yamlFormat.generate "simulation.yaml" {
        simulation = false;
        exclusions = [];
      };

      # Generate main config file (compatible with CrowdSec 1.7.x)
      configFile = yamlFormat.generate "config.yaml" {
        common = {
          daemonize = false;
          log_media = "stdout";
          log_level = cfg.logLevel;
        };
        config_paths = {
          config_dir = "${stateDir}/config";
          data_dir = "${stateDir}/data";
          hub_dir = "${stateDir}/hub";
          simulation_path = "${stateDir}/config/simulation.yaml";
        };
        crowdsec_service = {
          acquisition_path = "${stateDir}/config/acquisitions.yaml";
          parser_routines = 1;
        };
        cscli = {
          output = "human";
        };
        api = {
          client = {
            insecure_skip_verify = false;
            credentials_path = "${stateDir}/config/local_api_credentials.yaml";
          };
          server = {
            enable = true;
            listen_uri = "${cfg.api.listenAddr}:${toString cfg.api.listenPort}";
            profiles_path = "${stateDir}/config/profiles.yaml";
            online_client = {
              credentials_path = "${stateDir}/config/online_api_credentials.yaml";
            };
          };
        };
        db_config = {
          type = "sqlite";
          db_path = "${stateDir}/data/crowdsec.db";
          use_wal = true;
        };
      };

      # Generate profiles file (CrowdSec expects multi-document YAML format)
      profilesFile = pkgs.writeText "profiles.yaml" ''
        name: default_ip_remediation
        filters:
          - Alert.Remediation == true && Alert.GetScope() == "Ip"
        decisions:
          - type: ban
            duration: ${cfg.bouncer.banDuration}
        on_success: break
      '';

      # Initialization script - sets up CrowdSec on first run
      initScript = pkgs.writeShellScript "crowdsec-init" ''
        set -e
        export PATH="${lib.makeBinPath [ cfg.package pkgs.coreutils pkgs.gnugrep pkgs.nettools pkgs.findutils ]}:$PATH"
        
        STATE_DIR="${stateDir}"
        CONFIG_DIR="$STATE_DIR/config"
        DATA_DIR="$STATE_DIR/data"
        HUB_DIR="$STATE_DIR/hub"
        PACKAGE="${cfg.package}"
        
        # Create directories
        mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$HUB_DIR"
        
        # Copy configuration files
        cp -f ${configFile} "$CONFIG_DIR/config.yaml"
        cp -f ${profilesFile} "$CONFIG_DIR/profiles.yaml"
        cp -f ${acquisitionsFile} "$CONFIG_DIR/acquisitions.yaml"
        cp -f ${simulationFile} "$CONFIG_DIR/simulation.yaml"
        
        # Debug: Show acquisitions file content
        echo "Generated acquisitions.yaml:"
        cat "$CONFIG_DIR/acquisitions.yaml"
        echo ""
        
        # Copy patterns directory from package (required for parser grok patterns)
        echo "Looking for patterns directory..."
        
        # Try common locations
        PATTERNS_FOUND=0
        for PATTERNS_PATH in \
          "$PACKAGE/share/crowdsec/config/patterns" \
          "$PACKAGE/share/crowdsec/patterns" \
          "$PACKAGE/etc/crowdsec/patterns" \
          ; do
          if [ -d "$PATTERNS_PATH" ]; then
            echo "Found patterns at: $PATTERNS_PATH"
            rm -rf "$CONFIG_DIR/patterns"
            cp -r "$PATTERNS_PATH" "$CONFIG_DIR/patterns"
            PATTERNS_FOUND=1
            break
          fi
        done
        
        # If not found in common locations, search the entire package
        if [ "$PATTERNS_FOUND" = "0" ]; then
          echo "Searching for patterns directory in package..."
          PATTERNS_PATH=$(find "$PACKAGE" -type d -name "patterns" 2>/dev/null | head -1)
          if [ -n "$PATTERNS_PATH" ]; then
            echo "Found patterns at: $PATTERNS_PATH"
            rm -rf "$CONFIG_DIR/patterns"
            cp -r "$PATTERNS_PATH" "$CONFIG_DIR/patterns"
            PATTERNS_FOUND=1
          fi
        fi
        
        if [ "$PATTERNS_FOUND" = "0" ]; then
          echo "WARNING: Could not find patterns directory!"
          echo "Package contents:"
          ls -la "$PACKAGE/" || true
          ls -la "$PACKAGE/share/" || true
          ls -la "$PACKAGE/share/crowdsec/" 2>/dev/null || true
        fi
        
        # Initialize database if it doesn't exist
        if [ ! -f "$DATA_DIR/crowdsec.db" ]; then
          echo "Initializing CrowdSec database..."
          touch "$CONFIG_DIR/local_api_credentials.yaml"
          touch "$CONFIG_DIR/online_api_credentials.yaml"
          chmod 640 "$CONFIG_DIR/local_api_credentials.yaml"
          chmod 640 "$CONFIG_DIR/online_api_credentials.yaml"
        fi
        
        # Generate machine ID if it doesn't exist
        if [ ! -f "$CONFIG_DIR/local_api_credentials.yaml" ] || [ ! -s "$CONFIG_DIR/local_api_credentials.yaml" ]; then
          echo "Registering local machine..."
          cscli -c "$CONFIG_DIR/config.yaml" machines add "$(hostname)" --auto --force || true
        fi
        
        # Update hub index
        echo "Updating hub index..."
        cscli -c "$CONFIG_DIR/config.yaml" hub update || true
        
        # Set correct ownership
        chown -R crowdsec:crowdsec "$STATE_DIR"
      '';

      # Hub installation script (runs after service is started)
      hubInstallScript = pkgs.writeShellScript "crowdsec-hub-install" ''
        set -e
        export PATH="${lib.makeBinPath [ cfg.package pkgs.coreutils pkgs.gnugrep ]}:$PATH"
        
        CONFIG_DIR="${stateDir}/config"
        
        # Wait for API to be ready
        for i in $(seq 1 30); do
          if cscli -c "$CONFIG_DIR/config.yaml" hub list >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        
        # Install collections
        ${lib.concatMapStringsSep "\n" (c: ''
          if ! cscli -c "$CONFIG_DIR/config.yaml" collections list 2>/dev/null | grep -q "${c}"; then
            cscli -c "$CONFIG_DIR/config.yaml" collections install ${c} || true
          fi
        '') hubCollections}
        
        # Install additional scenarios
        ${lib.concatMapStringsSep "\n" (s: ''
          if ! cscli -c "$CONFIG_DIR/config.yaml" scenarios list 2>/dev/null | grep -q "${s}"; then
            cscli -c "$CONFIG_DIR/config.yaml" scenarios install ${s} || true
          fi
        '') cfg.hub.scenarios}
        
        # Install additional parsers
        ${lib.concatMapStringsSep "\n" (p: ''
          if ! cscli -c "$CONFIG_DIR/config.yaml" parsers list 2>/dev/null | grep -q "${p}"; then
            cscli -c "$CONFIG_DIR/config.yaml" parsers install ${p} || true
          fi
        '') cfg.hub.parsers}
      '';

      # ========================================================================
      # Firewall Bouncer Configuration
      # ========================================================================
      bouncerEnabled = cfg.features.firewallBouncer && cfg.bouncer.package != null;
      
      # Whether to use declarative nftables integration
      useNftablesIntegration = bouncerEnabled && cfg.bouncer.mode == "nftables" && cfg.bouncer.nftablesIntegration;

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
        
        # Read existing key if registration failed
        if [ -f "$KEY_FILE" ]; then
          export BOUNCER_API_KEY=$(cat "$KEY_FILE")
        fi
        
        # Generate config with key substituted
        if [ -n "$BOUNCER_API_KEY" ]; then
          sed "s/\''${BOUNCER_API_KEY}/$BOUNCER_API_KEY/g" ${bouncerConfigFile} > /var/lib/crowdsec-firewall-bouncer/config.yaml
        fi
      '';

    in lib.mkMerge [
      # ==========================================================================
      # Common Configuration (both implementations)
      # ==========================================================================
      {
        # Assertions
        assertions = [
          {
            assertion = !cfg.features.firewallBouncer || cfg.bouncer.package != null;
            message = ''
              CrowdSec firewall bouncer is enabled but no package is configured.
              
              The bouncer package should be available as pkgs.crowdsec-firewall-bouncer
              on NixOS 25.11+. If using an older NixOS version, you may need to:
              
              1. Upgrade to NixOS 25.11+
              2. Set infrastructure.crowdsec.features.firewallBouncer = false
              3. Provide the package from an external source
            '';
          }

          {
            assertion = acquisitions != [];
            message = ''
              CrowdSec requires at least one acquisition source.
              
              Enable at least one of:
              - infrastructure.crowdsec.features.sshProtection = true
              - infrastructure.crowdsec.features.nginxProtection = true
              - infrastructure.crowdsec.features.systemProtection = true
              
              Or add custom acquisitions via infrastructure.crowdsec.acquisitions
            '';
          }
          {
            assertion = cfg.implementation != "native" || hasNativeCrowdsecModule;
            message = ''
              CrowdSec native implementation requires NixOS 25.11 or later.
              
              Either:
              1. Upgrade to NixOS 25.11+
              2. Set infrastructure.crowdsec.implementation = "custom"
              3. Set infrastructure.crowdsec.implementation = "auto" (recommended)
            '';
          }
        ];

        # Open firewall for LAPI if configured
        networking.firewall.allowedTCPPorts = 
          lib.mkIf cfg.api.openFirewall [ cfg.api.listenPort ];

        # Install useful CLI tools
        environment.systemPackages = [ 
          cfg.package  # Includes cscli
        ] ++ lib.optionals (bouncerEnabled && cfg.bouncer.mode == "nftables") [
          pkgs.nftables
        ] ++ lib.optionals (bouncerEnabled && cfg.bouncer.mode == "iptables") [
          pkgs.iptables
        ] ++ lib.optionals (bouncerEnabled && cfg.bouncer.mode == "ipset") [
          pkgs.ipset
        ];
      }

      # ==========================================================================
      # Declarative nftables Integration
      # ==========================================================================
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

      # ==========================================================================
      # Custom Implementation
      # ==========================================================================
      (lib.mkIf (!useNativeImplementation) {
        # Create crowdsec user and group
        users.users.crowdsec = {
          isSystemUser = true;
          group = "crowdsec";
          home = stateDir;
          description = "CrowdSec daemon user";
        };
        users.groups.crowdsec = {};

        # Ensure data directories exist and create config symlink for cscli
        systemd.tmpfiles.rules = [
          "d ${stateDir} 0755 crowdsec crowdsec - -"
          "d ${stateDir}/config 0755 crowdsec crowdsec - -"
          "d ${stateDir}/data 0755 crowdsec crowdsec - -"
          "d ${stateDir}/hub 0755 crowdsec crowdsec - -"
          # Create /etc/crowdsec directory and symlink for cscli default config path
          "d /etc/crowdsec 0755 root root - -"
          "L+ /etc/crowdsec/config.yaml - - - - ${stateDir}/config/config.yaml"
        ] ++ lib.optionals bouncerEnabled [
          "d /var/lib/crowdsec-firewall-bouncer 0750 root root - -"
        ];

        # Main CrowdSec service
        systemd.services.crowdsec = {
          description = "CrowdSec Security Engine";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "local-fs.target" ];

          serviceConfig = {
            Type = "simple";
            User = "crowdsec";
            Group = "crowdsec";
            ExecStartPre = [
              "+${initScript}"  # Run as root for permissions
            ];
            ExecStart = "${cfg.package}/bin/crowdsec -c ${stateDir}/config/config.yaml";
            ExecStartPost = "${hubInstallScript}";
            Restart = "always";
            RestartSec = "10s";
            
            # Security hardening
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
            ReadWritePaths = [ stateDir ];
            
            # Allow journal access for systemd log sources
            SupplementaryGroups = lib.optional (cfg.features.sshProtection || cfg.features.systemProtection) "systemd-journal";
          };
        };

        # Firewall bouncer service (only when package is available)
        systemd.services.crowdsec-firewall-bouncer = lib.mkIf bouncerEnabled {
          description = "CrowdSec Firewall Bouncer";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "crowdsec.service" ];
          requires = [ "crowdsec.service" ];

          path = [ pkgs.iptables pkgs.ipset ];

          serviceConfig = {
            Type = "simple";
            ExecStartPre = "${bouncerRegisterScript}";
            ExecStart = "${cfg.bouncer.package}/bin/crowdsec-firewall-bouncer -c /var/lib/crowdsec-firewall-bouncer/config.yaml";
            Restart = "always";
            RestartSec = "10s";
          };
        };
      })

      # ==========================================================================
      # Native Implementation (NixOS 25.11+)
      # ==========================================================================
      (lib.mkIf (useNativeImplementation && hasNativeCrowdsecModule) {
        # Workarounds for native module bugs
        systemd.tmpfiles.rules = [
          # WORKAROUND #445342: Create state directory
          "d /var/lib/crowdsec 0755 crowdsec crowdsec - -"
          
          # WORKAROUND #446764: Create online_api_credentials.yaml
          "f /var/lib/crowdsec/online_api_credentials.yaml 0640 crowdsec crowdsec - -"
        ] ++ lib.optionals bouncerEnabled [
          "d /var/lib/crowdsec-firewall-bouncer 0750 root root - -"
        ];

        services.crowdsec = {
          enable = true;
          package = cfg.package;

          # Hub items to install (only collections - other options may not exist)
          hub = {
            collections = hubCollections;
          };

          # Local configuration (acquisitions)
          localConfig = {
            inherit acquisitions;
          } // cfg.extraLocalConfig;

          # Main settings
          settings = lib.mkMerge [
            {
              # WORKAROUND: BUG #445342 - Enable API server by default
              general.api.server.enable = true;
            }

            # Console enrollment (if configured)
            (lib.mkIf (cfg.console.enrollKeyFile != null) {
              console.tokenFile = cfg.console.enrollKeyFile;
            })

            # User's extra settings
            cfg.extraSettings
          ];
        };

        # Firewall bouncer service (custom - not yet in native nixpkgs)
        systemd.services.crowdsec-firewall-bouncer = lib.mkIf bouncerEnabled {
          description = "CrowdSec Firewall Bouncer";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "crowdsec.service" ];
          requires = [ "crowdsec.service" ];

          path = [ pkgs.iptables pkgs.ipset ];

          serviceConfig = {
            Type = "simple";
            ExecStartPre = "${bouncerRegisterScript}";
            ExecStart = "${cfg.bouncer.package}/bin/crowdsec-firewall-bouncer -c /var/lib/crowdsec-firewall-bouncer/config.yaml";
            Restart = "always";
            RestartSec = "10s";
          };
        };
      })
    ]
  );
}
