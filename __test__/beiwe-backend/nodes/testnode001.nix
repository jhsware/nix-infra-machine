{ config, pkgs, lib, ... }: {
  imports = [
    # Import based on file structure on deployed machine
    ./app_modules/_unstable/beiwe-backend/default.nix
  ];

  # ==========================================================================
  # PostgreSQL Database for Beiwe (using infrastructure module)
  # ==========================================================================
  config.infrastructure.postgresql = {
    enable = true;
    bindToIp = "127.0.0.1";
    bindToPort = 5432;
    # Note: Do NOT use initialDatabases here - beiwe-db-setup.service creates
    # the database when database.createLocally = true. Using both causes race conditions.
    authentication = ''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      local   all             all                                     trust
      host    all             all             127.0.0.1/32            trust
      host    all             all             ::1/128                 trust
    '';
  };

  # ==========================================================================
  # MinIO for S3-compatible storage (using infrastructure module)
  # ==========================================================================
  config.infrastructure.minio = {
    enable = true;
    bindToIp = "127.0.0.1";
    apiPort = 9000;
    consolePort = 9001;
    rootCredentialsSecretName = "minio-credentials";
    dataDir = [ "/var/lib/minio/data" ];
  };

  # Create MinIO credentials file
  config.systemd.services.minio-create-credentials = {
    description = "Create MinIO credentials file";
    wantedBy = [ "multi-user.target" ];
    before = [ "minio.service" ];
    requiredBy = [ "minio.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/secrets
      cat > /run/secrets/minio-credentials <<EOF
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin123
EOF
      chmod 400 /run/secrets/minio-credentials
    '';
  };

  # Create the beiwe-data bucket after MinIO starts
  config.systemd.services.minio-create-bucket = {
    description = "Create Beiwe S3 bucket in MinIO";
    wantedBy = [ "multi-user.target" ];
    after = [ "minio.service" ];
    requires = [ "minio.service" ];
    before = [ "beiwe-backend.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Set HOME so mc can store its config
      Environment = "HOME=/tmp/minio-bucket-setup";
    };
    path = [ pkgs.minio-client pkgs.curl ];
    script = ''
      # Create temp home for mc config
      mkdir -p /tmp/minio-bucket-setup
      export HOME=/tmp/minio-bucket-setup
      
      # Wait for MinIO to be ready (both health check AND API responding)
      echo "Waiting for MinIO to be ready..."
      for i in {1..60}; do
        if curl -sf http://127.0.0.1:9000/minio/health/live > /dev/null 2>&1; then
          # Also check that the API is responding
          if curl -sf http://127.0.0.1:9000/minio/health/ready > /dev/null 2>&1; then
            echo "MinIO is ready"
            break
          fi
        fi
        echo "Waiting... attempt $i/60"
        sleep 1
      done
      
      # Give MinIO a moment to fully initialize
      sleep 2
      
      # Configure mc client with explicit alias
      echo "Configuring mc client..."
      mc alias set local http://127.0.0.1:9000 minioadmin minioadmin123 --api S3v4
      
      # List existing buckets for debugging
      echo "Existing buckets:"
      mc ls local/ || echo "(no buckets yet)"
      
      # Create bucket if it doesn't exist
      echo "Creating beiwe-data bucket..."
      mc mb local/beiwe-data --ignore-existing || true
      
      # Verify bucket was created
      echo "Verifying bucket creation..."
      mc ls local/beiwe-data
      
      echo "Bucket setup complete"
    '';
  };


  # ==========================================================================
  # RabbitMQ for Celery task queue (using infrastructure module)
  # ==========================================================================
  config.infrastructure.rabbitmq = {
    enable = true;
    bindToIp = "127.0.0.1";
    bindToPort = 5672;
    managementPlugin = {
      enable = true;
      port = 15672;
    };
  };

  # ==========================================================================
  # Beiwe Backend Configuration
  # ==========================================================================
  config.infrastructure.beiwe-backend = {
    enable = true;

    # Network settings
    bindToIp = "0.0.0.0";
    bindToPort = 8080;
    openFirewall = true;
    domainName = "localhost:8080";

    # Security (test values - DO NOT use in production!)
    flaskSecretKey = "test-secret-key-not-for-production-use";
    sysadminEmails = "test@localhost";

    # Database configuration (local PostgreSQL)
    database = {
      host = "localhost";  # Use TCP connection instead of socket
      port = 5432;
      name = "beiwe";
      user = "beiwe";
      password = "unused_with_trust_auth";  # Required by Beiwe even with trust auth
      sslmode = "disable";  # Disable SSL for local development without certificates
      createLocally = true;
    };

    # S3 configuration (local MinIO)
    s3 = {
      bucket = "beiwe-data";
      accessKeyId = "minioadmin";
      secretAccessKey = "minioadmin123";
      endpoint = "http://127.0.0.1:9000";
    };

    # Celery configuration (local RabbitMQ)
    celery = {
      enable = true;
      rabbitmq = {
        host = "127.0.0.1";
        port = 5672;
        user = "guest";
        password = "guest";
        vhost = "";
      };
      concurrency = 2;
      logLevel = "INFO";
    };

    # Gunicorn settings
    gunicorn = {
      workers = 2;
      threads = 2;
      timeout = 120;
    };
  };

  # ==========================================================================
  # Service Dependencies
  # ==========================================================================
  
  # Ensure beiwe-backend starts after all dependencies
  config.systemd.services.beiwe-backend = {
    after = [ 
      "postgresql.service" 
      "minio.service"
      "minio-create-bucket.service"
      "beiwe-db-setup.service"
      "rabbitmq.service"
    ];
    wants = [
      "minio-create-bucket.service"
    ];
  };

  # Ensure celery worker starts after RabbitMQ is ready
  config.systemd.services.beiwe-celery-worker = {
    after = [
      "rabbitmq.service"
      "postgresql.service"
      "minio.service"
    ];
  };

  # ==========================================================================
  # Test utilities
  # ==========================================================================
  config.environment.systemPackages = with pkgs; [
    curl
    jq
    minio-client
    postgresql
  ];
}

# ==========================================================================
# NOTES ON SERVICES
# ==========================================================================
#
# REQUIRED SERVICES (all configured):
#
# 1. PostgreSQL (Database)
#    - Status: CONFIGURED via infrastructure.postgresql
#    - Purpose: Stores all application data, user accounts, study configurations
#
# 2. MinIO/S3 (Object Storage)
#    - Status: CONFIGURED via infrastructure.minio
#    - Purpose: Stores uploaded data files from mobile apps
#
# OPTIONAL SERVICES:
#
# 3. RabbitMQ + Celery (Message Queue)
#    - Status: CONFIGURED via infrastructure.rabbitmq + celery options
#    - Purpose: Background task processing
#    - Enables:
#      * Push notifications to mobile apps
#      * Data processing pipelines
#      * Forest analysis integration
#
# 4. Firebase Credentials
#    - Status: N/A (credentials, not a service)
#    - Impact: Push notifications to iOS devices won't work
#    - To add: Contact Onnela Lab for credentials, configure via environment vars
#
# 5. Sentry Error Tracking
#    - Status: N/A (external service)
#    - Impact: No centralized error tracking
#    - To add: Create Sentry.io account, add DSN to config.infrastructure.beiwe-backend.sentry.dsn
#
# WHAT WORKS WITH THIS CONFIGURATION:
# - Web-based study management portal
# - User authentication and management
# - Study configuration
# - Survey creation and management
# - Participant registration
# - Data uploads from mobile apps (stored in S3/MinIO)
# - Basic API endpoints
# - Background task processing (with Celery enabled)
# - Push notifications (requires Firebase credentials)
# - Data processing pipelines
#
