{ config, pkgs, lib, ... }:
let
  appName = "mongodb";
  defaultPort = 27017;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.mongodb";

    package = lib.mkOption {
      type = lib.types.package;
      description = "MongoDB package to use.";
      default = pkgs.mongodb-ce;
      example = "pkgs.mongodb";
    };

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
  };

  config = lib.mkIf cfg.enable {
    services.mongodb = {
      enable = true;
      package = cfg.package;
      bind_ip = cfg.bindToIp;
      extraConfig = lib.mkIf (cfg.bindToPort != defaultPort) ''
        net.port: ${toString cfg.bindToPort}
      '';
    };

    # Install mongosh for CLI access
    environment.systemPackages = [ pkgs.mongosh ];

    # Open firewall for MongoDB if binding to non-localhost
    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.bindToIp != "127.0.0.1") [ cfg.bindToPort ];
  };
}
