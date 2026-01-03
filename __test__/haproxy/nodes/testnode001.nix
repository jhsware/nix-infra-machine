{ config, pkgs, lib, ... }: {
  # Enable HAProxy with test configuration
  config.infrastructure.haproxy = {
    enable = true;
    openFirewall = true;

    # Note: ACME/Let's Encrypt cannot be fully tested in VM environment
    # as it requires DNS resolution and public internet access.
    # For production, set acme.enable = true and configure domains
    acme = {
      enable = false;  # Disabled for testing
      acceptTerms = false;
      email = "test@example.com";
      staging = true;  # Use staging server to avoid rate limits
      domains = {};
    };

    # Frontend configurations
    frontends = {
      # HTTP frontend - handles incoming HTTP traffic
      http-in = {
        bind = [ "*:80" ];
        mode = "http";
        options = [ "httplog" ];
        acls = [
          "is_health path /health"
          "is_api path_beg /api"
          "is_acme path_beg /.well-known/acme-challenge/"
        ];
        httpRequest = [
          "set-header X-Forwarded-Proto http"
        ];
        useBackend = [
          "health_backend if is_health"
          "api_backend if is_api"
          "acme_backend if is_acme"
        ];
        defaultBackend = "web_backend";
      };
    };

    # Backend configurations
    backends = {
      # Web backend - serves static content
      web_backend = {
        mode = "http";
        balance = "roundrobin";
        options = [ "httpchk GET /" ];
        servers = [
          "local 127.0.0.1:8080 check"
        ];
      };

      # API backend
      api_backend = {
        mode = "http";
        balance = "roundrobin";
        options = [ "httpchk GET /api/health" ];
        servers = [
          "api1 127.0.0.1:8081 check"
        ];
      };

      # Health check backend - returns OK for monitoring
      health_backend = {
        mode = "http";
        balance = "roundrobin";
        extraConfig = ''
          http-request return status 200 content-type text/plain string "OK"
        '';
      };

      # ACME challenge backend (for Let's Encrypt webroot validation)
      acme_backend = {
        mode = "http";
        balance = "roundrobin";
        servers = [
          "acme 127.0.0.1:8888 check"
        ];
      };
    };

    # Stats listen section - HAProxy stats page
    listen = {
      stats = {
        bind = [ "*:8404" ];
        mode = "http";
        extraConfig = ''
          stats enable
          stats uri /stats
          stats refresh 10s
          stats admin if LOCALHOST
        '';
      };
    };
  };

  # Simple test backend server using Python's HTTP server
  config.systemd.services.test-backend = {
    description = "Test backend server for HAProxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --directory /var/www/test";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # Create test web content
  config.systemd.tmpfiles.rules = [
    "d /var/www/test 0755 root root -"
    "f /var/www/test/index.html 0644 root root - '<html><body><h1>HAProxy Test Page</h1><p>Backend server is working!</p></body></html>'"
  ];

  # Install utilities for testing
  config.environment.systemPackages = with pkgs; [
    curl
    openssl
    python3
  ];
}
