{ config, pkgs, lib, ... }:
let
  appName = "opensearch";
  defaultHttpPort = 9200;
  defaultTransportPort = 9300;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.opensearch";

    package = lib.mkOption {
      type = lib.types.package;
      description = "OpenSearch package to use.";
      default = pkgs.opensearch;
      example = "pkgs.opensearch";
    };

    bindToIp = lib.mkOption {
      type = lib.types.str;
      description = "IP address to bind for HTTP API.";
      default = "127.0.0.1";
    };

    httpPort = lib.mkOption {
      type = lib.types.int;
      description = "Port for HTTP API.";
      default = defaultHttpPort;
    };

    transportPort = lib.mkOption {
      type = lib.types.int;
      description = "Port for transport/cluster communication.";
      default = defaultTransportPort;
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      description = "Data directory for OpenSearch.";
      default = "/var/lib/opensearch";
    };

    clusterName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the OpenSearch cluster.";
      default = "opensearch";
    };

    singleNode = lib.mkOption {
      type = lib.types.bool;
      description = "Run as a single-node cluster (disables bootstrap checks).";
      default = true;
    };

    heapSize = lib.mkOption {
      type = lib.types.str;
      description = "JVM heap size for OpenSearch (e.g., '512m', '1g').";
      default = "512m";
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      description = "Extra settings to add to opensearch.yml.";
      default = {};
      example = { "action.destructive_requires_name" = true; };
    };
  };

  config = lib.mkIf cfg.enable {
    services.opensearch = {
      enable = true;
      package = cfg.package;
      dataDir = cfg.dataDir;

      settings = lib.mkMerge [
        {
          "network.host" = cfg.bindToIp;
          "http.port" = cfg.httpPort;
          "transport.port" = cfg.transportPort;
          "cluster.name" = cfg.clusterName;
        }
        (lib.mkIf cfg.singleNode {
          "discovery.type" = "single-node";
        })
        cfg.extraSettings
      ];

      extraJavaOptions = [
        "-Xms${cfg.heapSize}"
        "-Xmx${cfg.heapSize}"
      ];
    };

    # Install curl for API access
    environment.systemPackages = [ pkgs.curl pkgs.jq ];

    # Open firewall for OpenSearch if binding to non-localhost
    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.bindToIp != "127.0.0.1") [ 
      cfg.httpPort 
      cfg.transportPort 
    ];
  };
}
