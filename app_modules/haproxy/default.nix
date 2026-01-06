{ config, pkgs, lib, ... }:
let
  appName = "haproxy";

  cfg = config.infrastructure.${appName};

  # Generate combined PEM file path for a domain
  combinedPemPath = domain: "/var/lib/acme/${domain}/combined.pem";

  # Self-signed certificate directory
  selfSignedCertDir = "/var/lib/haproxy/certs";

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

  # Script to generate self-signed certificates for testing
  mkSelfSignedCertScript = domain: pkgs.writeShellScript "generate-self-signed-${domain}" ''
    CERT_DIR="${selfSignedCertDir}"
    COMBINED="$CERT_DIR/${domain}.pem"
    
    mkdir -p "$CERT_DIR"
    
    # Only generate if not exists or expired
    if [ ! -f "$COMBINED" ] || ! ${pkgs.openssl}/bin/openssl x509 -checkend 86400 -noout -in "$COMBINED" 2>/dev/null; then
      echo "Generating self-signed certificate for ${domain}..."
      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 \
        -keyout "$CERT_DIR/${domain}.key" \
        -out "$CERT_DIR/${domain}.crt" \
        -sha256 -days 365 -nodes \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain},DNS:*.${domain}"
      
      # Combine for HAProxy
      cat "$CERT_DIR/${domain}.crt" "$CERT_DIR/${domain}.key" > "$COMBINED"
      chmod 640 "$COMBINED"
      chown haproxy:haproxy "$COMBINED"
      rm -f "$CERT_DIR/${domain}.key" "$CERT_DIR/${domain}.crt"
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
    # Self-Signed Certificate Configuration (for testing)
    # ==========================================================================

    selfSigned = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Enable self-signed certificate generation for testing.
          These certificates are NOT trusted by browsers but useful for development/testing.
        '';
        default = false;
      };

      domains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "List of domains to generate self-signed certificates for.";
        default = [];
        example = [ "localhost" "test.local" ];
      };

      regenerate = lib.mkOption {
        type = lib.types.bool;
        description = "Force regeneration of self-signed certificates on each activation.";
        default = false;
      };
    };

    # ==========================================================================
    # SSL/TLS Configuration
    # ==========================================================================

    ssl = {
      minVersion = lib.mkOption {
        type = lib.types.enum [ "TLSv1.2" "TLSv1.3" ];
        description = "Minimum TLS version to accept.";
        default = "TLSv1.2";
      };

      ciphers = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = "Custom cipher suite for TLS 1.2 and below.";
        default = null;
        example = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256";
      };

      ciphersuites = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = "Custom cipher suite for TLS 1.3.";
        default = null;
        example = "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384";
      };

      hsts = {
        enable = lib.mkOption {
          type = lib.types.bool;
          description = "Enable HTTP Strict Transport Security (HSTS) header.";
          default = false;
        };

        maxAge = lib.mkOption {
          type = lib.types.int;
          description = "HSTS max-age in seconds.";
          default = 31536000;  # 1 year
        };

        includeSubDomains = lib.mkOption {
          type = lib.types.bool;
          description = "Include subdomains in HSTS policy.";
          default = true;
        };

        preload = lib.mkOption {
          type = lib.types.bool;
          description = "Add preload directive to HSTS header.";
          default = false;
        };
      };
    };

    # ==========================================================================
    # HTTP to HTTPS Redirect
    # ==========================================================================

    httpToHttpsRedirect = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Automatically redirect HTTP requests to HTTPS.
          Creates a frontend on port 80 that redirects all traffic to HTTPS.
        '';
        default = false;
      };

      code = lib.mkOption {
        type = lib.types.enum [ 301 302 307 308 ];
        description = "HTTP redirect status code to use.";
        default = 301;
      };

      excludePaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Paths to exclude from redirect (e.g., ACME challenge).";
        default = [ "/.well-known/acme-challenge/" ];
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
          httpResponse = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "http-response rules.";
            default = [];
            example = [ "set-header Strict-Transport-Security max-age=31536000" ];
          };
          tcpRequest = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "tcp-request rules (for TCP mode).";
            default = [];
            example = [ "inspect-delay 5s" "content accept if { req_ssl_hello_type 1 }" ];
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
          tcpCheck = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "tcp-check rules for TCP mode health checking.";
            default = [];
            example = [ "connect" "send PING\\r\\n" "expect string +PONG" ];
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
    # Assertions
    assertions = [
      {
        assertion = !(cfg.acme.enable && cfg.selfSigned.enable);
        message = "Cannot enable both ACME and self-signed certificates. Choose one.";
      }
      {
        assertion = cfg.acme.enable -> cfg.acme.acceptTerms;
        message = "You must accept the ACME terms of service to use Let's Encrypt.";
      }
      {
        assertion = cfg.acme.enable -> cfg.acme.email != null;
        message = "You must provide an email address for ACME certificate registration.";
      }
    ];

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

    # Create directories for ACME and self-signed certificates
    systemd.tmpfiles.rules = 
      lib.optionals cfg.acme.enable [
        "d /var/lib/acme/acme-challenge 0755 acme acme -"
        "d /var/lib/acme/acme-challenge/.well-known 0755 acme acme -"
        "d /var/lib/acme/acme-challenge/.well-known/acme-challenge 0755 acme acme -"
      ] ++
      lib.optionals cfg.selfSigned.enable [
        "d ${selfSignedCertDir} 0750 haproxy haproxy -"
      ];

    # Self-signed certificate generation service
    systemd.services.haproxy-generate-self-signed = lib.mkIf cfg.selfSigned.enable {
      description = "Generate self-signed certificates for HAProxy";
      wantedBy = [ "haproxy.service" ];
      before = [ "haproxy.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStringsSep "\n" (domain: 
        "${mkSelfSignedCertScript domain}"
      ) cfg.selfSigned.domains;
    };

    # HAProxy configuration
    services.haproxy = {
      enable = true;
      package = cfg.package;
      user = cfg.user;
      group = cfg.group;

      config = let
        # HSTS header value
        hstsHeader = lib.optionalString cfg.ssl.hsts.enable (
          "max-age=${toString cfg.ssl.hsts.maxAge}" +
          lib.optionalString cfg.ssl.hsts.includeSubDomains "; includeSubDomains" +
          lib.optionalString cfg.ssl.hsts.preload "; preload"
        );

        # HTTP to HTTPS redirect frontend
        httpRedirectFrontend = lib.optionalString cfg.httpToHttpsRedirect.enable ''
          frontend http-redirect
            bind *:80
            mode http
            ${lib.concatMapStringsSep "\n  " (path: "acl is_acme path_beg ${path}") cfg.httpToHttpsRedirect.excludePaths}
            ${lib.optionalString (cfg.httpToHttpsRedirect.excludePaths != []) "use_backend acme_backend if is_acme"}
            http-request redirect scheme https code ${toString cfg.httpToHttpsRedirect.code} unless { ssl_fc }${lib.optionalString (cfg.httpToHttpsRedirect.excludePaths != []) " or is_acme"}
        '';

        # Generate frontend configuration
        frontendConfigs = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: frontend: ''
          frontend ${name}
            ${lib.concatMapStringsSep "\n  " (b: "bind ${b}") frontend.bind}
            mode ${frontend.mode}
            ${lib.concatMapStringsSep "\n  " (o: "option ${o}") frontend.options}
            ${lib.concatMapStringsSep "\n  " (a: "acl ${a}") frontend.acls}
            ${lib.concatMapStringsSep "\n  " (r: "http-request ${r}") frontend.httpRequest}
            ${lib.concatMapStringsSep "\n  " (r: "http-response ${r}") frontend.httpResponse}
            ${lib.concatMapStringsSep "\n  " (r: "tcp-request ${r}") frontend.tcpRequest}
            ${lib.optionalString (cfg.ssl.hsts.enable && frontend.mode == "http") "http-response set-header Strict-Transport-Security \"${hstsHeader}\""}
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
            ${lib.concatMapStringsSep "\n  " (c: "tcp-check ${c}") backend.tcpCheck}
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

        ${httpRedirectFrontend}

        ${frontendConfigs}

        ${backendConfigs}

        ${listenConfigs}

        ${cfg.extraConfig}
      '';
    };

    # Ensure HAProxy starts after certificates are ready
    systemd.services.haproxy = lib.mkMerge [
      (lib.mkIf cfg.acme.enable {
        wants = lib.mapAttrsToList (domain: _: "acme-${domain}.service") cfg.acme.domains;
        after = lib.mapAttrsToList (domain: _: "acme-${domain}.service") cfg.acme.domains;
      })
      (lib.mkIf cfg.selfSigned.enable {
        wants = [ "haproxy-generate-self-signed.service" ];
        after = [ "haproxy-generate-self-signed.service" ];
      })
      {
        serviceConfig = {
          # Allow HAProxy to reload without restart
          ExecReload = "${pkgs.coreutils}/bin/kill -USR2 $MAINPID";
        };
      }
    ];

    # Open firewall for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 80 443 ];

    # Install useful utilities
    environment.systemPackages = [ cfg.package pkgs.curl pkgs.openssl ];
  };
}

