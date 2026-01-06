# CrowdSec Console Integration Module
# Provides cloud enrollment and community threat intelligence sharing
{ config, pkgs, lib, ... }:

let
  appName = "crowdsec";
  cfg = config.infrastructure.${appName};
in
{
  # ==========================================================================
  # Options
  # ==========================================================================
  options.infrastructure.${appName}.console = {
    enrollKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = ''
        Path to file containing the CrowdSec Console enrollment key.
        
        Enrolling connects your instance to the CrowdSec Console for:
        - Centralized monitoring and management
        - Access to community and commercial blocklists
        - Threat intelligence dashboards
        - Alert visualization and analytics
        
        Get your enrollment key from: https://app.crowdsec.net/
        
        The enrollment key should be stored securely, for example using
        agenix or sops-nix for secrets management.
        
        [NIS2 COMPLIANCE]
        Article 21(2)(g) - Security Monitoring: Provides centralized
        visibility into security events across infrastructure.
        
        Article 23 - Reporting: Facilitates incident documentation
        and reporting through centralized logging.
      '';
      default = null;
      example = "/run/secrets/crowdsec-enroll-key";
    };

    shareDecisions = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Share your detected threats with the CrowdSec community.
        
        When enabled, anonymized attack signals are shared to improve
        collective threat intelligence for all CrowdSec users. This is
        a key part of CrowdSec's collaborative security model.
        
        Shared data includes:
        - Source IP addresses of attacks
        - Attack type/scenario that triggered
        - Timestamp of the attack
        
        Personal data and log contents are NOT shared.
        
        [NIS2 COMPLIANCE]
        Article 14 - Information Sharing: Contributes to EU-wide
        cybersecurity by participating in threat intelligence sharing.
      '';
      default = true;
    };

    name = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = ''
        Custom name for this instance in the CrowdSec Console.
        
        If not set, the hostname will be used. Useful for identifying
        machines in multi-server deployments.
      '';
      default = null;
      example = "web-server-01";
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        Tags to apply to this instance in the CrowdSec Console.
        
        Tags help organize and filter machines in the console dashboard.
      '';
      default = [];
      example = [ "production" "web-tier" "eu-west" ];
    };
  };

  # ==========================================================================
  # Configuration
  # ==========================================================================
  # Note: The actual console enrollment is handled by the main module
  # since it requires integration with both native and custom implementations.
  # This module only defines the options.
  #
  # For native implementation: settings are passed to services.crowdsec.settings
  # For custom implementation: enrollment is done via cscli in the init script
}
