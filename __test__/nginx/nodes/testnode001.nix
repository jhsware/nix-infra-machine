{ config, pkgs, lib, ... }: {
  # Enable nginx with test configuration
  config.infrastructure.nginx = {
    enable = true;
    openFirewall = true;
    recommendedSettings = true;

    # Note: ACME/Let's Encrypt cannot be fully tested in VM environment
    # as it requires DNS resolution and public internet access.
    # For production, set acme.enable = true and acme.acceptTerms = true
    acme = {
      enable = false;  # Disabled for testing
      acceptTerms = false;
      email = "test@example.com";
      staging = true;  # Use staging server to avoid rate limits
    };

    virtualHosts = {
      # Simple static site
      "localhost" = {
        default = true;
        root = "/var/www/test";
        locations."/" = {
          index = "index.html";
        };
        locations."/health" = {
          return = "200 'OK'";
          extraConfig = ''
            add_header Content-Type text/plain;
          '';
        };
      };

      # Reverse proxy example (proxy to a test backend)
      "proxy.localhost" = {
        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;
        };
        locations."/api" = {
          proxyPass = "http://127.0.0.1:8081";
          extraConfig = ''
            proxy_read_timeout 300s;
          '';
        };
      };
    };

    appendHttpConfig = ''
      # Custom http config for testing
      log_format custom '$remote_addr - $remote_user [$time_local] '
                        '"$request" $status $body_bytes_sent';
    '';
  };

  # Create test web root directory with content
  config.systemd.tmpfiles.rules = [
    "d /var/www/test 0755 nginx nginx -"
    "f /var/www/test/index.html 0644 nginx nginx - '<html><body><h1>Nginx Test Page</h1></body></html>'"
  ];

  # Install utilities for testing
  config.environment.systemPackages = with pkgs; [
    curl
    openssl
  ];
}
