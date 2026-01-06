{ config, pkgs, lib, ... }:
let
  appName = "nextcloud";
  defaultPort = 80;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.nextcloud";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Nextcloud package to use.";
      default = pkgs.nextcloud31;
      example = "pkgs.nextcloud30";
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Hostname for Nextcloud.";
      default = "localhost";
      example = "cloud.example.com";
    };

    https = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to use HTTPS.";
      default = false;
    };

    # ==========================================================================
    # Admin Configuration
    # ==========================================================================

    admin = {
      user = lib.mkOption {
        type = lib.types.str;
        description = "Admin username.";
        default = "admin";
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing admin password.";
      };
    };

    # ==========================================================================
    # Database Configuration
    # ==========================================================================

    database = {
      type = lib.mkOption {
        type = lib.types.enum [ "sqlite" "pgsql" "mysql" ];
        description = "Database type to use.";
        default = "pgsql";
      };

      name = lib.mkOption {
        type = lib.types.str;
        description = "Database name.";
        default = "nextcloud";
      };

      user = lib.mkOption {
        type = lib.types.str;
        description = "Database user.";
        default = "nextcloud";
      };

      host = lib.mkOption {
        type = lib.types.str;
        description = "Database host. Use socket path for local connections.";
        default = "/run/postgresql";
        example = "127.0.0.1";
      };

      createLocally = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether to create the database and user locally.
          Only works for PostgreSQL and MySQL/MariaDB when using socket authentication.
        '';
        default = true;
      };
    };

    # ==========================================================================
    # Caching Configuration
    # ==========================================================================

    caching = {
      redis = lib.mkOption {
        type = lib.types.bool;
        description = "Enable Redis for caching and file locking.";
        default = false;
      };

      apcu = lib.mkOption {
        type = lib.types.bool;
        description = "Enable APCu for local caching.";
        default = true;
      };

      memcached = lib.mkOption {
        type = lib.types.bool;
        description = "Enable Memcached for distributed caching.";
        default = false;
      };
    };

    # ==========================================================================
    # PHP Configuration
    # ==========================================================================

    maxUploadSize = lib.mkOption {
      type = lib.types.str;
      description = "Maximum upload size.";
      default = "512M";
      example = "1G";
    };

    phpOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Additional PHP options.";
      default = {};
      example = {
        "opcache.interned_strings_buffer" = "16";
        "opcache.max_accelerated_files" = "10000";
      };
    };

    # ==========================================================================
    # Extra Configuration
    # ==========================================================================

    extraApps = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      description = "Extra Nextcloud apps to install.";
      default = {};
      example = lib.literalExpression ''
        with config.services.nextcloud.package.packages.apps; {
          inherit calendar contacts notes;
        }
      '';
    };

    extraAppsEnable = lib.mkOption {
      type = lib.types.bool;
      description = "Automatically enable extra apps.";
      default = true;
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = ''
        Additional Nextcloud configuration settings.
        These are passed directly to services.nextcloud.settings.
      '';
      default = {};
      example = {
        default_phone_region = "US";
        overwriteprotocol = "https";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ==========================================================================
    # Nextcloud Service Configuration
    # ==========================================================================

    services.nextcloud = {
      enable = true;
      package = cfg.package;
      hostName = cfg.hostName;
      https = cfg.https;

      # Admin configuration
      config = {
        adminuser = cfg.admin.user;
        adminpassFile = cfg.admin.passwordFile;

        # Database configuration
        dbtype = cfg.database.type;
        dbname = cfg.database.name;
        dbuser = cfg.database.user;
        dbhost = cfg.database.host;
      };

      # Database creation
      database.createLocally = cfg.database.createLocally;

      # Caching configuration
      caching = {
        redis = cfg.caching.redis;
        apcu = cfg.caching.apcu;
        memcached = cfg.caching.memcached;
      };

      # Configure Redis for file locking if enabled
      configureRedis = cfg.caching.redis;

      # PHP settings
      maxUploadSize = cfg.maxUploadSize;
      phpOptions = {
        "opcache.enable" = "1";
        "opcache.enable_cli" = "1";
        "opcache.interned_strings_buffer" = "8";
        "opcache.max_accelerated_files" = "10000";
        "opcache.memory_consumption" = "128";
        "opcache.save_comments" = "1";
        "opcache.revalidate_freq" = "1";
      } // cfg.phpOptions;

      # Extra apps
      extraApps = cfg.extraApps;
      extraAppsEnable = cfg.extraAppsEnable;

      # Additional settings
      settings = {
        default_phone_region = "US";
        maintenance_window_start = 1;
      } // cfg.settings;
    };

    # ==========================================================================
    # Nginx Configuration (automatically enabled by Nextcloud module)
    # ==========================================================================

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
    };

    # ==========================================================================
    # Service Dependencies
    # ==========================================================================

    # Ensure Nextcloud starts after its dependencies
    systemd.services.nextcloud-setup = {
      after = lib.mkMerge [
        # Database dependencies
        (lib.mkIf (cfg.database.type == "pgsql" && cfg.database.createLocally) [ "postgresql.service" ])
        (lib.mkIf (cfg.database.type == "mysql" && cfg.database.createLocally) [ "mysql.service" ])
        # Redis dependency
        (lib.mkIf cfg.caching.redis [ "redis-nextcloud.service" ])
      ];
      requires = lib.mkMerge [
        (lib.mkIf (cfg.database.type == "pgsql" && cfg.database.createLocally) [ "postgresql.service" ])
        (lib.mkIf (cfg.database.type == "mysql" && cfg.database.createLocally) [ "mysql.service" ])
      ];
    };

    # ==========================================================================
    # Firewall Configuration
    # ==========================================================================

    networking.firewall.allowedTCPPorts = [ 80 443 ];

    # ==========================================================================
    # Utilities
    # ==========================================================================

    environment.systemPackages = with pkgs; [
      curl
    ];
  };
}
