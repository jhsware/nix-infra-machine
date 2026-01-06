{ config, pkgs, lib, ... }:
let
  appName = "postgresql";
  appPort = 5432;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.postgresql";

    package = lib.mkOption {
      type = lib.types.package;
      description = "PostgreSQL package to use.";
      default = pkgs.postgresql_16;
      example = "pkgs.postgresql_15";
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
      type = lib.types.listOf lib.types.str;
      description = "List of databases to create on initialization.";
      default = [];
      example = [ "myapp" "testdb" ];
    };

    authentication = lib.mkOption {
      type = lib.types.lines;
      description = "pg_hba.conf authentication rules.";
      default = ''
        # TYPE  DATABASE        USER            ADDRESS                 METHOD
        local   all             all                                     trust
        host    all             all             127.0.0.1/32            trust
        host    all             all             ::1/128                 trust
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      package = cfg.package;
      enableTCPIP = true;
      
      authentication = cfg.authentication;

      settings = {
        port = lib.mkDefault cfg.bindToPort;
        listen_addresses = lib.mkDefault cfg.bindToIp;
      };

      # Create initial databases if specified
      ensureDatabases = cfg.initialDatabases;
    };

    # Open firewall for PostgreSQL if binding to non-localhost
    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.bindToIp != "127.0.0.1") [ cfg.bindToPort ];
  };
}