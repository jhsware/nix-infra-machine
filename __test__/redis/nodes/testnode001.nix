{ config, pkgs, lib, ... }: {
  # Enable Redis using infrastructure module with multiple servers
  config.infrastructure.redis = {
    enable = true;
    servers = {
      # Default server (creates redis.service)
      "" = {
        bindToIp = "127.0.0.1";
        bindToPort = 6379;
      };
      # Named server for testing (creates redis-cache.service)
      cache = {
        bindToIp = "127.0.0.1";
        bindToPort = 6380;
        maxMemory = "64mb";
        maxMemoryPolicy = "allkeys-lru";
      };
    };
  };
}