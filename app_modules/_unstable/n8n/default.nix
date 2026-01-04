{ config, pkgs, lib, ... }:
let
  appName = "n8n";
  defaultPort = 5678;

  cfg = config.infrastructure.${appName};

  # Environment variables for n8n configuration
  n8nEnvironment = {
    # Network settings
    N8N_PORT = toString cfg.bindToPort;
    N8N_LISTEN_ADDRESS = cfg.bindToIp;

    # Execution settings
    EXECUTIONS_DATA_PRUNE = if cfg.executions.pruneData then "true" else "false";
    EXECUTIONS_DATA_MAX_AGE = toString cfg.executions.pruneDataMaxAge;
    EXECUTIONS_DATA_PRUNE_MAX_COUNT = toString cfg.executions.pruneDataMaxCount;
  } // (lib.optionalAttrs (cfg.webhookUrl != "") {
    # Webhook URL (if specified)
    WEBHOOK_URL = cfg.webhookUrl;
  }) // (lib.optionalAttrs (cfg.database.type == "postgresdb") {
    # Database settings (only set if using PostgreSQL)
    DB_TYPE = "postgresdb";
    DB_POSTGRESDB_HOST = cfg.database.postgresdb.host;
    DB_POSTGRESDB_PORT = toString cfg.database.postgresdb.port;
    DB_POSTGRESDB_DATABASE = cfg.database.postgresdb.database;
    DB_POSTGRESDB_USER = cfg.database.postgresdb.user;
  }) // (lib.optionalAttrs (cfg.database.type == "postgresdb" && cfg.database.postgresdb.ssl) {
    DB_POSTGRESDB_SSL_ENABLED = "true";
  }) // cfg.settings;
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.n8n";

    # ==========================================================================
    # Build Configuration
    # ==========================================================================

    buildMemoryMB = lib.mkOption {
      type = lib.types.int;
      description = ''
        Maximum Node.js heap size in MB for building n8n.
        Increase this if you encounter "JavaScript heap out of memory" errors during build.
      '';
      default = 4096;
      example = 8192;
    };

    # ==========================================================================
    # Network Configuration
    # ==========================================================================

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind n8n to.";
      default = "127.0.0.1";
      example = "0.0.0.0";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "Port for n8n web interface.";
      default = defaultPort;
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      description = "Open firewall for n8n.";
      default = false;
    };

    # ==========================================================================
    # Webhook Configuration
    # ==========================================================================

    webhookUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        WEBHOOK_URL for n8n, used when running behind a reverse proxy.
        This is the external URL where webhooks can reach n8n.
      '';
      default = "";
      example = "https://n8n.example.com/";
    };

    # ==========================================================================
    # Data Directory
    # ==========================================================================

    dataDir = lib.mkOption {
      type = lib.types.path;
      description = "Directory where n8n data is stored.";
      default = "/var/lib/n8n";
    };

    # ==========================================================================
    # Database Configuration
    # ==========================================================================
    database = {
      type = lib.mkOption {
        type = lib.types.enum [ "sqlite" "postgresdb" ];
        description = "Database type to use. SQLite is default, PostgreSQL recommended for production.";
        default = "sqlite";
      };

      postgresdb = {
        host = lib.mkOption {
          type = lib.types.str;
          description = "PostgreSQL host.";
          default = "localhost";
          example = "/run/postgresql";
        };

        port = lib.mkOption {
          type = lib.types.int;
          description = "PostgreSQL port.";
          default = 5432;
        };

        database = lib.mkOption {
          type = lib.types.str;
          description = "PostgreSQL database name.";
          default = "n8n";
        };

        user = lib.mkOption {
          type = lib.types.str;
          description = "PostgreSQL user.";
          default = "n8n";
        };

        passwordSecretName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          description = ''
            Name of the secret containing the PostgreSQL password.
            The secret should be placed at /run/secrets/<n>.
            If null, peer/socket authentication is assumed.
          '';
          default = null;
          example = "n8n-db-password";
        };

        ssl = lib.mkOption {
          type = lib.types.bool;
          description = "Enable SSL for PostgreSQL connection.";
          default = false;
        };

        createLocally = lib.mkOption {
          type = lib.types.bool;
          description = ''
            Whether to create the database user locally.
            This requires PostgreSQL to be running locally with trust or peer authentication.
            The database itself should be created via infrastructure.postgresql.initialDatabases.
          '';
          default = false;
        };
      };
    };


    # ==========================================================================
    # Execution Configuration
    # ==========================================================================

    executions = {
      pruneData = lib.mkOption {
        type = lib.types.bool;
        description = "Enable automatic pruning of old execution data.";
        default = true;
      };

      pruneDataMaxAge = lib.mkOption {
        type = lib.types.int;
        description = "Maximum age of execution data in hours before pruning.";
        default = 336;  # 14 days
      };

      pruneDataMaxCount = lib.mkOption {
        type = lib.types.int;
        description = "Maximum number of executions to keep.";
        default = 10000;
      };
    };

    # ==========================================================================
    # n8n Settings (pass-through as environment variables)
    # ==========================================================================

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = ''
        Additional n8n configuration as environment variables.
        These are passed directly to the n8n service.
        See https://docs.n8n.io/hosting/environment-variables/environment-variables/
      '';
      default = {};
      example = lib.literalExpression ''
        {
          GENERIC_TIMEZONE = "Europe/London";
          WORKFLOWS_DEFAULT_NAME = "My Workflow";
          N8N_METRICS = "true";
        }
      '';
    };


    # ==========================================================================
    # Reverse Proxy Configuration
    # ==========================================================================

    reverseProxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "Enable nginx reverse proxy for n8n.";
        default = false;
      };

      hostName = lib.mkOption {
        type = lib.types.str;
        description = "Hostname for the reverse proxy.";
        default = "localhost";
        example = "n8n.example.com";
      };

      ssl = lib.mkOption {
        type = lib.types.bool;
        description = "Enable SSL/HTTPS for the reverse proxy.";
        default = false;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ==========================================================================
    # Allow insecure n8n package (marked insecure due to CVE)
    # ==========================================================================

    nixpkgs.config.permittedInsecurePackages = [
      "n8n-1.91.3"
    ];

    # ==========================================================================
    # Override n8n package with increased memory for build
    # ==========================================================================

    nixpkgs.overlays = [
      (final: prev: {
        n8n = prev.n8n.overrideAttrs (oldAttrs: {
          env = (oldAttrs.env or {}) // {
            NODE_OPTIONS = "--max-old-space-size=${toString cfg.buildMemoryMB}";
          };
        });
      })
    ];

    # ==========================================================================
    # n8n Service Configuration
    # ==========================================================================

    services.n8n = {
      enable = true;
      openFirewall = cfg.openFirewall;
    };

    # Environment variables must be set through systemd service
    # This approach works on both NixOS 25.05 and 25.11+
    # Use mkForce to override the native module's default null values
    systemd.services.n8n.environment = lib.mkForce n8nEnvironment;

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

        locations."/" = {
          proxyPass = "http://${cfg.bindToIp}:${toString cfg.bindToPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            chunked_transfer_encoding off;
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

    systemd.services.n8n = {
      after = lib.mkMerge [
        (lib.mkIf cfg.reverseProxy.enable [ "nginx.service" ])
        (lib.mkIf (cfg.database.type == "postgresdb" && cfg.database.postgresdb.createLocally) [
          "postgresql.service"
          "n8n-db-setup.service"
        ])
      ];
      wants = lib.mkIf (cfg.database.type == "postgresdb" && cfg.database.postgresdb.createLocally) [
        "n8n-db-setup.service"
      ];
      requires = lib.mkIf (cfg.database.type == "postgresdb" && cfg.database.postgresdb.createLocally) [
        "postgresql.service"
      ];
    };

    systemd.services.nginx = lib.mkIf cfg.reverseProxy.enable {
      wants = [ "n8n.service" ];
    };

    # ==========================================================================
    # PostgreSQL Database Setup (Optional)
    # ==========================================================================

    systemd.services.n8n-db-setup = lib.mkIf (cfg.database.type == "postgresdb" && cfg.database.postgresdb.createLocally) {
      description = "Create n8n database user";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      before = [ "n8n.service" ];
      requiredBy = [ "n8n.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      script = let
        dbUser = cfg.database.postgresdb.user;
        dbName = cfg.database.postgresdb.database;
        dbHost = cfg.database.postgresdb.host;
        dbPort = toString cfg.database.postgresdb.port;
      in ''
        # Wait for PostgreSQL to be ready
        until ${pkgs.postgresql}/bin/pg_isready -h ${dbHost} -p ${dbPort}; do
          sleep 1
        done
        
        # Create database user if it doesn't exist
        ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -c "SELECT 1 FROM pg_roles WHERE rolname='${dbUser}'" | grep -q 1 || \
          ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -c "CREATE USER ${dbUser}"
        
        # Grant privileges on database
        ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -c "GRANT ALL PRIVILEGES ON DATABASE ${dbName} TO ${dbUser}"
        ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -d ${dbName} -c "GRANT ALL ON SCHEMA public TO ${dbUser}"
      '';
    };


    # ==========================================================================
    # Utilities
    # ==========================================================================

    environment.systemPackages = with pkgs; [
      curl
      jq
    ];
  };
}
