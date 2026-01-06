{ config, pkgs, lib, ... }:
let
  appName = "redis";
  defaultPort = 6379;

  cfg = config.infrastructure.${appName};

  # Server options submodule
  serverOptions = { name, ... }: {
    options = {
      enable = lib.mkEnableOption "this Redis server instance" // { default = true; };

      bindToIp = lib.mkOption {
        type = lib.types.str;
        description = "IP address to bind.";
        default = "127.0.0.1";
      };

      bindToPort = lib.mkOption {
        type = lib.types.int;
        description = "Port to bind.";
        default = defaultPort;
      };

      maxMemory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = "Maximum memory Redis can use (e.g., '256mb', '1gb'). Null for unlimited.";
        default = null;
        example = "256mb";
      };

      maxMemoryPolicy = lib.mkOption {
        type = lib.types.enum [ "noeviction" "allkeys-lru" "volatile-lru" "allkeys-random" "volatile-random" "volatile-ttl" ];
        description = "Policy for handling keys when maxMemory is reached.";
        default = "noeviction";
      };

      requirePass = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = "Password for Redis authentication. Null for no authentication.";
        default = null;
      };

      databases = lib.mkOption {
        type = lib.types.int;
        description = "Number of databases to configure.";
        default = 16;
      };

      appendOnly = lib.mkOption {
        type = lib.types.bool;
        description = "Enable append-only file persistence.";
        default = false;
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        description = "Open firewall for this Redis instance.";
        default = false;
      };
    };
  };

  # Filter enabled servers
  enabledServers = lib.filterAttrs (name: serverCfg: serverCfg.enable) cfg.servers;
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.redis";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Redis package to use.";
      default = pkgs.redis;
      example = "pkgs.redis";
    };

    servers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule serverOptions);
      description = ''
        Named Redis server instances.
        Each server creates a systemd service named redis-<name>.service.
        Use an empty string "" for the default server (redis.service).
      '';
      default = {};
      example = lib.literalExpression ''
        {
          "" = {
            bindToPort = 6379;
          };
          nextcloud = {
            bindToPort = 6380;
            maxMemory = "256mb";
          };
          cache = {
            bindToPort = 6381;
            maxMemory = "512mb";
            maxMemoryPolicy = "allkeys-lru";
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Set the package at the top level
    services.redis.package = cfg.package;

    # Create each enabled server
    services.redis.servers = lib.mapAttrs (name: serverCfg: {
      enable = true;
      bind = serverCfg.bindToIp;
      port = serverCfg.bindToPort;
      databases = serverCfg.databases;
      appendOnly = serverCfg.appendOnly;
      requirePass = serverCfg.requirePass;
      settings = lib.mkMerge [
        (lib.mkIf (serverCfg.maxMemory != null) {
          maxmemory = serverCfg.maxMemory;
          maxmemory-policy = serverCfg.maxMemoryPolicy;
        })
      ];
    }) enabledServers;

    # Install redis-cli for CLI access
    environment.systemPackages = [ cfg.package ];

    # Open firewall for servers that request it
    networking.firewall.allowedTCPPorts = lib.pipe enabledServers [
      (lib.filterAttrs (name: serverCfg: serverCfg.openFirewall))
      (lib.mapAttrsToList (name: serverCfg: serverCfg.bindToPort))
    ];
  };
}
