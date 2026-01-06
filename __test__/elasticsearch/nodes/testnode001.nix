{ config, pkgs, lib, ... }: {
  # Enable Elasticsearch using the infrastructure module
  infrastructure.elasticsearch = {
    enable = true;
    bindToIp = "127.0.0.1";
    httpPort = 9202;
    transportPort = 9302;
    clusterName = "test-cluster";
    singleNode = true;
    heapSize = "512m";
  };
}
