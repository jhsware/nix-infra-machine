{ config, pkgs, lib, ... }:
let
  appName = "elasticsearch";
  defaultHttpPort = 9200;
  defaultTransportPort = 9300;

  cfg = config.infrastructure.${appName};
in
{
  options.infrastructure.${appName} = {
    enable = lib.mkEnableOption "infrastructure.elasticsearch";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Elasticsearch package to use.";
      default = pkgs.elasticsearch;
      example = "pkgs.elasticsearch7";
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
      description = "Data directory for Elasticsearch.";
      default = "/var/lib/elasticsearch";
    };

    clusterName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the Elasticsearch cluster.";
      default = "elasticsearch";
    };

    singleNode = lib.mkOption {
      type = lib.types.bool;
      description = "Run as a single-node cluster (disables bootstrap checks).";
      default = true;
    };

    heapSize = lib.mkOption {
      type = lib.types.str;
      description = "JVM heap size for Elasticsearch (e.g., '512m', '1g').";
      default = "512m";
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      description = "Extra settings to add to elasticsearch.yml.";
      default = {};
      example = { "action.destructive_requires_name" = true; };
    };
  };

  config = lib.mkIf cfg.enable {
    services.elasticsearch = {
      enable = true;
      package = cfg.package;
      dataDir = cfg.dataDir;
      cluster_name = cfg.clusterName;
      listenAddress = cfg.bindToIp;
      port = cfg.httpPort;
      tcp_port = cfg.transportPort;
      single_node = cfg.singleNode;

      extraConf = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "${name}: ${builtins.toJSON value}") cfg.extraSettings
      );

      extraJavaOptions = [
        "-Xms${cfg.heapSize}"
        "-Xmx${cfg.heapSize}"
      ];
    };

    # Install curl for API access
    environment.systemPackages = [ pkgs.curl pkgs.jq ];

    # Open firewall for Elasticsearch if binding to non-localhost
    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.bindToIp != "127.0.0.1") [ 
      cfg.httpPort 
      cfg.transportPort 
    ];
  };
}
