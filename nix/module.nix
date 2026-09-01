{ config, lib, pkgs, ... }:

let
  cfg = config.services.hnvr.leader;
  cfgA = config.services.hnvr.admin;
in
{
  options.services.hnvr.admin = {
    enable = lib.mkEnableOption "HNVR admin service (roles/users/camera management)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hnvr-admin;
      defaultText = "pkgs.hnvr-admin";
      description = "Derivation containing bin/hnvr-admin.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 18010;
      description = "Admin web port (HNVR_ADMIN_PORT).";
    };

    listenAddr = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "10.9.0.5";
      description = ''
        Bind address (HNVR_ADMIN_LISTEN). The admin service owns ALL
        management mutation — keep it on loopback or a management VLAN.
        Never bind it on the end-user interface.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the admin port in the firewall. Deliberately off by default:
        reach it over loopback/SSH forwarding or a mgmt VLAN.
      '';
    };

    baseUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://nvr.example.com/admin";
      description = ''
        HNVR_ADMIN_BASE_URL: absolute public URL (scheme + host + path)
        when hnvr-admin is mounted under a sub-path of a reverse-proxied
        vhost. The app prefixes every generated URL with — and strips —
        the path itself (AdminWeb.BasePath), so the proxy must forward
        the ORIGINAL request URI untouched (proxy_pass WITHOUT a URI
        part: no trailing slash, no rewrite). Null = served at /.
      '';
    };
  };

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

    s3PublicEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        HNVR_S3_PUBLIC_ENDPOINT: browser-reachable S3 endpoint used only
        for presigned archive/event URLs. The presigned URL's host is
        part of the SigV4 signature, so when HNVR_S3_ENDPOINT is an
        internal address (localhost/VPC) set this to the address clients
        use (for example https://s3.example.com). Null falls back to
        HNVR_S3_ENDPOINT. Superseded by the @public_endpoint@ field of
        the config file (see configFile) — this env var overrides it.
      '';
    };

    baseUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://nvr.example.com/hnvr";
      description = ''
        HNVR_BASE_URL: absolute public URL (scheme + host + path) when
        the leader is mounted under a sub-path of a reverse-proxied
        vhost. The app prefixes every generated URL with — and strips —
        the path itself (Hnvr.Web.BasePath); /healthz, /status,
        /debug-frame and /whep all move under the prefix (requests
        outside it 404). The proxy must forward the ORIGINAL request URI
        untouched (proxy_pass WITHOUT a URI part). Null = served at /.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        HNVR_CONFIG: path to the YAML app config (S3 credentials etc.,
        see hnvr.example.yaml). Typically the sops-nix secret
        @config.sops.secrets.hnvr-config.path@ — that secret's owner
        must be the hnvr user since the service reads it at runtime
        (not via systemd EnvironmentFile). Null = rely on HNVR_S3_* env
        vars alone.
      '';
    };

    onnxruntimePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.onnxruntime;
      defaultText = "pkgs.onnxruntime";
      description = ''
        onnxruntime build whose libonnxruntime.so the CV analyzer
        dlopens (HNVR_ONNXRUNTIME_LIB). Default is the CPU-only nixpkgs
        build (hnvr-1: Pascal is unsupported by cuDNN ≥ 9.12, so CPU EP
        is its v1 ceiling). hnvr-2 overrides with the flake's
        CUDA build: packages.onnxruntime-cuda (sm_89).
      '';
    };

    execProviders = lib.mkOption {
      type = lib.types.str;
      default = "cpu";
      description = ''
        HNVR_EXEC_PROVIDERS: comma-separated EP priority list
        (cpu|cuda|tensorrt). First provider whose session initializes
        wins. hnvr-2 (RTX 4090): "tensorrt,cuda,cpu".
      '';
    };

    modelPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        HNVR_MODEL_PATH: absolute path to the YOLO ONNX model. Null
        disables the analysis pipeline (CaptureSupervisor skips the
        frame-source/analyzer pair per camera).
      '';
    };

    modelDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        HNVR_MODEL_DIR: directory holding the per-camera ONNX models
        referenced by cameras.model_name (<dir>/<model_name>.onnx).
        Null = the directory of modelPath.
      '';
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9100;
      description = ''
        HNVR_METRICS_PORT: Prometheus text endpoint (own warp, leader +
        node). Not opened in the firewall by default — scrape over
        localhost or allow explicitly.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
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
          # ---- Phase 3 CV pipeline -----------------------------------
          HNVR_ONNXRUNTIME_LIB = "${cfg.onnxruntimePackage}/lib/libonnxruntime.so";
          HNVR_EXEC_PROVIDERS = cfg.execProviders;
          HNVR_METRICS_PORT = toString cfg.metricsPort;
          # libcuda.so.1 (kernel-driver shim) lives outside the nix store;
          # NixOS exposes it here when hardware.nvidia is enabled. A
          # nonexistent dir on CPU-only hosts is harmless.
          LD_LIBRARY_PATH = "/run/opengl-driver/lib";
          # TRT engine cache — first analyzer start builds the engine
          # (minutes), later starts load from here. Under dataDir so
          # ProtectSystem=strict allows the write.
          HNVR_TRT_CACHE_DIR = "${cfg.dataDir}/trt-cache";
          # Public ICE hosts for the rendered mediamtx.yml (WHEP from
          # outside the LAN — see services.hnvr.mediamtx.webrtcAdditionalHosts).
          HNVR_MEDIAMTX_WEBRTC_HOSTS = lib.concatStringsSep ","
            config.services.hnvr.mediamtx.webrtcAdditionalHosts;
          # hasql 1.10 + hasql-pool 1.4: interrupted sessions (killed web
          # handler threads) deallocate server-side prepared statements but
          # keep the client-side cache, permanently poisoning pooled
          # connections with 26000 "prepared statement does not exist"
          # (surfaced as AssignmentCoordinator reconcile failures). Unnamed
          # statements can't go stale; HNVR's query volume doesn't need
          # prepared statements. Patched IHP reads this env var.
          HASQL_DISABLE_PREPARED_STATEMENTS = "1";
        } // lib.optionalAttrs (cfg.modelPath != null) {
          HNVR_MODEL_PATH = cfg.modelPath;
        } // lib.optionalAttrs (cfg.modelDir != null) {
          HNVR_MODEL_DIR = cfg.modelDir;
        } // lib.optionalAttrs (cfg.s3PublicEndpoint != null) {
          HNVR_S3_PUBLIC_ENDPOINT = cfg.s3PublicEndpoint;
        } // lib.optionalAttrs (cfg.baseUrl != null) {
          HNVR_BASE_URL = cfg.baseUrl;
        } // lib.optionalAttrs (cfg.configFile != null) {
          HNVR_CONFIG = toString cfg.configFile;
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
          # The MediaMTXConfigSyncer writes the mediamtx config (and its
          # .tmp) next to the mediamtx service's runtime dir; without this
          # the syncer's initial write fails under ProtectSystem=strict,
          # which used to kill the whole syncer async silently.
          ReadWritePaths = [ cfg.dataDir ]
            ++ lib.optionals config.services.hnvr.mediamtx.enable
            [ (dirOf config.services.hnvr.mediamtx.configPath) ];

          # Raise the FD ceiling above systemd's 1024 default. The leader
          # holds many concurrent sockets: per-camera ffmpeg subprocess
          # pipes, MinIO upload connections, WHEP/WebRTC session sockets,
          # async S3-purge workers (PurgeRecordingAction spawns a thread
          # that walks thousands of segment keys). At Sergey's 3-camera
          # 24/7 capture load the leader peaked past 1024 and
          # `Network.Socket.accept: resource exhausted` started refusing
          # /NewSession, which made it look like the cameras-crud test
          # was hung on `page.goto` (reported 2026-08-12).
          LimitNOFILE = 524288;
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
          cp -fL ${cfg.staticAssets}/app.js ${cfg.dataDir}/static/app.js
          cp -fL ${cfg.staticAssets}/ptz.js ${cfg.dataDir}/static/ptz.js
          cp -fL ${cfg.staticAssets}/timeline.js ${cfg.dataDir}/static/timeline.js
          if [ ! -f ${cfg.dataDir}/client_session_key.aes ]; then
            head -c 32 /dev/urandom > ${cfg.dataDir}/client_session_key.aes
            chmod 0600 ${cfg.dataDir}/client_session_key.aes
          fi
        '' + lib.optionalString (config.services.hnvr.secrets.enable or false) ''
          # Rebuild per-secret EnvironmentFile fragments every boot —
          # sops-nix may have rotated the underlying /run/secrets/* value
          # between activations.
          mkdir -p ${cfg.dataDir}/env
          # S3 creds moved into the YAML config file (cfg.configFile /
          # sops secret hnvr-config); the HNVR_S3_* env fragment keys are
          # gone — env remains an override, not the primary source.
          for kv in \
              "HNVR_DATA_KEY=hnvr-data-key" \
              "DATABASE_URL=hnvr-db-url" \
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
        lib.optionals (config.services.hnvr.secrets.enable or false) (
          map (k: "${cfg.dataDir}/env/${k}")
            [
              "HNVR_DATA_KEY"
              "DATABASE_URL"
              "INITIAL_ADMIN_EMAIL"
              "INITIAL_ADMIN_PASSWORD"
            ]
        );

      networking.firewall.allowedTCPPorts = lib.optionals config.networking.firewall.enable
        [ cfg.port ];
    })

    # hnvr-admin (design_docs/13, M3+): shares the DB, NATS and static
    # assets with the leader; own cookie name, bound to listenAddr.
    (lib.mkIf cfgA.enable {
      systemd.services.hnvr-admin = {
        description = "HNVR admin service (roles/users/camera management)";
        after = [ "network.target" "postgresql.service" "hnvr-leader.service" ];
        wants = [ "hnvr-leader.service" ];
        wantedBy = [ "multi-user.target" ];

        environment = {
          HNVR_ADMIN_PORT = toString cfgA.port;
          HNVR_ADMIN_LISTEN = cfgA.listenAddr;
          DATABASE_URL = cfg.databaseUrl;
          HNVR_NATS_URI = cfg.natsUri;
          APP_STATIC = "${cfg.dataDir}/static";
          IHP_SESSION_SECRET_FILE = "${cfg.dataDir}/client_session_key.aes";
          HASQL_DISABLE_PREPARED_STATEMENTS = "1";
        } // lib.optionalAttrs (cfgA.baseUrl != null) {
          HNVR_ADMIN_BASE_URL = cfgA.baseUrl;
        } // lib.optionalAttrs (cfg.configFile != null) {
          HNVR_CONFIG = toString cfg.configFile;
        };

        serviceConfig = {
          ExecStart = "${cfgA.package}/bin/hnvr-admin";
          StateDirectory = "hnvr";
          WorkingDirectory = cfg.dataDir;
          User = "hnvr";
          Group = "hnvr";
          Restart = "on-failure";
          RestartSec = 5;

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadOnlyPaths = "/";
          ReadWritePaths = [ cfg.dataDir ];
        };
      };

      networking.firewall.allowedTCPPorts = lib.optionals
        (config.networking.firewall.enable && cfgA.openFirewall)
        [ cfgA.port ];
    })
  ];
}
