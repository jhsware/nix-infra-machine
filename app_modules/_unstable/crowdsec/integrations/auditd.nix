# CrowdSec Auditd Integration Module
# Provides kernel-level security event monitoring via Linux Audit Framework
{ config, pkgs, lib, ... }:

let
  appName = "crowdsec";
  cfg = config.infrastructure.${appName};
in
{
  # ==========================================================================
  # Options
  # ==========================================================================
  options.infrastructure.${appName}.auditd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Enable auditd integration with CrowdSec.
        
        When enabled, configures auditd to send audit events to CrowdSec
        for analysis. This enables detection of:
        - Privilege escalation attempts
        - Unauthorized file access
        - System call anomalies
        - User authentication events
        
        [NIS2 COMPLIANCE]
        Article 21(2)(g) - Security Monitoring: Provides kernel-level
        visibility into security events and potential threats.
      '';
      default = false;
    };

    rules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        Additional auditd rules to configure for CrowdSec monitoring.
        
        These rules are added to the system's auditd configuration.
        
        Common rules for security monitoring:
        - File integrity: "-w /etc/passwd -p wa -k identity"
        - Privilege escalation: "-w /usr/bin/sudo -p x -k privilege"
        - Network configuration: "-w /etc/hosts -p wa -k network"
      '';
      default = [];
      example = [
        "-w /etc/passwd -p wa -k identity"
        "-w /etc/shadow -p wa -k identity"
        "-w /etc/sudoers -p wa -k privilege"
      ];
    };

    nixWrappersWhitelistProcess = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        List of process names to whitelist from auditd monitoring.
        
        NOTE: This feature is currently disabled due to compatibility issues
        with the 'comm' field filter in some versions of auditd. The option
        is preserved for future use when auditd compatibility is resolved.
        
        NixOS uses wrapper scripts in /run/wrappers/bin for setuid/setgid
        programs (like sudo, ping, etc.). These wrappers can generate a lot
        of noise in auditd logs.
        
        [NIS2 COMPLIANCE]
        Article 21(2)(g) - Security Monitoring: Reduces audit log noise
        while maintaining security visibility on critical processes.
      '';
      default = [];
      example = [ "sshd" "systemd" "sudo" ];
    };
  };

  # ==========================================================================
  # Configuration
  # ==========================================================================
  config = lib.mkIf (cfg.enable && cfg.auditd.enable) {
    # Enable the Linux Audit daemon
    security.auditd.enable = true;
    
    # Add user-defined audit rules
    # Note: The nixWrappersWhitelistProcess feature is currently disabled
    # due to auditd compatibility issues with the 'comm' field filter
    security.audit.rules = cfg.auditd.rules;
  };
}
