{ config, pkgs, lib, ... }:
let
  appName = "mariadb";
  appPort = 3306;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.mariadb";

    package = lib.mkOption {
      type = lib.types.package;
      description = "MariaDB package to use.";
      default = pkgs.mariadb;
      example = "pkgs.mariadb_110";
    };

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind.";
      default = "127.0.0.1";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "Port to bind.";
      default = appPort;
    };

    initialDatabases = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Database name.";
          };
          schema = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            description = "Path to SQL schema file to import.";
            default = null;
          };
        };
      });
      description = "List of databases to create on initialization.";
      default = [];
      example = [ { name = "myapp"; } { name = "testdb"; schema = ./schema.sql; } ];
    };

    ensureUsers = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "User name.";
          };
          ensurePermissions = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            description = "Permissions to grant to the user.";
            default = {};
            example = { "*.*" = "ALL PRIVILEGES"; };
          };
        };
      });
      description = ''
        List of users to ensure exist. Users are created with Unix socket 
        authentication by default (no password required for local connections
        when the system username matches the MySQL username).
      '';
      default = [];
      example = [ { name = "myuser"; ensurePermissions = { "mydb.*" = "ALL PRIVILEGES"; }; } ];
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = "Additional MariaDB settings.";
      default = {};
      example = {
        max_connections = 200;
        innodb_buffer_pool_size = "1G";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.mysql = {
      enable = true;
      package = cfg.package;
      
      settings = {
        mysqld = {
          bind-address = cfg.bindToIp;
          port = cfg.bindToPort;
        } // cfg.settings;
      };

      # Create initial databases if specified
      initialDatabases = cfg.initialDatabases;

      # Create users if specified
      ensureUsers = cfg.ensureUsers;
    };

    # Open firewall for MariaDB if binding to non-localhost
    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.bindToIp != "127.0.0.1") [ cfg.bindToPort ];
  };
}
