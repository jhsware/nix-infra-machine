{ config, pkgs, lib, ... }: {
  # Enable RabbitMQ using the infrastructure module
  infrastructure.rabbitmq = {
    enable = true;
    bindToIp = "127.0.0.1";
    bindToPort = 5672;
    
    # Enable management plugin for testing
    managementPlugin = {
      enable = true;
      port = 15672;
    };
  };
}
