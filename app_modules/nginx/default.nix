{ config, pkgs, lib, ... }:
let
  appName = "nginx";

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.nginx";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Nginx package to use.";
      default = pkgs.nginx;
      example = "pkgs.nginxMainline";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to open firewall ports for HTTP (80) and HTTPS (443).";
      default = true;
    };

    recommendedSettings = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Enable recommended nginx settings for optimization and security.
        This enables recommendedGzipSettings, recommendedOptimisation,
        recommendedProxySettings, and recommendedTlsSettings.
      '';
      default = true;
    };

    # ==========================================================================
    # Let's Encrypt / ACME Configuration
    # ==========================================================================

    acme = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "Enable ACME (Let's Encrypt) certificate management.";
        default = false;
      };

      acceptTerms = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Accept the ACME provider's terms of service.
          For Let's Encrypt: https://letsencrypt.org/documents/LE-SA-v1.2-November-15-2017.pdf
        '';
        default = false;
      };

      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = "Default email address for ACME certificate registration and renewal notifications.";
        default = null;
        example = "admin@example.com";
      };

      staging = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Use Let's Encrypt staging server for testing.
          Certificates won't be trusted but you won't hit rate limits.
        '';
        default = false;
      };

      extraConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        description = ''
          Extra configuration options passed to security.acme.defaults.
          See https://nixos.org/manual/nixos/stable/#module-security-acme for options.
        '';
        default = {};
        example = {
          webroot = "/var/lib/acme/acme-challenge";
          renewInterval = "daily";
        };
      };
    };

    # ==========================================================================
    # Pass-through Configuration
    # ==========================================================================

    virtualHosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        # Use freeformType to allow any nginx virtualHost options
        freeformType = lib.types.attrsOf lib.types.anything;
      });
      description = ''
        Virtual host configurations passed directly to services.nginx.virtualHosts.
        See https://nixos.org/manual/nixos/stable/options.html#opt-services.nginx.virtualHosts
        
        Example with Let's Encrypt:
        {
          "example.com" = {
            enableACME = true;
            forceSSL = true;
            locations."/" = {
              proxyPass = "http://127.0.0.1:8080";
            };
          };
        }
      '';
      default = {};
      example = lib.literalExpression ''
        {
          "example.com" = {
            enableACME = true;
            forceSSL = true;
            root = "/var/www/example.com";
          };
          "api.example.com" = {
            enableACME = true;
            forceSSL = true;
            locations."/" = {
              proxyPass = "http://127.0.0.1:3000";
              proxyWebsockets = true;
            };
          };
        }
      '';
    };

    appendHttpConfig = lib.mkOption {
      type = lib.types.lines;
      description = "Additional nginx http block configuration.";
      default = "";
      example = ''
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = ''
        Extra configuration options passed directly to services.nginx.
        Use this for any nginx options not explicitly exposed by this module.
      '';
      default = {};
      example = {
        clientMaxBodySize = "100m";
        resolver = { addresses = [ "1.1.1.1" ]; };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ACME configuration
    security.acme = lib.mkIf cfg.acme.enable {
      acceptTerms = cfg.acme.acceptTerms;
      defaults = {
        email = cfg.acme.email;
        server = lib.mkIf cfg.acme.staging "https://acme-staging-v02.api.letsencrypt.org/directory";
      } // cfg.acme.extraConfig;
    };

    # Nginx configuration
    services.nginx = {
      enable = true;
      package = cfg.package;

      # Recommended settings
      recommendedGzipSettings = cfg.recommendedSettings;
      recommendedOptimisation = cfg.recommendedSettings;
      recommendedProxySettings = cfg.recommendedSettings;
      recommendedTlsSettings = cfg.recommendedSettings;

      # Virtual hosts (pass-through)
      virtualHosts = cfg.virtualHosts;

      # Additional http config
      appendHttpConfig = cfg.appendHttpConfig;
    } // cfg.extraConfig;

    # Open firewall for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 80 443 ];

    # Install useful utilities
    environment.systemPackages = [ pkgs.curl pkgs.openssl ];
  };
}
