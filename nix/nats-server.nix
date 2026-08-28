{ config, lib, pkgs, ... }:

let
  cfg = config.services.hnvr.nats;

  confFile = pkgs.writeText "hnvr-nats.conf" ''
    port: ${toString cfg.port}
    http: ${toString cfg.monitorPort}

    jetstream {
      store_dir: ${cfg.dataDir}/jetstream
      max_mem_store: 0
    }

    authorization {
      user: ${cfg.user}
      password: ${cfg.password}
      timeout: 5s
    }

    # Single-node dev deployment. Cluster config lands in Phase 8 (HA bus).
    ${cfg.extraConfig}
  '';
in
{
  options.services.hnvr.nats = {
    enable = lib.mkEnableOption "NATS server with JetStream for HNVR";

    port = lib.mkOption {
      type = lib.types.port;
      default = 4222;
      description = "Client port.";
    };

    monitorPort = lib.mkOption {
      type = lib.types.port;
      default = 8222;
      description = "HTTP monitoring port.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hnvr-nats";
      description = "JetStream data directory.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nats";
      description = "Plaintext username. We are on a trusted LAN; bcrypt/nkeys come in Phase 6.";
    };

    password = lib.mkOption {
      type = lib.types.str;
      default = "nats";
      description = "Plaintext password. See warning in `user`.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra lines appended to the generated nats-server.conf.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.nats = {
      isSystemUser = true;
      group = "nats";
      home = cfg.dataDir;
      createHome = true;
    };
    users.groups.nats = { };

    systemd.services.hnvr-nats = {
      description = "NATS server (HNVR bus backbone)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.nats-server}/bin/nats-server -c ${confFile}";
        StateDirectory = "hnvr-nats";
        WorkingDirectory = cfg.dataDir;
        User = "nats";
        Group = "nats";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = "/";
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.optionals config.networking.firewall.enable
      [ cfg.port cfg.monitorPort ];
  };
}
