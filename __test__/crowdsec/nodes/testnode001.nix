{ config, pkgs, lib, ... }: {
  imports = [
    # Import based on file structure on deployed machine
    ./app_modules/_unstable/crowdsec/default.nix
  ];

  # Enable CrowdSec using the infrastructure module
  infrastructure.crowdsec = {
    enable = true;
    
    # API Configuration
    api = {
      listenAddr = "127.0.0.1";
      listenPort = 8080;
    };
    
    # Feature toggles
    features = {
      # Enable SSH brute-force protection
      sshProtection = true;
      
      # Disable nginx protection (not installed in test)
      nginxProtection = false;
      
      # Enable system/kernel protection
      systemProtection = true;
      
      # Disable firewall bouncer (package not available in NixOS 25.05)
      firewallBouncer = false;
      
      # Enable community blocklists (requires enrollment in production)
      communityBlocklists = true;
    };
    
    # Console enrollment (disabled for test - would need valid key)
    console = {
      enrollKeyFile = null;
      shareDecisions = false;
    };
    
    # Bouncer configuration (for when enabled)
    bouncer = {
      denyAction = "DROP";
      denyLog = true;
      denyLogPrefix = "crowdsec-test: ";
      banDuration = "4h";
    };
  };
}
