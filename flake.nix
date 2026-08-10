{
  description = "HNVR — Haskell Network Video Recorder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # IHP HEAD (Aug 7 2026) — GHC 9.12-capable. Pin via commit until a
    # tagged release supports 9.12. nixpkgs follows ours so the IHP
    # Haskell overlay (jailbreaks, hasql pinning, etc.) evaluates against
    # the same nixpkgs rev as the rest of the flake.
    ihp = {
      url = "github:digitallyinduced/ihp/v1.6.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Phase 2 (live view): mediamtx bumped to v1.20.0 (design lock) via
    # the mediamtxOverlay defined below — nixpkgs pins 1.18.2 but the
    # overlay rebuilds from source via buildGo126Module.
    # Phase 6+ (secrets, disks):
    #   sops-nix.url   = "github:Mic92/sops-nix";
    #   disko.url      = "github:nix-community/disko";

    # devenv — manages local dev services (Postgres, MinIO, NATS, MediaMTX)
    # via `devenv up` inside `nix develop`. Flake-integrated: the devShell
    # is built via devenv.lib.mkShell instead of plain pkgs.mkShell, so
    # `nix develop` lands in a devenv-aware shell.
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, pre-commit-hooks, ihp, devenv, ... }:
    let
      supportedSystems = [ "x86_64-linux" ];

      # -------------------------------------------------------------
      # Haskell overlay for our local packages + nats-queue jailbreaks.
      # Designed to be applied on top of IHP's ghc912 package set
      # (`pkgs.extend ihp.overlays.default` exposes `ghc912` top-level).
      # -------------------------------------------------------------
      hnvrHaskellOverlay = libHs: final: prev: {
        # nats-queue (2017) calls Network.Socket.sClose, renamed to close
        # in network >= 3.x. Patch the call site. Its test suite also
        # pulls in cabal-test-quickcheck (broken + base <4.14), so jailbreak
        # and skip tests on the chain.
        nats-queue = libHs.dontCheck (prev.nats-queue.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace Network/Nats.hs --replace "S.sClose" "S.close"
          '';
          patches = (old.patches or [ ]) ++ [ ./nix/nats-queue-ipv6-fallback.patch ];
        }));
        cabal-test-quickcheck =
          libHs.dontCheck (libHs.doJailbreak (libHs.markUnbroken prev.cabal-test-quickcheck));

        # IHP codegen output (e.g. Generated/Statements/UpdateHost.hs) needs
        # the IsScalar.encoder signature from hasql-mapping 0.1.0.2; older
        # versions in nixpkgs don't have it. callHackageDirect bypasses the
        # stale all-cabal-hashes index pinned in nixpkgs.
        hasql-mapping = libHs.dontCheck (final.callHackageDirect
          {
            pkg = "hasql-mapping";
            ver = "0.1.0.2";
            sha256 = "1fliljpkm223hakd43jsi9bgiyahxn23j8a85j9cqlazwd5v8yaj";
          }
          { });

        # IHP ships without profiling libs; matching that here avoids
        # "Could not load module … Perhaps you haven't installed the
        # profiling libraries for package ihp" at link time.
        hnvr-core = libHs.disableLibraryProfiling (final.callCabal2nix "hnvr-core" ./hnvr-core { });
        hnvr-nats = libHs.disableLibraryProfiling (final.callCabal2nix "hnvr-nats" ./hnvr-nats { });
        hnvr-capture = libHs.disableLibraryProfiling (final.callCabal2nix "hnvr-capture" ./hnvr-capture { });
        hnvr-cv = libHs.disableLibraryProfiling (final.callCabal2nix "hnvr-cv" ./hnvr-cv { });
        hnvr-ptz = libHs.disableLibraryProfiling (final.callCabal2nix "hnvr-ptz" ./hnvr-ptz { });
        hnvr-storage = libHs.disableLibraryProfiling (final.callCabal2nix "hnvr-storage" ./hnvr-storage { });
        hnvr-web = libHs.disableLibraryProfiling (final.callCabal2nix "hnvr-web" ./hnvr-web { });
      };

      # Top-level overlay exposing our packages (so NixOS modules can
      # reference pkgs.hnvr-web directly). IHP overlay is composed by
      # the consumer via nixpkgs.overlays.
      hnvrTopOverlay = final: prev:
        let
          hpkgs = prev.ghc912.extend (hnvrHaskellOverlay prev.haskell.lib);
        in
        {
          inherit (hpkgs)
            hnvr-core hnvr-nats hnvr-capture hnvr-cv hnvr-ptz hnvr-storage hnvr-web;
        };

      # -------------------------------------------------------------
      # MediaMTX v1.20.0 — design lock (design_docs/02-tech-stack.md).
      # nixpkgs pins 1.18.2; we override to 1.20.0 to (a) match the
      # locked version and (b) align the REST API surface with the
      # `Hnvr.Web.MediaMTXConfigSyncer` consumer (1.18.2 vs 1.20.0 both
      # use /v3/* so this is forward-compatible, but 1.20.0 also ships
      # the v1.20 WHEP improvements Chrome 130+ wants — Phase 2 Slice 3
      # decision point).
      #
      # The rpicamera patches nixpkgs-1.18.2 needs are NOT required for
      # 1.20.0 on x86_64: the build constraints naturally exclude arm-
      # only files, and the renamed `source_other.go` stub matches our
      # arch without substitution.
      # -------------------------------------------------------------
      mediamtxOverlay = final: prev: {
        mediamtx = prev.mediamtx.overrideAttrs (old:
          let
            hlsJs = final.fetchurl {
              url = "https://cdn.jsdelivr.net/npm/hls.js@v1.6.16/dist/hls.min.js";
              hash = "sha256-RC9ZnDTxA8M1WzdaI73/VgWS1xF9CajIRyQuo94tQOA=";
            };
          in
          {
            version = "1.20.0";
            src = final.fetchFromGitHub {
              owner = "bluenviron";
              repo = "mediamtx";
              tag = "v1.20.0";
              hash = "sha256-bnbuIf3GdT+TCUHzAqvsS9wLPjDUGunpJoQBJFY4aTo=";
            };
            vendorHash = "sha256-uXwfIeE95g8isjR3ll0pcXnRtr/dbhp9B0HyH47WgWU=";
            postPatch = ''
              cp ${hlsJs} internal/servers/hls/hls.min.js
              echo "v1.20.0" > internal/core/VERSION
            '';
          });
      };

      # -------------------------------------------------------------
      # Per-host NixOS module stacks. Both VMs apply IHP + hnvr overlays
      # top-level (so pkgs.hnvr-web resolves).
      # -------------------------------------------------------------
      baseVmConfig = { config, pkgs, lib, ... }: {
        nixpkgs.overlays = [ ihp.overlays.default mediamtxOverlay hnvrTopOverlay ];

        # QEMU VM sizing.
        virtualisation.vmVariant = {
          virtualisation.memorySize = 2048;
          virtualisation.cores = 2;
          virtualisation.graphics = false;
        };

        users.users.root.initialPassword = "root";

        # Allow SSH for debugging.
        services.openssh.enable = true;
        services.openssh.settings.PermitRootLogin = lib.mkForce "yes";

        # Trust LAN — disable firewall for dev simplicity.
        networking.firewall.enable = false;

        system.stateVersion = "25.05";
      };

      mkLeaderVmModules = [
        baseVmConfig
        self.nixosModules.hnvr-nats
        self.nixosModules.hnvr-mediamtx
        self.nixosModules.hnvr
        {
          services.hnvr.nats.enable = true;
          services.hnvr.mediamtx.enable = true;
          services.hnvr.leader.enable = true;
          services.hnvr.leader.hostName = "hnvr-2";

          # IHP needs a Postgres. Local dev Postgres for now; the design
          # has Postgres as a SaaS dependency that real deployments pull
          # in via HNVR_DB_URL (sops-nix in Phase 6).
          services.postgresql.enable = true;
          services.postgresql.ensureDatabases = [ "hnvr" ];
          services.postgresql.ensureUsers = [{
            name = "hnvr";
            ensureDBOwnership = true;
          }];
          services.postgresql.authentication = ''
            local all all trust
          '';
        }
      ];

      mkWorkerVmModules = [
        baseVmConfig
        self.nixosModules.hnvr-nats
        ({ pkgs, ... }: {
          # Worker VM runs its own local NATS for Phase 0 demo purposes
          # (so the node has something to connect to without inter-VM
          # networking). Real deployments only run NATS on the leader;
          # the worker reaches it over the LAN.
          services.hnvr.nats.enable = true;

          systemd.services.hnvr-node = {
            description = "HNVR worker (CaptureSupervisor stub lands in Phase 3)";
            after = [ "network.target" "hnvr-nats.service" ];
            wants = [ "hnvr-nats.service" ];
            wantedBy = [ "multi-user.target" ];
            environment = {
              HNVR_NATS_URI = "nats://nats:nats@localhost:4222";
              HNVR_HOST = "hnvr-1";
            };
            serviceConfig = {
              ExecStart = "${pkgs.hnvr-web}/bin/hnvr-node";
              Restart = "on-failure";
              RestartSec = 5;
            };
          };
        })
      ];
    in
    (flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system}.extend (nixpkgs.lib.composeManyExtensions [
          ihp.overlays.default
          mediamtxOverlay
        ]);
        hpkgs = pkgs.ghc912.extend (hnvrHaskellOverlay pkgs.haskell.lib);

        localPkgs = {
          inherit (hpkgs)
            hnvr-core hnvr-nats hnvr-capture hnvr-cv hnvr-ptz hnvr-storage hnvr-web;
        };

        # -------------------------------------------------------------
        # Pre-commit hooks
        # -------------------------------------------------------------
        preCommit = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          tools = {
            ormolu = pkgs.ormolu;
            hlint = hpkgs.hlint;
          };
          hooks = {
            ormolu = {
              enable = true;
              excludes = [ "^hnvr-web/gen/" "^vendored/" ];
            };
            hlint = {
              enable = true;
              excludes = [ "^hnvr-web/gen/" "^vendored/" ];
            };
            cabal-fmt = {
              enable = true;
              excludes = [ "^vendored/" ];
            };
            nixpkgs-fmt.enable = true;
            end-of-file-fixer = {
              enable = true;
              excludes = [ "^hnvr-web/gen/" "^vendored/" ];
            };
            trim-trailing-whitespace = {
              enable = true;
              excludes = [ "^hnvr-web/gen/" "^vendored/" ];
            };
          };
        };

        # -------------------------------------------------------------
        # devenv-only pkgs instance. MinIO is `meta.insecure = true` in
        # nixpkgs and the eval check looks at `config.permittedInsecurePackages`,
        # which can only be set via `import nixpkgs { config = ...; }` (not
        # via overlays on legacyPackages). We compose IHP's overlay on top
        # so `ghc912` resolves the same way as the main `pkgs` above; our
        # hnvrHaskellOverlay layers on top of that to expose our packages
        # for fast cabal-style iteration inside the devenv shell.
        #
        # Production deployments use the SeaweedFS SaaS for object storage,
        # never this dev MinIO — the bypass is dev-shell-only.
        # -------------------------------------------------------------
        minioVersion = (import nixpkgs { inherit system; overlays = [ ihp.overlays.default ]; }).minio.name;
        devenvPkgs = import nixpkgs {
          inherit system;
          overlays = [ ihp.overlays.default mediamtxOverlay ];
          config.permittedInsecurePackages = [ minioVersion ];
        };
        devenvHpkgs = devenvPkgs.ghc912.extend (hnvrHaskellOverlay devenvPkgs.haskell.lib);

        # MediaMTX bootstrap config — leader pushes per-camera path
        # config via REST API (PUT /v2/config/paths/<slug>) once cameras
        # are added in the IHP UI. Mirrors the stubConfig in
        # nix/mediamtx.nix (NixOS module) so prod + dev behave the same.
        #
        # Only API + WebRTC are enabled. RTSP/RTMP/HLS/SRT/playback
        # *server* ports are disabled because (a) HNVR doesn't use them
        # (live view = WebRTC; archive HLS is served by the leader, not
        # mediamtx) and (b) the default HLS port :8888 collides with
        # another service on Sergey's dev box, crashing mediamtx on
        # startup. mediamtx still pulls RTSP from cameras as a *client*
        # — that path is independent of the server settings below.
        mediamtxBootstrap = devenvPkgs.writeText "mediamtx-dev.yml" ''
          api: yes
          apiAddress: :9997
          webrtc: yes
          webrtcAddress: :8889
          webrtcEncryption: no
          webrtcAllowOrigins:
            - '*'
          rtsp: no
          rtmp: no
          hls: no
          srt: no
          playback: no
          logLevel: info
        '';
      in
      {
        # `nix build .#hnvr-web` yields a derivation with
        # bin/{hnvr-leader,hnvr-node}.
        packages = localPkgs // { default = localPkgs.hnvr-web; };

        # -------------------------------------------------------------
        # devenv-integrated dev shell.
        #
        # Replaces the previous plain `pkgs.mkShell`. The shell still
        # works under `nix develop` and direnv (`use flake`), but now
        # also exposes `devenv up` which launches the four services
        # the leader VM normally provides (Postgres, MinIO, NATS,
        # MediaMTX). Env vars consumed by HNVR binaries (HNVR_NATS_URI,
        # HNVR_S3_*, DATABASE_URL, etc.) are pre-wired so cabal-built
        # binaries drop straight into a working environment.
        #
        # `nix develop` MUST be invoked with `--no-pure-eval` (or via
        # direnv which already does so) — `devenv up` needs to query
        # the working directory at runtime, which pure eval forbids.
        # See https://devenv.sh/guides/using-with-flakes/.
        #
        # MinIO is `meta.insecure = true` in nixpkgs (CVE history).
        # We construct a dedicated pkgs instance for the devenv shell
        # only — production deployments use the SeaweedFS SaaS, never
        # this dev MinIO.
        # -------------------------------------------------------------
        devShells.default = devenv.lib.mkShell {
          inherit inputs;
          pkgs = devenvPkgs;
          modules = [
            ({ pkgs, config, lib, ... }: {
              # devenv auto-detects root via `builtins.getEnv "PWD"`,
              # which returns "" under pure eval (CI `nix flake check`).
              # Fall back to the flake's own source path so the shell
              # evaluates cleanly in pure mode. Under no-pure-eval (real
              # `nix develop`), PWD wins and points at Sergey's working
              # tree so state files land in the right place.
              devenv.root =
                let pwd = builtins.getEnv "PWD";
                in if pwd != "" then pwd else inputs.self.outPath;

              packages = [
                devenvHpkgs.ghc
                devenvHpkgs.cabal-install
                devenvHpkgs.ghcid
                devenvHpkgs.hlint
                pkgs.ormolu
                devenvHpkgs.cabal-fmt
                pkgs.nixpkgs-fmt
                # ---- Runtime deps for local testing --------------------
                pkgs.ffmpeg_7-full
                pkgs.onnxruntime
                # NOTE: cabal build all needs pg_config for postgresql-libpq-configure.
                # We currently can't pull postgresql/libpq here without enabling
                # nix's experimental pipe-operators feature (nixpkgs at our pinned
                # rev uses `<|` syntax in the postgresql family). cabal build all
                # is therefore verified in CI only (CI uses Nix 2.35+).

                # ---- Utilities -------------------------------------------
                pkgs.curl
                pkgs.jq
                pkgs.direnv
              ];

              # ---- Services (managed by `devenv up`) ----------------------

              # PostgreSQL 18 — matches the design's SaaS PG version.
              # IHP needs TCP (not just unix socket) because the leader
              # binary may run as a different user than the dev shell.
              # Trust auth mirrors the leader VM (nix/module.nix).
              #
              # Port 15432 (not the default 5432) — Sergey's dev box
              # runs a system postgres on :5432 (langfuse / zulip-dicts
              # build). Use a non-conflicting port; DATABASE_URL below
              # is updated to match.
              services.postgres = {
                enable = true;
                package = pkgs.postgresql_18;
                listen_addresses = "127.0.0.1";
                port = 15432;
                initialDatabases = [{
                  name = "hnvr";
                  user = "hnvr";
                  schema = ./hnvr-web/Application/Schema.sql;
                }];
                hbaConf = ''
                  local all all trust
                  host  all all 127.0.0.1/32 trust
                  host  all all ::1/128 trust
                '';
              };

              # MinIO — S3-compatible storage for fMP4 segments. Buckets
              # are auto-created on first start; no `mc mb` needed.
              # Matches the credentials used in MEMORIES.md pitfall #30
              # and the hnvr-s3-upload integration binary examples.
              services.minio = {
                enable = true;
                listenAddress = "127.0.0.1:9100";
                consoleAddress = "127.0.0.1:9101";
                accessKey = "minioadmin";
                secretKey = "minioadmin";
                buckets = [ "hnvr-recordings" ];
              };

              # NATS — IPC spine. Auth + JetStream on; matches what the
              # VM runs (nix/nats-server.nix) and the URI form the binaries
              # expect (user:pass@host — pitfall #31).
              services.nats = {
                enable = true;
                port = 4222;
                monitoring.enable = true;
                monitoring.port = 8222;
                authorization = {
                  enable = true;
                  user = "nats";
                  password = "nats";
                };
                jetstream.enable = true;
              };

              # MediaMTX — RTSP→WebRTC WHEP bridge (leader-only). Not a
              # built-in devenv service, so we drive it as a custom
              # process. The bootstrap config only enables REST + WebRTC
              # listeners; the leader's MediaMTXConfigSyncer pushes
              # per-camera path config live via PUT /v2/config/paths/<slug>
              # once cameras are added in the IHP UI.
              processes.mediamtx.exec =
                "${pkgs.mediamtx}/bin/mediamtx ${mediamtxBootstrap}";
              # Readiness probe — mediamtx 1.18.2 uses /v3/* API prefix
              # (NOT /v2/* — that was 1.7-1.15; HNVR's MediaMTXConfigSyncer
              # has a separate bug to migrate). /v3/info is the lightest
              # unauthenticated GET (returns version + start time).
              processes.mediamtx.ready = {
                exec = "${pkgs.curl}/bin/curl -fsS -o /dev/null http://127.0.0.1:9997/v3/info";
                initial_delay = 2;
                period = 5;
                probe_timeout = 3;
                failure_threshold = 5;
              };

              # MinIO's built-in devenv service module defines
              # `processes.minio.exec` but no readiness probe — the TUI
              # shows "no health status" until we add one. /minio/health/
              # live is MinIO's official unauthenticated liveness check.
              processes.minio.ready = {
                exec = "${pkgs.curl}/bin/curl -fsS -o /dev/null http://127.0.0.1:9100/minio/health/live";
                initial_delay = 2;
                period = 5;
                probe_timeout = 3;
                failure_threshold = 5;
              };

              # ---- Environment variables consumed by HNVR binaries ------
              #
              # These mirror what the NixOS leader VM sets via the
              # systemd Environment= block. Sergey's canonical dev
              # commands (./result/bin/hnvr-leader, hnvr-node,
              # hnvr-capture-loop, hnvr-s3-upload) read these and just
              # work — no manual export needed.
              env = {
                HNVR_NATS_URI = "nats://nats:nats@localhost:4222";
                HNVR_HOST = "hnvr-2";
                HNVR_S3_ENDPOINT = "http://localhost:9100";
                HNVR_S3_ACCESS_KEY = "minioadmin";
                HNVR_S3_SECRET_KEY = "minioadmin";
                HNVR_S3_BUCKET = "hnvr-recordings";
                HNVR_MEDIAMTX_API = "http://127.0.0.1:9997";
                HNVR_MEDIAMTX_WEBRTC = "http://127.0.0.1:8889";
                # ConfigSyncer writes here in prod (/run/hnvr/mediamtx.yml).
                # In dev we point it at DEVENV_STATE so the leader can
                # write without root.
                HNVR_MEDIAMTX_CONFIG_PATH = "${config.env.DEVENV_STATE}/hnvr-mediamtx.yml";
                # IHP reads DATABASE_URL when present. Devenv's PG unix
                # socket lives under $DEVENV_RUNTIME/postgres; the TCP
                # port matches services.postgres.port (15432 — Sergey's
                # system postgres owns :5432).
                DATABASE_URL = "postgresql:///hnvr?host=127.0.0.1&port=15432";
                # Port 8000 is Taiga on Sergey's box (pitfall #13).
                PORT = "18001";
              };

              enterShell = preCommit.shellHook + ''
                echo ""
                echo "  HNVR dev shell — $(ghc --version)"
                echo "  Build:     cabal build all"
                echo "  REPL:      cabal repl"
                echo "  Services:  devenv up   (postgres :15432, minio :9100,"
                echo "                          nats :4222, mediamtx :9997)"
                echo "  Health:    curl localhost:8222/healthz         (nats)"
                echo "             curl localhost:9997/v2/config/paths  (mediamtx)"
                echo "             curl localhost:9101/minio/health/live (minio)"
                echo ""
              '';
            })
          ];
        };

        checks = {
          pre-commit = preCommit;
          build-all = localPkgs.hnvr-web;
        };

        formatter = pkgs.nixpkgs-fmt;
      }))
    // {
      # NixOS modules — consumed by nixosConfigurations below, also
      # re-exportable so downstream users can `imports: [ hnvr.nixosModules.hnvr ]`.
      nixosModules = {
        hnvr-nats = import ./nix/nats-server.nix;
        hnvr-mediamtx = import ./nix/mediamtx.nix;
        hnvr = import ./nix/module.nix;
        default = self.nixosModules.hnvr;
      };

      # Demo VMs. Build & run with:
      #   nix run .#nixosConfigurations.hnvr-2-vm.config.system.build.vm
      nixosConfigurations = {
        hnvr-1-vm = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = mkWorkerVmModules;
        };
        hnvr-2-vm = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = mkLeaderVmModules;
        };
      };
    };
}
