{ config, pkgs, lib, ... }: {
  # Enable podman for container runtime
  config.infrastructure.podman.enable = true;

  # Enable n8n as container-based instance
  config.infrastructure.n8n-pod = {
    enable = true;
    
    # Use official n8n Docker image
    # image = "docker.n8n.io/n8nio/n8n:latest";  # Default
    
    # Network settings
    bindToIp = "0.0.0.0";
    bindToPort = 5678;
    openFirewall = true;

    # Use SQLite database (default)
    database = {
      type = "sqlite";
    };

    # Execution settings
    executions = {
      pruneData = true;
      pruneDataMaxAge = 168;  # 7 days for testing
      pruneDataMaxCount = 1000;
    };

    # Additional settings (environment variables)
    settings = {
      GENERIC_TIMEZONE = "UTC";
    };
  };

  # Test utilities
  config.environment.systemPackages = with pkgs; [
    curl
    jq
  ];
}
