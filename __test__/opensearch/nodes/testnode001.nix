{ config, pkgs, lib, ... }: {
  # Enable OpenSearch using the infrastructure module
  infrastructure.opensearch = {
    enable = true;
    bindToIp = "127.0.0.1";
    httpPort = 9201;
    transportPort = 9301;
    clusterName = "test-cluster";
    singleNode = true;
    heapSize = "512m";
  };
}
