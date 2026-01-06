{ config, pkgs, lib, ... }:
let
  appName = "minio";
  defaultApiPort = 9000;
  defaultConsolePort = 9001;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.minio";

    package = lib.mkOption {
      type = lib.types.package;
      description = "MinIO package to use.";
      default = pkgs.minio;
      example = "pkgs.minio";
    };

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind.";
      default = "127.0.0.1";
    };

    apiPort = lib.mkOption {
      type = lib.types.int;
      description = "Port for S3 API.";
      default = defaultApiPort;
    };

    consolePort = lib.mkOption {
      type = lib.types.int;
      description = "Port for web console.";
      default = defaultConsolePort;
    };

    dataDir = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Data directories for MinIO storage.";
      default = [ "/var/lib/minio/data" ];
      example = [ "/var/lib/minio/data1" "/var/lib/minio/data2" ];
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      description = "Configuration directory for MinIO.";
      default = "/var/lib/minio/config";
    };

    rootCredentialsSecretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of the secret containing root credentials.
        The secret file should contain:
        MINIO_ROOT_USER=<user>
        MINIO_ROOT_PASSWORD=<password>
        
        The secret will be loaded from:
        /run/secrets/<secretName>
      '';
      example = "minio-root-credentials";
    };

    region = lib.mkOption {
      type = lib.types.str;
      description = "Region for MinIO server.";
      default = "us-east-1";
    };

    browser = lib.mkOption {
      type = lib.types.bool;
      description = "Enable or disable the web browser console.";
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    services.minio = {
      enable = true;
      package = cfg.package;
      listenAddress = "${cfg.bindToIp}:${toString cfg.apiPort}";
      consoleAddress = "${cfg.bindToIp}:${toString cfg.consolePort}";
      dataDir = cfg.dataDir;
      configDir = cfg.configDir;
      rootCredentialsFile = "/run/secrets/${cfg.rootCredentialsSecretName}";
      region = cfg.region;
      browser = cfg.browser;
    };

    # Install MinIO client for CLI access
    environment.systemPackages = [ pkgs.minio-client pkgs.curl pkgs.jq ];

    # Open firewall for MinIO if binding to non-localhost
    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.bindToIp != "127.0.0.1") [ 
      cfg.apiPort 
      cfg.consolePort 
    ];
  };
}
