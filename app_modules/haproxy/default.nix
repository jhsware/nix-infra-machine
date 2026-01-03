{ config, pkgs, lib, ... }:
let
  appName = "haproxy";

  cfg = config.infrastructure.${appName};

  # Generate combined PEM file path for a domain
  combinedPemPath = domain: "/var/lib/acme/${domain}/combined.pem";

  # Script to concatenate fullchain.pem and privkey.pem for HAProxy
  # HAProxy requires a single file with cert chain + private key
  mkCombinePemScript = domain: pkgs.writeShellScript "combine-pem-${domain}" ''
    ACME_DIR="/var/lib/acme/${domain}"
    COMBINED="$ACME_DIR/combined.pem"
    
    if [ -f "$ACME_DIR/fullchain.pem" ] && [ -f "$ACME_DIR/privkey.pem" ]; then
      cat "$ACME_DIR/fullchain.pem" "$ACME_DIR/privkey.pem" > "$COMBINED"
      chmod 640 "$COMBINED"
      chown acme:haproxy "$COMBINED"
    fi
  '';

  # Default HAProxy global configuration
  defaultGlobalConfig = ''
    global
      log /dev/log local0
      log /dev/log local1 notice
      maxconn 4096
      # Modern SSL settings
      ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
      ssl-default-bind-options prefer-client-ciphers no-sslv3 no-tlsv10 no-tlsv11
      ssl-default-server-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
      ssl-default-server-options no-sslv3 no-tlsv10 no-tlsv11
      tune.ssl.default-dh-param 2048
  '';

  # Default HAProxy defaults configuration
  defaultDefaultsConfig = ''
    defaults
      log global
      mode http
      option httplog
      option dontlognull
      option forwardfor
      option http-server-close
      timeout connect 5s
      timeout client 50s
      timeout server 50s
      timeout http-request 10s
      timeout http-keep-alive 10s
      errorfile 400 /dev/null
      errorfile 403 /dev/null
      errorfile 408 /dev/null
      errorfile 500 /dev/null
      errorfile 502 /dev/null
      errorfile 503 /dev/null
      errorfile 504 /dev/null
  '';

in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.haproxy";

    package = lib.mkOption {
      type = lib.types.package;
      description = "HAProxy package to use.";
      default = pkgs.haproxy;
      example = "pkgs.haproxy-lts";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to open firewall ports for HTTP (80) and HTTPS (443).";
      default = true;
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "User account under which HAProxy runs.";
      default = "haproxy";
    };

    group = lib.mkOption {
      type = lib.types.str;
      description = "Group account under which HAProxy runs.";
      default = "haproxy";
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

      domains = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            extraDomainNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Additional domain names (SANs) for this certificate.";
              default = [];
              example = [ "www.example.com" "api.example.com" ];
            };
            webroot = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              description = "Webroot path for HTTP-01 challenge. If null, standalone mode is used.";
              default = "/var/lib/acme/acme-challenge";
            };
            extraConfig = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              description = "Extra configuration options for this certificate.";
              default = {};
            };
          };
        });
        description = ''
          Domains to obtain certificates for. The key is the primary domain name.
          Use extraDomainNames for additional SANs (Subject Alternative Names).
        '';
        default = {};
        example = lib.literalExpression ''
          {
            "example.com" = {
              extraDomainNames = [ "www.example.com" ];
            };
            "api.example.com" = {};
          }
        '';
      };

      extraConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        description = ''
          Extra configuration options passed to security.acme.defaults.
          See https://nixos.org/manual/nixos/stable/#module-security-acme for options.
        '';
        default = {};
        example = {
          renewInterval = "daily";
        };
      };
    };

    # ==========================================================================
    # HAProxy Configuration
    # ==========================================================================

    globalConfig = lib.mkOption {
      type = lib.types.lines;
      description = "HAProxy global section configuration.";
      default = defaultGlobalConfig;
      example = ''
        global
          log /dev/log local0
          maxconn 2048
      '';
    };

    defaultsConfig = lib.mkOption {
      type = lib.types.lines;
      description = "HAProxy defaults section configuration.";
      default = defaultDefaultsConfig;
      example = ''
        defaults
          log global
          mode http
          timeout connect 5s
          timeout client 50s
          timeout server 50s
      '';
    };

    frontends = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          bind = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Bind addresses and ports.";
            default = [];
            example = [ "*:80" "*:443 ssl crt /path/to/cert.pem" ];
          };
          mode = lib.mkOption {
            type = lib.types.enum [ "http" "tcp" ];
            description = "Frontend mode.";
            default = "http";
          };
          options = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "HAProxy options for this frontend.";
            default = [];
            example = [ "httplog" "forwardfor" ];
          };
          acls = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "ACL definitions.";
            default = [];
            example = [ "is_api path_beg /api" "is_static path_beg /static" ];
          };
          httpRequest = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "http-request rules.";
            default = [];
            example = [ "set-header X-Forwarded-Proto https if { ssl_fc }" ];
          };
          useBackend = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "use_backend rules.";
            default = [];
            example = [ "api_backend if is_api" "static_backend if is_static" ];
          };
          defaultBackend = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "Default backend for this frontend.";
            default = null;
            example = "web_backend";
          };
          extraConfig = lib.mkOption {
            type = lib.types.lines;
            description = "Extra configuration for this frontend.";
            default = "";
          };
        };
      });
      description = "HAProxy frontend configurations.";
      default = {};
      example = lib.literalExpression ''
        {
          http = {
            bind = [ "*:80" ];
            defaultBackend = "web_backend";
          };
          https = {
            bind = [ "*:443 ssl crt /var/lib/acme/example.com/combined.pem" ];
            httpRequest = [ "set-header X-Forwarded-Proto https" ];
            defaultBackend = "web_backend";
          };
        }
      '';
    };

    backends = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          mode = lib.mkOption {
            type = lib.types.enum [ "http" "tcp" ];
            description = "Backend mode.";
            default = "http";
          };
          balance = lib.mkOption {
            type = lib.types.str;
            description = "Load balancing algorithm.";
            default = "roundrobin";
            example = "leastconn";
          };
          options = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "HAProxy options for this backend.";
            default = [];
            example = [ "httpchk GET /health" ];
          };
          httpRequest = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "http-request rules for this backend.";
            default = [];
          };
          httpResponse = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "http-response rules for this backend.";
            default = [];
          };
          servers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Backend server definitions.";
            default = [];
            example = [ "server1 127.0.0.1:8080 check" "server2 127.0.0.1:8081 check" ];
          };
          extraConfig = lib.mkOption {
            type = lib.types.lines;
            description = "Extra configuration for this backend.";
            default = "";
          };
        };
      });
      description = "HAProxy backend configurations.";
      default = {};
      example = lib.literalExpression ''
        {
          web_backend = {
            balance = "roundrobin";
            servers = [ "web1 127.0.0.1:8080 check" "web2 127.0.0.1:8081 check" ];
            options = [ "httpchk GET /health" ];
          };
        }
      '';
    };

    listen = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          bind = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Bind addresses and ports.";
            default = [];
          };
          mode = lib.mkOption {
            type = lib.types.enum [ "http" "tcp" ];
            description = "Listen mode.";
            default = "http";
          };
          balance = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "Load balancing algorithm.";
            default = null;
          };
          options = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "HAProxy options for this listen section.";
            default = [];
          };
          servers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Server definitions.";
            default = [];
          };
          extraConfig = lib.mkOption {
            type = lib.types.lines;
            description = "Extra configuration for this listen section.";
            default = "";
          };
        };
      });
      description = "HAProxy listen sections (combined frontend/backend).";
      default = {};
      example = lib.literalExpression ''
        {
          stats = {
            bind = [ "*:8404" ];
            options = [ "http-use-htx" "httplog" ];
            extraConfig = '''
              stats enable
              stats uri /stats
              stats refresh 10s
            ''';
          };
        }
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      description = "Extra HAProxy configuration appended to the config file.";
      default = "";
    };
  };

  config = lib.mkIf cfg.enable {
    # ACME configuration for Let's Encrypt
    security.acme = lib.mkIf cfg.acme.enable {
      acceptTerms = cfg.acme.acceptTerms;
      defaults = {
        email = cfg.acme.email;
        server = lib.mkIf cfg.acme.staging "https://acme-staging-v02.api.letsencrypt.org/directory";
        webroot = "/var/lib/acme/acme-challenge";
        group = "haproxy";
      } // cfg.acme.extraConfig;

      # Create certificate configurations for each domain
      certs = lib.mapAttrs (domain: domainCfg: {
        inherit (domainCfg) extraDomainNames;
        webroot = domainCfg.webroot;
        # Reload HAProxy after certificate renewal
        postRun = ''
          # Combine fullchain and privkey for HAProxy
          ${mkCombinePemScript domain}
          # Reload HAProxy to pick up new certificates
          ${pkgs.systemd}/bin/systemctl reload haproxy.service || true
        '';
      } // domainCfg.extraConfig) cfg.acme.domains;
    };

    # Ensure haproxy user is in acme group to read certificates
    users.users.haproxy = lib.mkIf cfg.acme.enable {
      extraGroups = [ "acme" ];
    };

    # Create ACME challenge directory for webroot validation
    systemd.tmpfiles.rules = lib.mkIf cfg.acme.enable [
      "d /var/lib/acme/acme-challenge 0755 acme acme -"
      "d /var/lib/acme/acme-challenge/.well-known 0755 acme acme -"
      "d /var/lib/acme/acme-challenge/.well-known/acme-challenge 0755 acme acme -"
    ];

    # HAProxy configuration
    services.haproxy = {
      enable = true;
      package = cfg.package;
      user = cfg.user;
      group = cfg.group;

      config = let
        # Generate frontend configuration
        frontendConfigs = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: frontend: ''
          frontend ${name}
            ${lib.concatMapStringsSep "\n  " (b: "bind ${b}") frontend.bind}
            mode ${frontend.mode}
            ${lib.concatMapStringsSep "\n  " (o: "option ${o}") frontend.options}
            ${lib.concatMapStringsSep "\n  " (a: "acl ${a}") frontend.acls}
            ${lib.concatMapStringsSep "\n  " (r: "http-request ${r}") frontend.httpRequest}
            ${lib.concatMapStringsSep "\n  " (u: "use_backend ${u}") frontend.useBackend}
            ${lib.optionalString (frontend.defaultBackend != null) "default_backend ${frontend.defaultBackend}"}
            ${frontend.extraConfig}
        '') cfg.frontends);

        # Generate backend configuration
        backendConfigs = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: backend: ''
          backend ${name}
            mode ${backend.mode}
            balance ${backend.balance}
            ${lib.concatMapStringsSep "\n  " (o: "option ${o}") backend.options}
            ${lib.concatMapStringsSep "\n  " (r: "http-request ${r}") backend.httpRequest}
            ${lib.concatMapStringsSep "\n  " (r: "http-response ${r}") backend.httpResponse}
            ${lib.concatMapStringsSep "\n  " (s: "server ${s}") backend.servers}
            ${backend.extraConfig}
        '') cfg.backends);

        # Generate listen configuration
        listenConfigs = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: listenCfg: ''
          listen ${name}
            ${lib.concatMapStringsSep "\n  " (b: "bind ${b}") listenCfg.bind}
            mode ${listenCfg.mode}
            ${lib.optionalString (listenCfg.balance != null) "balance ${listenCfg.balance}"}
            ${lib.concatMapStringsSep "\n  " (o: "option ${o}") listenCfg.options}
            ${lib.concatMapStringsSep "\n  " (s: "server ${s}") listenCfg.servers}
            ${listenCfg.extraConfig}
        '') cfg.listen);

      in ''
        ${cfg.globalConfig}

        ${cfg.defaultsConfig}

        ${frontendConfigs}

        ${backendConfigs}

        ${listenConfigs}

        ${cfg.extraConfig}
      '';
    };

    # Ensure HAProxy starts after ACME certificates are ready
    systemd.services.haproxy = lib.mkIf cfg.acme.enable {
      wants = lib.mapAttrsToList (domain: _: "acme-${domain}.service") cfg.acme.domains;
      after = lib.mapAttrsToList (domain: _: "acme-${domain}.service") cfg.acme.domains;
      serviceConfig = {
        # Allow HAProxy to reload without restart
        ExecReload = "${pkgs.coreutils}/bin/kill -USR2 $MAINPID";
      };
    };

    # Open firewall for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 80 443 ];

    # Install useful utilities
    environment.systemPackages = [ cfg.package pkgs.curl pkgs.openssl ];
  };
}
