{ config, pkgs, lib, ... }: {
  # ==========================================================================
  # Home Assistant Configuration (using infrastructure module)
  # ==========================================================================
  config.infrastructure.home-assistant = {
    enable = true;
    
    # Network settings
    bindToIp = "0.0.0.0";
    bindToPort = 8123;
    openFirewall = true;

    # Configuration directory
    configDir = "/var/lib/hass";
    configWritable = true;

    # Components for testing
    extraComponents = [
      # Required for onboarding
      "esphome"
      "met"
      "radio_browser"
    ];

    # Home Assistant configuration
    config = {
      # Basic setup - includes dependencies for a basic setup
      default_config = {};
      
      # Core homeassistant settings
      homeassistant = {
        name = "Test Home";
        unit_system = "metric";
        time_zone = "UTC";
      };

      # HTTP configuration
      http = {
        server_host = "0.0.0.0";
        server_port = 8123;
      };

      # Enable logging for debugging
      logger = {
        default = "info";
        logs = {
          "homeassistant.core" = "debug";
        };
      };
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
