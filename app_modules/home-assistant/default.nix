{ config, pkgs, lib, ... }:
let
  appName = "home-assistant";
  defaultPort = 8123;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.home-assistant";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Home Assistant package to use.";
      default = pkgs.home-assistant;
      example = "pkgs.home-assistant";
    };

    # ==========================================================================
    # Network Configuration
    # ==========================================================================

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind Home Assistant to.";
      default = "0.0.0.0";
      example = "127.0.0.1";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "Port for Home Assistant web interface.";
      default = defaultPort;
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      description = "Open firewall for Home Assistant.";
      default = true;
    };

    # ==========================================================================
    # Configuration Directory
    # ==========================================================================

    configDir = lib.mkOption {
      type = lib.types.path;
      description = "Directory where Home Assistant configuration is stored.";
      default = "/var/lib/hass";
    };

    configWritable = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Whether to make configuration.yaml writable from the web UI.
        This allows editing configuration from Home Assistant's interface.
      '';
      default = false;
    };

    # ==========================================================================
    # Components and Integrations
    # ==========================================================================

    extraComponents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        List of Home Assistant components/integrations to include.
        Component names can be found at https://www.home-assistant.io/integrations/
      '';
      default = [
        # Components required for initial onboarding
        "esphome"
        "met"
        "radio_browser"
      ];
      example = [
        "esphome"
        "met"
        "radio_browser"
        "hue"
        "zwave_js"
        "mqtt"
        "homekit"
      ];
    };

    customComponents = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      description = "List of custom component packages to install.";
      default = [];
    };

    customLovelaceModules = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      description = "List of custom Lovelace card packages to load.";
      default = [];
    };

    # ==========================================================================
    # Home Assistant Configuration (config.yaml as Nix)
    # ==========================================================================

    config = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      description = ''
        Home Assistant configuration.yaml as a Nix attribute set.
        Set to null to use an existing configuration.yaml file.
      '';
      default = {
        # Basic setup with default_config integration
        default_config = {};

        # HTTP configuration
        http = {
          server_host = cfg.bindToIp;
          server_port = cfg.bindToPort;
        };

        # Homeassistant core settings
        homeassistant = {
          name = "Home";
          unit_system = "metric";
        };
      };
      example = lib.literalExpression ''
        {
          default_config = {};
          homeassistant = {
            name = "My Smart Home";
            unit_system = "metric";
            time_zone = "Europe/London";
            latitude = 51.5074;
            longitude = -0.1278;
          };
          automation = "!include automations.yaml";
          scene = "!include scenes.yaml";
        }
      '';
    };

    # ==========================================================================
    # Lovelace Dashboard Configuration
    # ==========================================================================

    lovelaceConfig = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      description = ''
        Lovelace dashboard configuration as a Nix attribute set.
        Set to null to use UI-managed dashboards.
      '';
      default = null;
    };

    lovelaceConfigWritable = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to make Lovelace configuration writable.";
      default = false;
    };

    # ==========================================================================
    # Reverse Proxy Configuration
    # ==========================================================================

    reverseProxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "Enable nginx reverse proxy for Home Assistant.";
        default = false;
      };

      hostName = lib.mkOption {
        type = lib.types.str;
        description = "Hostname for the reverse proxy.";
        default = "localhost";
        example = "homeassistant.example.com";
      };

      ssl = lib.mkOption {
        type = lib.types.bool;
        description = "Enable SSL/HTTPS for the reverse proxy.";
        default = false;
      };

      trustedProxies = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "List of trusted proxy IP addresses.";
        default = [ "127.0.0.1" "::1" ];
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ==========================================================================
    # Home Assistant Service Configuration
    # ==========================================================================

    services.home-assistant = {
      enable = true;
      package = cfg.package;
      configDir = cfg.configDir;
      configWritable = cfg.configWritable;

      # Components and integrations
      extraComponents = cfg.extraComponents;
      customComponents = cfg.customComponents;
      customLovelaceModules = cfg.customLovelaceModules;

      # Configuration
      config = if cfg.config != null then (cfg.config // {
        # Always include HTTP config if using reverse proxy
        http = (cfg.config.http or {}) // (lib.mkIf cfg.reverseProxy.enable {
          use_x_forwarded_for = true;
          trusted_proxies = cfg.reverseProxy.trustedProxies;
        });
      }) else null;

      # Lovelace configuration
      lovelaceConfig = cfg.lovelaceConfig;
      lovelaceConfigWritable = cfg.lovelaceConfigWritable;
    };

    # ==========================================================================
    # Nginx Reverse Proxy (Optional)
    # ==========================================================================

    services.nginx = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = cfg.reverseProxy.ssl;

      virtualHosts.${cfg.reverseProxy.hostName} = {
        forceSSL = cfg.reverseProxy.ssl;
        enableACME = cfg.reverseProxy.ssl;

        extraConfig = ''
          proxy_buffering off;
        '';

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.bindToPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
    };

    # ==========================================================================
    # Firewall Configuration
    # ==========================================================================

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
      [ cfg.bindToPort ] ++
      (lib.optionals cfg.reverseProxy.enable [ 80 443 ])
    );

    # ==========================================================================
    # Service Dependencies
    # ==========================================================================

    systemd.services.home-assistant = {
      after = lib.mkIf cfg.reverseProxy.enable [ "nginx.service" ];
    };

    systemd.services.nginx = lib.mkIf cfg.reverseProxy.enable {
      wants = [ "home-assistant.service" ];
    };

    # ==========================================================================
    # Utilities
    # ==========================================================================

    environment.systemPackages = with pkgs; [
      curl
    ];
  };
}
