{ config, pkgs, lib, ... }: {
  imports = [
    # Import based on file structure on deployed machine
    ./app_modules/_unstable/n8n/default.nix
  ];

  # ==========================================================================
  # Swap Configuration (for memory-intensive n8n builds)
  # ==========================================================================
  config.swapDevices = [{
    device = "/swapfile";
    size = 4096;  # 4GB swap
  }];

  # ==========================================================================
  # Nix Build Settings (limit parallelism to avoid OOM during n8n build)
  # ==========================================================================
  config.nix.settings = {
    # Only one build job at a time
    max-jobs = 6;
    # Limit cores per build job
    cores = 6;
  };

  # ==========================================================================
  # n8n Configuration (using infrastructure module with SQLite)
  # ==========================================================================
  config.infrastructure.n8n = {
    enable = true;

    # Reduce build memory to leave room for system (default: 4096)
    buildMemoryMB = 8192;

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
      # Enable public API for testing
      N8N_PUBLIC_API_ENABLED = "true";
    };

  };

  # ==========================================================================
  # Test utilities
  # ==========================================================================
  config.environment.systemPackages = with pkgs; [
    curl
    jq
  ];
}
