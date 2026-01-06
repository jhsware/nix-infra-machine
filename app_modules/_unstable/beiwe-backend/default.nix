{ config, pkgs, lib, ... }:
let
  appName = "beiwe-backend";
  defaultPort = 8080;

  cfg = config.infrastructure.${appName};

  # Build the beiwe-backend package
  beiwePackage = if cfg.package != null then cfg.package else
    pkgs.callPackage ./package.nix {
      rev = cfg.version;
    };

  # Construct the Celery broker URL from RabbitMQ settings
  celeryBrokerUrl = if cfg.celery.enable then
    "amqp://${cfg.celery.rabbitmq.user}:${cfg.celery.rabbitmq.password}@${cfg.celery.rabbitmq.host}:${toString cfg.celery.rabbitmq.port}/${cfg.celery.rabbitmq.vhost}"
  else "";

  # Environment variables for beiwe-backend configuration
  # See: https://github.com/jhsware/beiwe-backend (fork with env var support)
  beiweEnvironment = {
    # Required settings
    DOMAIN_NAME = cfg.domainName;
    FLASK_SECRET_KEY = cfg.flaskSecretKey;
    SYSADMIN_EMAILS = cfg.sysadminEmails;
    
    # Database settings (PostgreSQL)
    RDS_DB_NAME = cfg.database.name;
    RDS_USERNAME = cfg.database.user;
    RDS_PASSWORD = cfg.database.password;
    RDS_HOSTNAME = cfg.database.host;
    RDS_PORT = toString cfg.database.port;
    
    # PostgreSQL SSL mode
    # Multiple env vars to ensure compatibility with different Django/psycopg versions
    PGSSLMODE = cfg.database.sslmode;
    DATABASE_SSLMODE = cfg.database.sslmode;
    
    # S3/MinIO settings
    S3_BUCKET = cfg.s3.bucket;
    AWS_ACCESS_KEY_ID = cfg.s3.accessKeyId;
    AWS_SECRET_ACCESS_KEY = cfg.s3.secretAccessKey;
    BEIWE_SERVER_AWS_ACCESS_KEY_ID = cfg.s3.accessKeyId;
    BEIWE_SERVER_AWS_SECRET_ACCESS_KEY = cfg.s3.secretAccessKey;
    S3_ACCESS_CREDENTIALS_USER = cfg.s3.accessKeyId;
    S3_ACCESS_CREDENTIALS_KEY = cfg.s3.secretAccessKey;
    
    # Django settings
    DJANGO_SETTINGS_MODULE = "config.django_settings";
  } // (lib.optionalAttrs (cfg.s3.endpoint != "") {
    # Custom S3 endpoint for MinIO
    S3_ENDPOINT_URL = cfg.s3.endpoint;
    AWS_S3_ENDPOINT_URL = cfg.s3.endpoint;
  }) // (lib.optionalAttrs (cfg.sentry.dsn != "") {
    # Sentry error tracking (optional)
    SENTRY_ELASTIC_BEANSTALK_DSN = cfg.sentry.dsn;
    SENTRY_DATA_PROCESSING_DSN = cfg.sentry.dsn;
  }) // (lib.optionalAttrs cfg.celery.enable {
    # Celery/RabbitMQ settings
    CELERY_BROKER_URL = celeryBrokerUrl;
    BROKER_URL = celeryBrokerUrl;
    # jhsware fork environment variables for Celery configuration
    # These replace the manager_ip file requirement
    CELERY_MANAGER_IP = "${cfg.celery.rabbitmq.host}:${toString cfg.celery.rabbitmq.port}";
    CELERY_PASSWORD = cfg.celery.rabbitmq.password;
  }) // cfg.extraEnvironment;


in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.beiwe-backend";

    # ==========================================================================
    # Package and Version Configuration
    # ==========================================================================

    version = lib.mkOption {
      type = lib.types.str;
      description = ''
        Git commit hash of beiwe-backend to install.
        
        Uses jhsware fork which adds environment variable support for Celery.
        Supported versions are defined in package.nix.
        
        See package.nix for instructions on adding new versions.
      '';
      default = "93be878";  # jhsware fork with CELERY_MANAGER_IP/CELERY_PASSWORD env var support
      example = "main";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      description = ''
        Custom beiwe-backend package to use. If null, the package will be built
        using the version specified in 'version' option.
      '';
      default = null;
    };

    # ==========================================================================
    # Network Configuration
    # ==========================================================================

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind beiwe-backend to.";
      default = "127.0.0.1";
      example = "0.0.0.0";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "Port for beiwe-backend web interface.";
      default = defaultPort;
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      description = "Open firewall for beiwe-backend.";
      default = false;
    };

    domainName = lib.mkOption {
      type = lib.types.str;
      description = "Domain name for the Beiwe backend (used in DOMAIN_NAME env var).";
      default = "localhost:8080";
      example = "beiwe.example.com";
    };

    # ==========================================================================
    # Security Configuration
    # ==========================================================================

    flaskSecretKey = lib.mkOption {
      type = lib.types.str;
      description = ''
        A unique, cryptographically secure string for Flask sessions.
        IMPORTANT: Change this in production!
      '';
      default = "CHANGE_ME_IN_PRODUCTION_use_a_random_string";
      example = "your-super-secret-random-key-here";
    };

    sysadminEmails = lib.mkOption {
      type = lib.types.str;
      description = "System administrator email addresses (comma-separated).";
      default = "sysadmin@localhost";
      example = "admin@example.com";
    };

    # ==========================================================================
    # Data Directory
    # ==========================================================================

    dataDir = lib.mkOption {
      type = lib.types.path;
      description = "Directory where beiwe-backend data is stored.";
      default = "/var/lib/beiwe-backend";
    };

    # ==========================================================================
    # Database Configuration (PostgreSQL)
    # ==========================================================================
    database = {
      host = lib.mkOption {
        type = lib.types.str;
        description = "PostgreSQL host.";
        default = "/run/postgresql";
        example = "localhost";
      };

      port = lib.mkOption {
        type = lib.types.int;
        description = "PostgreSQL port.";
        default = 5432;
      };

      name = lib.mkOption {
        type = lib.types.str;
        description = "PostgreSQL database name.";
        default = "beiwe";
      };

      user = lib.mkOption {
        type = lib.types.str;
        description = "PostgreSQL user.";
        default = "beiwe";
      };

      password = lib.mkOption {
        type = lib.types.str;
        description = ''
          PostgreSQL password. Required by Beiwe even when using trust authentication.
          For trust authentication, use an empty string or placeholder value.
        '';
        default = "unused_with_trust_auth";
        example = "secure-password-here";
      };

      passwordSecretName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = ''
          Name of the secret containing the PostgreSQL password.
          The secret should be placed at /run/secrets/<n>.
          If null, peer/socket authentication is assumed.
        '';
        default = null;
        example = "beiwe-db-password";
      };

      sslmode = lib.mkOption {
        type = lib.types.enum [ "disable" "allow" "prefer" "require" "verify-ca" "verify-full" ];
        description = ''
          PostgreSQL SSL mode. For local development without SSL certificates,
          use "disable". For production with SSL, use "require" or "verify-full".
          
          See: https://www.postgresql.org/docs/current/libpq-ssl.html
        '';
        default = "prefer";
        example = "disable";
      };

      createLocally = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether to create the database user locally.
          This requires PostgreSQL to be running locally with trust or peer authentication.
        '';
        default = false;
      };
    };

    # ==========================================================================
    # S3/MinIO Configuration
    # ==========================================================================
    s3 = {
      bucket = lib.mkOption {
        type = lib.types.str;
        description = "S3 bucket name for data storage.";
        default = "beiwe-data";
      };

      accessKeyId = lib.mkOption {
        type = lib.types.str;
        description = "AWS/MinIO access key ID.";
        default = "";
        example = "minioadmin";
      };

      secretAccessKey = lib.mkOption {
        type = lib.types.str;
        description = "AWS/MinIO secret access key.";
        default = "";
        example = "minioadmin";
      };

      endpoint = lib.mkOption {
        type = lib.types.str;
        description = ''
          Custom S3 endpoint URL for MinIO or other S3-compatible storage.
          Leave empty for AWS S3.
        '';
        default = "";
        example = "http://localhost:9000";
      };
    };

    # ==========================================================================
    # Sentry Configuration (Optional)
    # ==========================================================================
    sentry = {
      dsn = lib.mkOption {
        type = lib.types.str;
        description = "Sentry DSN for error tracking. Leave empty to disable.";
        default = "";
        example = "https://xxx@sentry.io/xxx";
      };
    };

    # ==========================================================================
    # Celery Configuration (Optional - for background tasks)
    # ==========================================================================
    celery = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Enable Celery worker for background task processing.
          
          When enabled, the following features become available:
          - Push notifications to mobile apps
          - Data processing pipelines
          - Forest analysis integration
          
          Requires RabbitMQ to be running and accessible.
        '';
        default = false;
      };

      rabbitmq = {
        host = lib.mkOption {
          type = lib.types.str;
          description = "RabbitMQ host for Celery broker.";
          default = "127.0.0.1";
          example = "rabbitmq.example.com";
        };

        port = lib.mkOption {
          type = lib.types.int;
          description = "RabbitMQ port.";
          default = 5672;
        };

        user = lib.mkOption {
          type = lib.types.str;
          description = "RabbitMQ user.";
          default = "guest";
          example = "beiwe";
        };

        password = lib.mkOption {
          type = lib.types.str;
          description = "RabbitMQ password.";
          default = "guest";
          example = "secure-password";
        };

        vhost = lib.mkOption {
          type = lib.types.str;
          description = "RabbitMQ virtual host.";
          default = "";
          example = "beiwe";
        };
      };

      concurrency = lib.mkOption {
        type = lib.types.int;
        description = "Number of concurrent Celery worker processes.";
        default = 2;
      };

      queues = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          Celery queues to process. Beiwe uses separate queues for different tasks:
          - celery (default queue)
          - data_processing
          - push_notifications
          - forest
        '';
        default = [ "celery" "data_processing" "push_notifications" "forest" ];
      };

      logLevel = lib.mkOption {
        type = lib.types.enum [ "DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL" ];
        description = "Celery worker log level.";
        default = "INFO";
      };
    };

    # ==========================================================================
    # Gunicorn Configuration
    # ==========================================================================
    gunicorn = {
      workers = lib.mkOption {
        type = lib.types.int;
        description = "Number of Gunicorn worker processes.";
        default = 4;
      };

      threads = lib.mkOption {
        type = lib.types.int;
        description = "Number of threads per worker.";
        default = 2;
      };

      timeout = lib.mkOption {
        type = lib.types.int;
        description = "Request timeout in seconds.";
        default = 120;
      };
    };

    # ==========================================================================
    # Extra Environment Variables
    # ==========================================================================

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = ''
        Additional environment variables for beiwe-backend.
        These are passed directly to the service.
      '';
      default = {};
      example = lib.literalExpression ''
        {
          DEBUG = "false";
        }
      '';
    };

    # ==========================================================================
    # Reverse Proxy Configuration
    # ==========================================================================

    reverseProxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "Enable nginx reverse proxy for beiwe-backend.";
        default = false;
      };

      hostName = lib.mkOption {
        type = lib.types.str;
        description = "Hostname for the reverse proxy.";
        default = "localhost";
        example = "beiwe.example.com";
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
    # Beiwe User and Group
    # ==========================================================================

    users.users.beiwe = {
      isSystemUser = true;
      group = "beiwe";
      home = cfg.dataDir;
      createHome = true;
      description = "Beiwe backend service user";
    };

    users.groups.beiwe = {};

    # ==========================================================================
    # Beiwe Backend Systemd Service (Web Server)
    # ==========================================================================

    systemd.services.beiwe-backend = {
      description = "Beiwe Backend - Digital Phenotyping Research Platform";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "postgresql.service" ] ++ 
        lib.optionals cfg.reverseProxy.enable [ "nginx.service" ] ++
        lib.optionals cfg.celery.enable [ "rabbitmq.service" ];
      wants = lib.optionals cfg.database.createLocally [
        "beiwe-db-setup.service"
      ];
      requires = lib.optionals cfg.database.createLocally [
        "postgresql.service"
      ];

      environment = beiweEnvironment;

      # Load database password from secret file if specified
      serviceConfig = {
        Type = "simple";
        User = "beiwe";
        Group = "beiwe";
        WorkingDirectory = "${beiwePackage}/lib/beiwe-backend";
        
        ExecStartPre = let
          preStartScript = pkgs.writeShellScript "beiwe-pre-start" ''
            # Run database migrations
            ${beiwePackage}/bin/beiwe-manage migrate --noinput || true
          '';
        in "+${preStartScript}";
        
        ExecStart = ''
          ${beiwePackage}/bin/beiwe-gunicorn wsgi:application \
            --bind ${cfg.bindToIp}:${toString cfg.bindToPort} \
            --workers ${toString cfg.gunicorn.workers} \
            --threads ${toString cfg.gunicorn.threads} \
            --timeout ${toString cfg.gunicorn.timeout} \
            --access-logfile - \
            --error-logfile -
        '';
        
        Restart = "on-failure";
        RestartSec = "5s";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
      } // (lib.optionalAttrs (cfg.database.passwordSecretName != null) {
        EnvironmentFile = "/run/secrets/${cfg.database.passwordSecretName}";
      });
    };

    # ==========================================================================
    # Beiwe Celery Worker Service (Background Task Processing)
    # ==========================================================================
    # 
    # Uses jhsware fork which supports CELERY_MANAGER_IP and CELERY_PASSWORD
    # environment variables instead of requiring a manager_ip file.

    systemd.services.beiwe-celery-worker = lib.mkIf cfg.celery.enable {
      description = "Beiwe Celery Worker - Background Task Processing";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "postgresql.service" "rabbitmq.service" ];
      requires = [ "rabbitmq.service" ];
      wants = [ "beiwe-backend.service" ];

      environment = beiweEnvironment;

      serviceConfig = {
        Type = "simple";
        User = "beiwe";
        Group = "beiwe";
        WorkingDirectory = "${beiwePackage}/lib/beiwe-backend";
        
        # Celery command pattern from beiwe-backend wiki:
        # python3 -m celery -A services.celery_data_processing worker -Q ...
        ExecStart = let
          queuesArg = lib.concatStringsSep "," cfg.celery.queues;
        in ''
          ${beiwePackage}/bin/beiwe-celery \
            -A services.celery_data_processing \
            worker \
            --queues=${queuesArg} \
            --concurrency=${toString cfg.celery.concurrency} \
            --loglevel=${cfg.celery.logLevel}
        '';
        
        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir "/tmp" ];
      } // (lib.optionalAttrs (cfg.database.passwordSecretName != null) {
        EnvironmentFile = "/run/secrets/${cfg.database.passwordSecretName}";
      });
    };

    # ==========================================================================
    # Beiwe Celery Beat Service (Scheduled Tasks)
    # ==========================================================================

    systemd.services.beiwe-celery-beat = lib.mkIf cfg.celery.enable {
      description = "Beiwe Celery Beat - Task Scheduler";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "rabbitmq.service" "beiwe-celery-worker.service" ];
      requires = [ "rabbitmq.service" ];
      wants = [ "beiwe-celery-worker.service" ];

      environment = beiweEnvironment;

      serviceConfig = {
        Type = "simple";
        User = "beiwe";
        Group = "beiwe";
        WorkingDirectory = "${beiwePackage}/lib/beiwe-backend";
        
        ExecStart = ''
          ${beiwePackage}/bin/beiwe-celery \
            -A services.celery_data_processing \
            beat \
            --loglevel=${cfg.celery.logLevel} \
            --schedule=${cfg.dataDir}/celerybeat-schedule
        '';
        
        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
      } // (lib.optionalAttrs (cfg.database.passwordSecretName != null) {
        EnvironmentFile = "/run/secrets/${cfg.database.passwordSecretName}";
      });
    };

    # ==========================================================================
    # PostgreSQL Database Setup (Optional)
    # ==========================================================================

    systemd.services.beiwe-db-setup = lib.mkIf cfg.database.createLocally {
      description = "Create Beiwe database and user";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      before = [ "beiwe-backend.service" ];
      requiredBy = [ "beiwe-backend.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      script = let
        dbUser = cfg.database.user;
        dbName = cfg.database.name;
        dbHost = cfg.database.host;
        dbPort = toString cfg.database.port;
      in ''
        set -euo pipefail
        
        # Wait for PostgreSQL to be ready
        echo "Waiting for PostgreSQL to be ready..."
        until ${pkgs.postgresql}/bin/pg_isready -h ${dbHost} -p ${dbPort} 2>/dev/null; do
          sleep 1
        done
        echo "PostgreSQL is ready"
        
        # Create database user if it doesn't exist
        echo "Checking if user '${dbUser}' exists..."
        if ! ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -tAc "SELECT 1 FROM pg_roles WHERE rolname='${dbUser}'" | grep -q 1; then
          echo "Creating user '${dbUser}'..."
          ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -c "CREATE USER ${dbUser}"
        else
          echo "User '${dbUser}' already exists"
        fi
        
        # Create database if it doesn't exist
        echo "Checking if database '${dbName}' exists..."
        if ! ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -tAc "SELECT 1 FROM pg_database WHERE datname='${dbName}'" | grep -q 1; then
          echo "Creating database '${dbName}'..."
          ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -c "CREATE DATABASE ${dbName} OWNER ${dbUser}"
        else
          echo "Database '${dbName}' already exists"
        fi
        
        # Grant privileges on database (idempotent)
        echo "Granting privileges..."
        ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -c "GRANT ALL PRIVILEGES ON DATABASE ${dbName} TO ${dbUser}" || true
        ${pkgs.postgresql}/bin/psql -h ${dbHost} -p ${dbPort} -d ${dbName} -c "GRANT ALL ON SCHEMA public TO ${dbUser}" || true
        
        echo "Database setup complete"
      '';
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
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout ${toString cfg.gunicorn.timeout}s;
            proxy_connect_timeout ${toString cfg.gunicorn.timeout}s;
            client_max_body_size 100M;
          '';
        };

        # Static files
        locations."/static/" = {
          alias = "${beiwePackage}/lib/beiwe-backend/frontend/static/";
          extraConfig = ''
            expires 30d;
            add_header Cache-Control "public, immutable";
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
    # Utilities
    # ==========================================================================

    environment.systemPackages = [
      beiwePackage
      pkgs.curl
      pkgs.jq
    ];
  };
}
