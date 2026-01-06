{ config, pkgs, lib, ... }:
let
  appName = "mongodb-pod";
  appPort = 27017;

  cfg = config.infrastructure.${appName};

  dataDir = "/var/lib/mongodb-pod";
  execStartPreScript = pkgs.writeShellScript "preStart" ''
    ${pkgs.coreutils}/bin/mkdir -p ${dataDir}
  '';
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.mongodb-pod oci";

    image = lib.mkOption {
      type = lib.types.str;
      description = "MongoDB Docker image to use.";
      default = "mongo:6";
      example = "mongo:4.4.29-focal";
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
  };

  config = lib.mkIf cfg.enable {
    # https://stackoverflow.com/questions/42912755/how-to-create-a-db-for-mongodb-container-on-start-up
    infrastructure.oci-containers.backend = "podman";
    infrastructure.oci-containers.containers.${appName} = {
      app = {
        name = appName;
      };
      image = cfg.image;
      autoStart = true;
      ports = [
        "${cfg.bindToIp}:${toString cfg.bindToPort}:27017"
      ];
      bindToIp = cfg.bindToIp;
      volumes = [
        "${dataDir}:/data/db"
      ];

      execHooks = {
        ExecStartPre = [
          "${execStartPreScript}"
        ];
      };
    };
  };
}
