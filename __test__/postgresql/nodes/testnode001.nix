{ config, pkgs, lib, ... }: {
  # Enable PostgreSQL using the infrastructure module
  infrastructure.postgresql = {
    enable = true;
    bindToIp = "127.0.0.1";
    bindToPort = 5432;
    initialDatabases = [ "testdb" ];
  };
}
