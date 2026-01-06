{ config, pkgs, lib, ... }: {
  imports = [
    # CrowdSec module with modular structure:
    # - default.nix: Core engine and detection features
    # - bouncers/firewall.nix: Firewall bouncer (nftables/iptables/ipset)
    # - bouncers/haproxy.nix: HAProxy SPOA bouncer
    # - bouncers/python.nix: Python bouncer registration for pycrowdsec
    # - integrations/auditd.nix: Linux Audit Framework integration
    # - integrations/console.nix: CrowdSec Console cloud enrollment
    ./app_modules/_unstable/crowdsec/default.nix
  ];

  # ==========================================================================
  # CrowdSec Configuration
  # ==========================================================================
  infrastructure.crowdsec = {
    enable = true;
    
    # --------------------------------------------------------------------------
    # Core Configuration (from default.nix)
    # --------------------------------------------------------------------------
    
    # API Configuration - Local API (LAPI) settings
    api = {
      listenAddr = "127.0.0.1";
      listenPort = 8080;
    };
    
    # Detection Features - What log sources to monitor
    features = {
      # Enable SSH brute-force protection (monitors journalctl for sshd.service)
      sshProtection = true;
      
      # Disable nginx protection (not installed in test environment)
      nginxProtection = false;
      
      # Enable system/kernel protection (monitors kernel logs)
      systemProtection = true;
      
      # Enable community blocklists (requires console enrollment in production)
      communityBlocklists = true;
      
      # --------------------------------------------------------------------------
      # Firewall Bouncer (from bouncers/firewall.nix)
      # --------------------------------------------------------------------------
      # Enable firewall bouncer to block malicious IPs at network level
      # Available in NixOS 25.11+ via pkgs.crowdsec-firewall-bouncer
      firewallBouncer = true;
      
      # --------------------------------------------------------------------------
      # HAProxy Bouncer (from bouncers/haproxy.nix)
      # --------------------------------------------------------------------------
      # Disable HAProxy protection (no HAProxy service in test environment)
      # The module handles missing packages gracefully (defaults to null)
      haproxyProtection = false;
    };
    
    # --------------------------------------------------------------------------
    # Firewall Bouncer Settings (from bouncers/firewall.nix)
    # --------------------------------------------------------------------------
    bouncer = {
      # Use nftables mode with declarative table integration
      mode = "nftables";
      nftablesIntegration = true;
      
      # Block action and logging
      denyAction = "DROP";
      denyLog = true;
      denyLogPrefix = "crowdsec-test: ";
      
      # Default ban duration
      banDuration = "4h";
    };
    
    # --------------------------------------------------------------------------
    # HAProxy Bouncer Settings (from bouncers/haproxy.nix)
    # --------------------------------------------------------------------------
    # These settings would apply if haproxyProtection were enabled
    # and the cs-haproxy-spoa-bouncer package were available
    haproxy = {
      listenAddr = "127.0.0.1";
      listenPort = 3000;
      action = "deny";
      logLevel = "info";
    };
    
    # --------------------------------------------------------------------------
    # Console Integration (from integrations/console.nix)
    # --------------------------------------------------------------------------
    # Cloud enrollment disabled for test - would need valid enrollment key
    console = {
      enrollKeyFile = null;
      shareDecisions = false;
    };
    
    # --------------------------------------------------------------------------
    # Auditd Integration (from integrations/auditd.nix)
    # --------------------------------------------------------------------------
    # Kernel-level security monitoring via Linux Audit Framework
    auditd = {
      enable = true;
      
      # Custom audit rules for sensitive files
      # Note: nixWrappersWhitelistProcess is currently disabled due to
      # auditd compatibility issues with the 'comm' field filter
      rules = [
        "-w /etc/passwd -p wa -k identity"
        "-w /etc/shadow -p wa -k identity"
        "-w /etc/group -p wa -k identity"
        "-w /etc/sudoers -p wa -k sudoers"
      ];
    };
    
    # --------------------------------------------------------------------------
    # Python Bouncer (from bouncers/python.nix)
    # --------------------------------------------------------------------------
    # Disabled for test - enable for Python web application integration
    # python = {
    #   enable = true;
    #   bouncerName = "my-flask-app";
    #   apiKeyFileGroup = "www-data";
    # };
  };
}
