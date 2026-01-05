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
      
      # Enable firewall bouncer (now available in NixOS 25.11)
      firewallBouncer = true;
      
      # Disable HAProxy protection (package not available in standard nixpkgs)
      # Enable this when cs-haproxy-spoa-bouncer is added to nixpkgs
      haproxyProtection = false;
      
      # Enable community blocklists (requires enrollment in production)
      communityBlocklists = true;
    };
    
    # Console enrollment (disabled for test - would need valid key)
    console = {
      enrollKeyFile = null;
      shareDecisions = false;
    };
    
    # Bouncer configuration (nftables mode with declarative integration)
    bouncer = {
      mode = "nftables";
      nftablesIntegration = true;
      denyAction = "DROP";
      denyLog = true;
      denyLogPrefix = "crowdsec-test: ";
      banDuration = "4h";
    };
    
    # HAProxy SPOA bouncer configuration (for when package becomes available)
    haproxy = {
      listenAddr = "127.0.0.1";
      listenPort = 3000;
      action = "deny";
      logLevel = "info";
    };
    
    # Auditd integration for kernel-level security monitoring
    auditd = {
      enable = true;
      # Note: nixWrappersWhitelistProcess is currently disabled due to
      # auditd compatibility issues with the 'comm' field filter
      # Add custom audit rules for sensitive files
      rules = [
        "-w /etc/passwd -p wa -k identity"
        "-w /etc/shadow -p wa -k identity"
        "-w /etc/group -p wa -k identity"
        "-w /etc/sudoers -p wa -k sudoers"
      ];
    };
  };
}