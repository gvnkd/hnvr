{ config, lib, pkgs, ... }:

let
  cfg = config.services.hnvr.leader;
in
{
  options.services.hnvr.leader = {
    enable = lib.mkEnableOption "HNVR leader (IHP web + event writer)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hnvr-web;
      defaultText = "pkgs.hnvr-web";
      description = "Derivation containing bin/hnvr-leader.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "IHP web port. Also published as PORT for IHP.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hnvr";
      description = "Working directory; IHP looks for static/, Config/ here.";
    };

    databaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "postgresql:///hnvr?host=/run/postgresql";
      description = "Postgres connection string. Real deployment pulls from sops-nix.";
    };

    natsUri = lib.mkOption {
      type = lib.types.str;
      default = "nats://nats:nats@localhost:4222";
      description = "NATS connection URI.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables. sops-nix secrets land here.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.hnvr = {
      isSystemUser = true;
      group = "hnvr";
      home = cfg.dataDir;
      createHome = true;
    };
    users.groups.hnvr = { };

    systemd.services.hnvr-leader = {
      description = "HNVR leader (IHP web + event writer)";
      after = [ "network.target" "postgresql.service" "hnvr-nats.service" ];
      wants = [ "hnvr-nats.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PORT = toString cfg.port;
        DATABASE_URL = cfg.databaseUrl;
        HNVR_NATS_URI = cfg.natsUri;
        APP_STATIC = "${cfg.dataDir}/static";
        IHP_SESSION_SECRET_FILE = "${cfg.dataDir}/client_session_key.aes";
      } // cfg.environment;

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/hnvr-leader";
        StateDirectory = "hnvr";
        WorkingDirectory = cfg.dataDir;
        User = "hnvr";
        Group = "hnvr";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening (loosened in Phase 6 when we add GPU access)
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = "/";
        ReadWritePaths = [ cfg.dataDir ];
      };

      # Generate the IHP session secret on first start if missing.
      preStart = ''
        mkdir -p ${cfg.dataDir}/static
        if [ ! -f ${cfg.dataDir}/client_session_key.aes ]; then
          head -c 32 /dev/urandom > ${cfg.dataDir}/client_session_key.aes
          chmod 0600 ${cfg.dataDir}/client_session_key.aes
        fi
      '';
    };

    networking.firewall.allowedTCPPorts = lib.optionals config.networking.firewall.enable
      [ cfg.port ];
  };
}
