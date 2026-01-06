{ config, pkgs, lib, ... }: {
  # Enable MariaDB using the infrastructure module
  infrastructure.mariadb = {
    enable = true;
    bindToIp = "127.0.0.1";
    bindToPort = 3306;
    
    # Create initial database
    initialDatabases = [
      { name = "testdb"; }
    ];

    # Create test user with access to testdb
    ensureUsers = [
      {
        name = "testuser";
        ensurePermissions = {
          "testdb.*" = "ALL PRIVILEGES";
        };
      }
    ];
  };
}
