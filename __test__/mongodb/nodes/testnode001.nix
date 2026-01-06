{ config, pkgs, lib, ... }: {
  # Allow insecure MongoDB package (CVE-2025-14847)
  nixpkgs.config.permittedInsecurePackages = [
    "mongodb-ce-8.0.4"
  ];

  # Enable MongoDB using the infrastructure module
  infrastructure.mongodb = {
    enable = true;
    bindToIp = "127.0.0.1";
    bindToPort = 27018;
  };
}
