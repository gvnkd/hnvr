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

    staticAssets = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hnvr-static or (pkgs.runCommand "hnvr-static-empty" { } "mkdir $out");
      defaultText = "pkgs.hnvr-static";
      description = ''
        Derivation containing the compiled static assets (notably
        @app.css@) that get copied into @''${dataDir}/static/@ at
        service start. Defaults to @pkgs.hnvr-static@ when the HNVR
        overlay is applied; falls back to an empty derivation
        otherwise.
      '';
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

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "hnvr-2";
      description = ''
        Host identifier published as hnvr.health.<hostName> by the
        HealthReporter and matched by the AssignmentCoordinator. Real
        deployments set this per-host via the NixOS config.
      '';
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
        # Published as hnvr.health.<HNVR_HOST> by HealthReporter; consumed
        # by the leader's HealthCache + AssignmentCoordinator.
        HNVR_HOST = cfg.hostName;
        APP_STATIC = "${cfg.dataDir}/static";
        IHP_SESSION_SECRET_FILE = "${cfg.dataDir}/client_session_key.aes";
        # Bootstrap admin: leader boot idempotently INSERTs a row into
        # users(email='INITIAL_ADMIN_EMAIL', is_admin=TRUE) using
        # hashPassword(INITIAL_ADMIN_PASSWORD). Real deployments source
        # these from sops-nix (services.hnvr.secrets.enable = true).
        INITIAL_ADMIN_EMAIL = lib.mkDefault "admin@hnvr.local";
      } // cfg.environment;

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/hnvr-leader";
        StateDirectory = "hnvr";
        WorkingDirectory = cfg.dataDir;
        User = "hnvr";
        Group = "hnvr";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening (loosened in Phase 6 when we add GPU access if needed).
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = "/";
        ReadWritePaths = [ cfg.dataDir ];
      };

      # Generate the IHP session secret on first start if missing.
      # Also stage the compiled static assets (app.css) from
      # cfg.staticAssets into ${dataDir}/static/ — IHP's static
      # middleware serves from APP_STATIC (env-configured below).
      #
      # When sops-nix is enabled, also generate per-secret systemd
      # EnvironmentFile fragments from /run/secrets/<name> (single
      # value per file → KEY=value line). systemd EnvironmentFile
      # wants the KEY= form; sops-nix's per-secret files contain only
      # the value.
      preStart = ''
        mkdir -p ${cfg.dataDir}/static
        # Idempotently stage the latest CSS — copy (not symlink) because
        # ProtectSystem=strict + ReadWritePaths=${cfg.dataDir} forbid
        # writes outside dataDir, and the nix store is read-only anyway.
        cp -fL ${cfg.staticAssets}/app.css ${cfg.dataDir}/static/app.css
        if [ ! -f ${cfg.dataDir}/client_session_key.aes ]; then
          head -c 32 /dev/urandom > ${cfg.dataDir}/client_session_key.aes
          chmod 0600 ${cfg.dataDir}/client_session_key.aes
        fi
      '' + lib.optionalString config.services.hnvr.secrets.enable ''
        # Rebuild per-secret EnvironmentFile fragments every boot —
        # sops-nix may have rotated the underlying /run/secrets/* value
        # between activations.
        mkdir -p ${cfg.dataDir}/env
        for kv in \
            "HNVR_DATA_KEY=hnvr-data-key" \
            "HNVR_S3_ENDPOINT=hnvr-s3-endpoint" \
            "HNVR_S3_ACCESS_KEY=hnvr-s3-access-key" \
            "HNVR_S3_SECRET_KEY=hnvr-s3-secret-key" \
            "HNVR_S3_BUCKET=hnvr-s3-bucket" \
            "HNVR_DB_URL=hnvr-db-url" \
            "INITIAL_ADMIN_EMAIL=initial-admin-email" \
            "INITIAL_ADMIN_PASSWORD=initial-admin-password"; do
          key=''${kv%%=*}
          src=''${kv#*=}
          if [ -f /run/secrets/$src ]; then
            printf "%s=" "$key" > ${cfg.dataDir}/env/$key
            cat /run/secrets/$src >> ${cfg.dataDir}/env/$key
            printf "\n" >> ${cfg.dataDir}/env/$key
          fi
        done
      '';
    };

    # Inject the EnvironmentFile list. We do this in a separate
    # assignment so lib.optionals reads config.services.hnvr.secrets.enable
    # correctly under mkIf (config merging rules).
    systemd.services.hnvr-leader.serviceConfig.EnvironmentFile =
      lib.optionals config.services.hnvr.secrets.enable (
        map (k: "${cfg.dataDir}/env/${k}")
          [
            "HNVR_DATA_KEY"
            "HNVR_S3_ENDPOINT"
            "HNVR_S3_ACCESS_KEY"
            "HNVR_S3_SECRET_KEY"
            "HNVR_S3_BUCKET"
            "HNVR_DB_URL"
            "INITIAL_ADMIN_EMAIL"
            "INITIAL_ADMIN_PASSWORD"
          ]
      );

    networking.firewall.allowedTCPPorts = lib.optionals config.networking.firewall.enable
      [ cfg.port ];
  };
}
