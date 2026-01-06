{ config, pkgs, lib, ... }: {
  # Enable podman for container runtime
  config.infrastructure.podman.enable = true;

  # Enable MongoDB standalone instance (container-based)
  config.infrastructure.mongodb-pod = {
    enable = true;
    # image = "mongo:6";  # Default, or use "mongo:4.4.29-focal" for older version
    bindToIp = "127.0.0.1";
    bindToPort = 27017;
  };

  # Open firewall for MongoDB (only if external access needed)
  # config.networking.firewall.allowedTCPPorts = [ 27017 ];
}
