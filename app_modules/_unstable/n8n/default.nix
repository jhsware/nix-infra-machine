{ config, pkgs, lib, ... }:
let
  appName = "n8n";
  defaultPort = 5678;

  cfg = config.infrastructure.${appName};

  # Build the custom n8n package with version selection
  n8nPackage = if cfg.package != null then cfg.package else
    pkgs.callPackage ./package.nix {
      version = cfg.version;
      buildMemoryMB = cfg.buildMemoryMB;
    };

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
    # Package and Version Configuration
    # ==========================================================================

    version = lib.mkOption {
      type = lib.types.str;
      description = ''
        n8n version to install.
        
        Supported versions are defined in package.nix. To add a new version,
        you need to compute the source and pnpm dependency hashes.
        
        See package.nix for instructions on adding new versions.
      '';
      default = "2.1.5";
      example = "1.120.4";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      description = ''
        Custom n8n package to use. If null, the package will be built
        using the version specified in 'version' option.
        
        Use this to provide a completely custom n8n build.
      '';
      default = null;
      example = lib.literalExpression "pkgs.n8n";
    };

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
    # Disable the native n8n service (we'll configure our own systemd service)
    # ==========================================================================

    # Do NOT enable services.n8n - we create our own service to have full control

    # ==========================================================================
    # n8n User and Group
    # ==========================================================================

    users.users.n8n = {
      isSystemUser = true;
      group = "n8n";
      home = cfg.dataDir;
      createHome = true;
      description = "n8n service user";
    };

    users.groups.n8n = {};

    # ==========================================================================
    # n8n Systemd Service
    # ==========================================================================

    systemd.services.n8n = {
      description = "n8n - Workflow Automation";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ] ++ 
        lib.optionals cfg.reverseProxy.enable [ "nginx.service" ] ++
        lib.optionals (cfg.database.type == "postgresdb" && cfg.database.postgresdb.createLocally) [
          "postgresql.service"
          "n8n-db-setup.service"
        ];
      wants = lib.optionals (cfg.database.type == "postgresdb" && cfg.database.postgresdb.createLocally) [
        "n8n-db-setup.service"
      ];
      requires = lib.optionals (cfg.database.type == "postgresdb" && cfg.database.postgresdb.createLocally) [
        "postgresql.service"
      ];

      environment = n8nEnvironment;

      serviceConfig = {
        Type = "simple";
        User = "n8n";
        Group = "n8n";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${n8nPackage}/bin/n8n";
        Restart = "on-failure";
        RestartSec = "5s";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
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
