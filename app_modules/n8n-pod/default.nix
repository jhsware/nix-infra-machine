{ config, pkgs, lib, ... }:
let
  appName = "n8n-pod";
  defaultPort = 5678;

  cfg = config.infrastructure.${appName};

  dataDir = "/var/lib/n8n-pod";
  execStartPreScript = pkgs.writeShellScript "preStart" ''
    ${pkgs.coreutils}/bin/mkdir -p ${dataDir}
    ${pkgs.coreutils}/bin/chown -R 1000:1000 ${dataDir}
  '';

  # Build environment variables for the container
  containerEnv = {
    # Network settings
    N8N_PORT = toString defaultPort;
    N8N_LISTEN_ADDRESS = "0.0.0.0";  # Always bind to all interfaces inside container

    # Execution settings
    EXECUTIONS_DATA_PRUNE = if cfg.executions.pruneData then "true" else "false";
    EXECUTIONS_DATA_MAX_AGE = toString cfg.executions.pruneDataMaxAge;
    EXECUTIONS_DATA_PRUNE_MAX_COUNT = toString cfg.executions.pruneDataMaxCount;
  } // (lib.optionalAttrs (cfg.webhookUrl != "") {
    WEBHOOK_URL = cfg.webhookUrl;
  }) // (lib.optionalAttrs (cfg.database.type == "postgresdb") {
    DB_TYPE = "postgresdb";
    DB_POSTGRESDB_HOST = cfg.database.postgresdb.host;
    DB_POSTGRESDB_PORT = toString cfg.database.postgresdb.port;
    DB_POSTGRESDB_DATABASE = cfg.database.postgresdb.database;
    DB_POSTGRESDB_USER = cfg.database.postgresdb.user;
  }) // (lib.optionalAttrs (cfg.database.type == "postgresdb" && cfg.database.postgresdb.ssl) {
    DB_POSTGRESDB_SSL_ENABLED = "true";
  }) // cfg.settings;

  # Convert environment to list of "KEY=VALUE" strings
  envList = lib.mapAttrsToList (name: value: "${name}=${toString value}") containerEnv;
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.n8n-pod oci";

    image = lib.mkOption {
      type = lib.types.str;
      description = "n8n Docker image to use.";
      default = "docker.n8n.io/n8nio/n8n:latest";
      example = "docker.n8n.io/n8nio/n8n:1.70.0";
    };

    # ==========================================================================
    # Network Configuration
    # ==========================================================================

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind n8n to on the host.";
      default = "127.0.0.1";
      example = "0.0.0.0";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "Port for n8n web interface on the host.";
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
          description = "PostgreSQL host. Use host IP for container access.";
          default = "host.containers.internal";
          example = "192.168.1.100";
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

        password = lib.mkOption {
          type = lib.types.str;
          description = ''
            PostgreSQL password. For production, consider using
            passwordFile or environment variable injection instead.
          '';
          default = "";
          example = "secretpassword";
        };

        ssl = lib.mkOption {
          type = lib.types.bool;
          description = "Enable SSL for PostgreSQL connection.";
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
  };

  config = lib.mkIf cfg.enable {
    # Configure podman backend
    infrastructure.oci-containers.backend = "podman";
    
    infrastructure.oci-containers.containers.${appName} = {
      app = {
        name = appName;
      };
      image = cfg.image;
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:${toString defaultPort}"
      ];
      bindToIp = cfg.bindToIp;
      
      # Mount data directory for persistence
      volumes = [
        "${dataDir}:/home/node/.n8n"
      ];

      # Environment variables
      environment = containerEnv;

      # Run as node user (UID 1000 in official image)
      user = "1000:1000";

      execHooks = {
        ExecStartPre = [
          "${execStartPreScript}"
        ];
      };
    };

    # ==========================================================================
    # Firewall Configuration
    # ==========================================================================

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.bindToPort ];

    # ==========================================================================
    # Utilities
    # ==========================================================================

    environment.systemPackages = with pkgs; [
      curl
      jq
    ];
  };
}
