{ config, pkgs, lib, ... }:
let
  appName = "rabbitmq";
  defaultPort = 5672;
  defaultManagementPort = 15672;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.rabbitmq";

    package = lib.mkOption {
      type = lib.types.package;
      description = "RabbitMQ package to use.";
      default = pkgs.rabbitmq-server;
      example = "pkgs.rabbitmq-server";
    };

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind.";
      default = "127.0.0.1";
    };

    bindToPort = lib.mkOption {
      type = lib.types.int;
      description = "AMQP port to bind.";
      default = defaultPort;
    };

    managementPlugin = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "Enable the RabbitMQ management plugin (web UI).";
        default = true;
      };

      port = lib.mkOption {
        type = lib.types.int;
        description = "Port for the management web UI.";
        default = defaultManagementPort;
      };
    };

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Additional RabbitMQ plugins to enable.";
      default = [];
      example = [ "rabbitmq_shovel" "rabbitmq_federation" ];
    };

    configItems = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Additional RabbitMQ configuration items (key-value pairs).";
      default = {};
      example = {
        "vm_memory_high_watermark" = "0.6";
        "disk_free_limit.absolute" = "1GB";
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      description = "Open firewall ports for RabbitMQ.";
      default = false;
    };
  };

  config = lib.mkIf cfg.enable {
    services.rabbitmq = {
      enable = true;
      package = cfg.package;
      listenAddress = cfg.bindToIp;
      port = cfg.bindToPort;
      
      # Enable management plugin if requested
      managementPlugin.enable = cfg.managementPlugin.enable;
      managementPlugin.port = cfg.managementPlugin.port;

      # Combine user plugins with management plugin
      plugins = cfg.plugins;

      # Pass through additional configuration
      configItems = cfg.configItems;
    };

    # Install rabbitmqadmin CLI tool when management plugin is enabled
    environment.systemPackages = lib.mkIf cfg.managementPlugin.enable [
      pkgs.rabbitmq-server
    ];

    # Open firewall ports if requested
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
      [ cfg.bindToPort ] ++
      (lib.optional cfg.managementPlugin.enable cfg.managementPlugin.port)
    );
  };
}
