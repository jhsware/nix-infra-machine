{ config, pkgs, lib, ... }: {
  # Enable MinIO standalone instance using native NixOS service
  config.infrastructure.minio = {
    enable = true;
    bindToIp = "127.0.0.1";
    apiPort = 9002;
    consolePort = 9003;
    dataDir = [ "/var/lib/minio/data" ];
    configDir = "/var/lib/minio/config";
    rootCredentialsSecretName = "minio-root-credentials";
    region = "us-east-1";
    browser = true;
  };

  # Install MinIO client and utilities for testing
  config.environment.systemPackages = with pkgs; [
    minio-client
    curl
    jq
  ];

  # Open firewall for MinIO (only if external access needed)
  # config.networking.firewall.allowedTCPPorts = [ 9002 9003 ];
}
