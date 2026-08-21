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
    # M4 (Aug 11 2026): sops-nix for production secrets. Dev (devenv)
    # keeps using plaintext env vars — sops-nix activation is opt-in
    # per-host via `services.hnvr.secrets.enable = true;`.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Phase 6+ (disks):
    #   disko.url = "github:nix-community/disko";

    # devenv — manages local dev services (Postgres, NATS, MediaMTX)
    # via `devenv up` inside `nix develop`. Flake-integrated: the devShell
    # is built via devenv.lib.mkShell instead of plain pkgs.mkShell, so
    # `nix develop` lands in a devenv-aware shell.
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, pre-commit-hooks, ihp, devenv, sops-nix, ... }:
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

        # minio-hs 1.7.0 sends `continuation_token` (underscore) where
        # ListObjectsV2 requires `continuation-token` (hyphen) — MinIO
        # ignores it and paginated listings loop page 1 forever, which
        # OOM'd the leader on 2026-08-15 (RSS 13→47 GB in 3 h). Upstream
        # is unmaintained (bug on master); use the vendored copy, patched
        # with the continuation-token fix plus the same crypton-connection
        # patches nixpkgs applies (minio-hs PR #191, commits 786cf188 +
        # e2169892) so it builds against tls 2.x.
        minio-hs = libHs.dontCheck (final.callCabal2nix "minio-hs" ./vendored/minio-hs { });

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

        # postgresql-simple-migration 0.1.15.0 (last released 2020) pins
        # bytestring <0.11, text <1.3, time <1.10 — all stale on GHC 9.12.
        # doJailbreak lifts the bounds; the library is otherwise compatible
        # (postgresql-simple >=0.4 covers our 0.8.x at runtime).
        postgresql-simple-migration =
          libHs.doJailbreak prev.postgresql-simple-migration;

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

          # Compiled static assets (app.css) — built via the tailwindcss
          # standalone CLI. Lives at the top level so the NixOS leader
          # module can do `pkgs.hnvr-static` for its staticAssets option.
          hnvr-static = prev.stdenv.mkDerivation {
            name = "hnvr-static";
            # Tailwind scans the whole hnvr-web tree to resolve the
            # `content` globs in tailwind.config.js (relative paths).
            src = ./hnvr-web;
            nativeBuildInputs = [ prev.tailwindcss ];
            buildPhase = ''
              tailwindcss --input static/src.css --output static/app.css --minify
            '';
            installPhase = ''
              mkdir -p $out
              cp static/app.css $out/app.css
              cp static/app.js $out/app.js
              cp static/ptz.js $out/ptz.js
              cp static/timeline.js $out/timeline.js
            '';
          };
        in
        {
          inherit (hpkgs)
            hnvr-core hnvr-nats hnvr-capture hnvr-cv hnvr-ptz hnvr-storage hnvr-web;
          inherit hnvr-static;
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
        sops-nix.nixosModules.sops
        self.nixosModules.hnvr-nats
        self.nixosModules.hnvr-mediamtx
        self.nixosModules.hnvr-secrets
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
        sops-nix.nixosModules.sops
        self.nixosModules.hnvr-nats
        self.nixosModules.hnvr-secrets
        ({ pkgs, ... }: {
          # Worker VM runs its own local NATS for Phase 0 demo purposes
          # (so the node has something to connect to without inter-VM
          # networking). Real deployments only run NATS on the leader;
          # the worker reaches it over the LAN.
          services.hnvr.nats.enable = true;

          systemd.services.hnvr-node = {
            description = "HNVR worker (CaptureSupervisor + CV analysis)";
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

        # -------------------------------------------------------------
        # hnvr-static: compiles hnvr-web/static/src.css via the
        # tailwindcss standalone CLI (nixpkgs#tailwindcss — no npm,
        # no node, single Go binary). Scans HSX in src/Hnvr/Web/View
        # for class names and emits a minified static/app.css.
        #
        # Consumed by nix/module.nix (copies app.css into the leader's
        # ${dataDir}/static/ in systemd preStart). Iteration in dev via
        # `devenv up` which runs tailwindcss in watch mode.
        #
        # The build copies the whole hnvr-web/ tree so tailwind can
        # resolve the `content` globs in tailwind.config.js (they are
        # relative to the config file's directory).
        # -------------------------------------------------------------
        hnvr-static = pkgs.stdenv.mkDerivation {
          name = "hnvr-static";
          src = ./hnvr-web;
          nativeBuildInputs = [ pkgs.tailwindcss ];
          buildPhase = ''
            cp ${./hnvr-web/tailwind.config.js} tailwind.config.js
            tailwindcss --input static/src.css --output static/app.css --minify
          '';
          installPhase = ''
            mkdir -p $out
            cp static/app.css $out/app.css
            cp static/app.js $out/app.js
            cp static/ptz.js $out/ptz.js
            cp static/timeline.js $out/timeline.js
          '';
        };

        localPkgs = {
          inherit (hpkgs)
            hnvr-core hnvr-nats hnvr-capture hnvr-cv hnvr-ptz hnvr-storage hnvr-web;
          hnvr-static = hnvr-static;
          onnxruntime-cuda = onnxruntimeCuda;
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
              # app.css is tailwind --minify output (no trailing newline);
              # the devenv watcher regenerates it on every src.css edit.
              excludes = [ "^hnvr-web/gen/" "^vendored/" "^hnvr-web/static/app\\.css$" ];
            };
            trim-trailing-whitespace = {
              enable = true;
              excludes = [ "^hnvr-web/gen/" "^vendored/" ];
            };
          };
        };

        # -------------------------------------------------------------
        # devenv-only pkgs instance. Kept separate from the main `pkgs`
        # so the dev shell can carry dev-only config knobs without
        # touching the production package set. We compose IHP's overlay
        # on top so `ghc912` resolves the same way as the main `pkgs`
        # above; our hnvrHaskellOverlay layers on top of that to expose
        # our packages for fast cabal-style iteration inside the devenv
        # shell.
        # -------------------------------------------------------------
        devenvPkgs = import nixpkgs {
          inherit system;
          overlays = [ ihp.overlays.default mediamtxOverlay ];
        };
        devenvHpkgs = devenvPkgs.ghc912.extend (hnvrHaskellOverlay devenvPkgs.haskell.lib);

        # -------------------------------------------------------------
        # CUDA-enabled onnxruntime (Phase 3). Separate nixpkgs import
        # because cudaSupport + cudaCapabilities are nixpkgs *config*
        # knobs, not overlays. sm_89 = RTX 4090 (hnvr-2 / this dev box).
        # hnvr-1 (GTX 1070, sm_61) needs cudaPackages_12_8 — CUDA 12.9
        # dropped Pascal codegen — and gets its own wiring when the
        # NixOS module grows the GPU slice.
        #
        # allowUnfree: the CUDA redist packages (cudart/cudnn/cublas)
        # are unfree-licensed. pythonSupport=false trims the multi-GB
        # python dist output — we only dlopen libonnxruntime.so.
        #
        # Build explicitly once (`nix build .#onnxruntime-cuda`) before
        # entering a fresh dev shell: the source build takes ~1 h and
        # needs ~15 GB of disk.
        # -------------------------------------------------------------
        cudaPkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
            # 8.9 = RTX 4090 (hnvr-2 / this dev box). hnvr-1's GTX 1070
            # (Pascal, sm_61) is deliberately absent: cuDNN ≥ 9.12
            # dropped Maxwell/Pascal and ORT 1.27's CUDA EP hard-links
            # cuDNN, so hnvr-1 runs the CPU EP in v1 (decision Aug 13
            # 2026 — ~80 ms/frame CPU is fine for 5 fps sub-streams).
            cudaCapabilities = [ "8.9" ];
            # TensorRT redist is marked insecure in nixpkgs (CVE
            # history, same class as MinIO — pitfall #30). Name
            # computed dynamically so nixpkgs bumps don't break eval.
            permittedInsecurePackages = [
              (import nixpkgs {
                inherit system;
                config = {
                  allowUnfree = true;
                  cudaSupport = true;
                  cudaCapabilities = [ "8.9" ];
                };
              }).cudaPackages.tensorrt.name
            ];
          };
        };
        onnxruntimeCuda =
          let
            trt = cudaPkgs.cudaPackages.tensorrt;
            # ORT's cmake expects TENSORRT_ROOT to hold BOTH include/ and
            # lib/ under one prefix; nixpkgs splits them across outputs.
            # `static` is required: the TRT EP links nvonnxparser_static.a.
            tensorrtHome = cudaPkgs.symlinkJoin {
              name = "tensorrt-home-${trt.version}";
              paths = [ trt.out trt.include trt.lib trt.static ];
            };
          in
          (cudaPkgs.onnxruntime.override { pythonSupport = false; }).overrideAttrs (old: {
            buildInputs = old.buildInputs ++ [ trt.lib ];
            cmakeFlags = old.cmakeFlags ++ [
              (nixpkgs.lib.cmakeBool "onnxruntime_USE_TENSORRT" true)
              (nixpkgs.lib.cmakeFeature "onnxruntime_TENSORRT_HOME" "${tensorrtHome}")
              # Use TRT's shipped nvonnxparser (in the redist) instead
              # of building onnx-tensorrt from source — ORT's default
              # path FetchContent's onnx-tensorrt, which conflicts with
              # nixpkgs' FETCHCONTENT_FULLY_DISCONNECTED (no
              # FETCHCONTENT_SOURCE_DIR_ONNX_TENSORRT is wired) and
              # dies at link with `-lnvonnxparser_static not found`.
              (nixpkgs.lib.cmakeBool "onnxruntime_USE_TENSORRT_BUILTIN_PARSER" true)
            ];
          });


        # MediaMTX bootstrap config — leader pushes per-camera path
        # config via REST API (PUT /v2/config/paths/<slug>) once cameras
        # are added in the IHP UI. Mirrors the stubConfig in
        # nix/mediamtx.nix (NixOS module) so prod + dev behave the same.
        #
        # Only API + WebRTC + RTSP-server are enabled. RTMP/HLS/SRT/playback
        # stay off because (a) HNVR doesn't use them (live view = WebRTC;
        # archive HLS is served by the leader, not mediamtx) and (b) the
        # default HLS port :8888 collides with another service on Sergey's
        # dev box, crashing mediamtx on startup.
        #
        # The RTSP *server* on :8554 is enabled (Aug 11 2026 M1 fix) so
        # CaptureWorker pulls from rtsp://localhost:8554/<slug> instead of
        # from the camera directly. mediamtx becomes the single ingestion
        # point: one RTSP session per camera regardless of how many
        # internal consumers (CaptureWorker + N WHEP viewers). Required
        # for cameras with a 1-concurrent-RTSP-session cap (Sergey's
        # cam-196 and cam-198 per Aug 11 2026 debugging).
        mediamtxBootstrap = devenvPkgs.writeText "mediamtx-dev.yml" ''
          api: yes
          apiAddress: :9997
          webrtc: yes
          webrtcAddress: :8889
          webrtcEncryption: no
          webrtcAllowOrigins:
            - '*'
          rtsp: yes
          rtspAddress: :8554
          rtmp: no
          hls: no
          srt: no
          playback: no
          logLevel: info
        '';

        # -------------------------------------------------------------
        # Chromium runtime deps for Playwright (tests/e2e/).
        #
        # Playwright's `npx playwright install chromium` drops a stock
        # Linux chromium at ~/.cache/ms-playwright/. On NixOS the
        # system loader (nix-ld, configured via programs.nix-ld.enable
        # in Sergey's system config) needs to find chromium's ~20
        # shared libs. The system bundle at
        # /run/current-system/sw/share/nix-ld/lib covers glibc + systemd
        # + a few others; we extend NIX_LD_LIBRARY_PATH in enterShell
        # with the chromium-specific deps via pkgs.lib.makeLibraryPath.
        #
        # With this in place, `npx playwright test` works inside
        # `nix develop` without needing to exit to a system shell.
        # -------------------------------------------------------------
        chromiumRuntimeDeps = with devenvPkgs; [
          glib
          nss
          nspr
          atk
          at-spi2-atk
          at-spi2-core
          cups
          libdrm
          dbus
          libxkbcommon
          xorg.libX11
          xorg.libXcomposite
          xorg.libXdamage
          xorg.libXext
          xorg.libXfixes
          xorg.libXrandr
          xorg.libXScrnSaver
          xorg.libxshmfence
          xorg.libXi
          xorg.libXtst
          xorg.libxcb
          mesa
          libgbm
          pango
          cairo
          alsa-lib
          expat
        ];
        chromiumLibPath = devenvPkgs.lib.makeLibraryPath chromiumRuntimeDeps;
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
        # also exposes `devenv up` which launches the dev services
        # (Postgres, NATS, MediaMTX). S3 is the external SeaweedFS at
        # 192.168.0.254:8333 — credentials come from the gitignored
        # hnvr.yaml at the repo root (see hnvr.example.yaml), NOT from
        # this flake. Env vars consumed by HNVR binaries (HNVR_NATS_URI,
        # HNVR_CONFIG, DATABASE_URL, etc.) are pre-wired so cabal-built
        # binaries drop straight into a working environment.
        #
        # `nix develop` MUST be invoked with `--no-pure-eval` (or via
        # direnv which already does so) — `devenv up` needs to query
        # the working directory at runtime, which pure eval forbids.
        # See https://devenv.sh/guides/using-with-flakes/.
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
                # CSS toolchain — tailwind standalone cli (no npm)
                pkgs.tailwindcss
                # ---- Playwright E2E (tests/e2e/) -----------------------
                # node + npm for the dev-only Playwright UI test suite
                # (S4 deliverable, design_docs/10-test-plan.md). The
                # production build is npm-free; this is dev-only.
                pkgs.nodejs
                # ---- Runtime deps for local testing --------------------
                pkgs.ffmpeg_7-full
                pkgs.onnxruntime
                # ultralytics CLI (`yolo`) — dev-only, used to export
                # YOLOv8n-320/YOLOv8s-640 ONNX models for the CV
                # pipeline (Phase 3). AGPL-3.0: export tool only, never
                # linked into HNVR binaries or shipped in the NixOS
                # closure. Pulls in torch — expect a multi-GB closure
                # on first `nix develop`.
                #
                # The top-level `pkgs.ultralytics` wrapper omits the
                # optional ONNX export deps (`import onnx` fails), so we
                # build our own python env with onnx + onnxslim (the
                # 8.4.x simplifier — the old `onnxsim` is gone).
                (pkgs.python3.withPackages (ps: [
                  ps.ultralytics
                  ps.onnx
                  ps.onnxslim
                ]))
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

              # S3 is NOT a devenv service: dev records straight into
              # the external SeaweedFS (http://192.168.0.254:8333,
              # bucket `hnvr`) via hnvr.yaml — see HNVR_CONFIG below.

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

              # Tailwind CSS watcher — rebuild static/app.css whenever
              # HSX markup or src.css changes. Output goes into the
              # project's hnvr-web/static/app.css (committed artifact
              # so the dev leader binary, which reads APP_STATIC=hnvr-web/static,
              # serves the latest CSS without a nix rebuild).
              #
              # The output path is stringified (toString then concatenated)
              # so nix doesn't try to copy app.css into the eval closure —
              # the file is a *build output*, not an input, and may not
              # exist on a fresh checkout.
              processes.tailwind.exec = ''
                ${pkgs.tailwindcss}/bin/tailwindcss \
                  --config ${./hnvr-web/tailwind.config.js} \
                  --input ${./hnvr-web/static/src.css} \
                  --output "${toString ./hnvr-web/static/app.css}" \
                  --watch
              '';

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
                # S3 (SeaweedFS) credentials live in the gitignored
                # hnvr.yaml at the repo root — copy hnvr.example.yaml
                # and fill in the keys. HNVR_S3_* env vars still
                # override the file when set (integration tests).
                HNVR_CONFIG = "${config.devenv.root}/hnvr.yaml";
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
                # Bootstrap admin user — leader idempotently INSERTs
                # this on boot (ON CONFLICT DO NOTHING). Production
                # sources these from sops-nix (Phase 6); dev-only.
                INITIAL_ADMIN_EMAIL = "admin@hnvr.local";
                INITIAL_ADMIN_PASSWORD = "hnvr-dev";
                # AES-256 data key for camera password encryption
                # (Hnvr.Core.Crypto via Web.Controller.Support.Crypto).
                # Stable so dev DB rows stay decryptable across sessions;
                # dev-only — production sources from sops-nix.
                HNVR_DATA_KEY = "j1kGE9Y274/RNq1+TJWKeS4RDocw5+Uu05q3KPKm7XM=";
                # Spool dir for capture segments when S3 is unreachable
                # (NodeMain defaults to /var/lib/hnvr/spool, unwritable
                # for the dev user — spool fallback silently failed in
                # dev until this was set).
                HNVR_SPOOL_DIR = "${config.env.DEVENV_STATE}/spool";
                # ---- Phase 3 CV pipeline --------------------------------
                # libonnxruntime for the internal FFI binding
                # (Hnvr.Cv.OnnxRuntime.Internal, dlopen'd at session
                # creation). CUDA+TensorRT build (sm_89): TRT EP wins,
                # CUDA is the fallback, CPU the safety net. TRT engines
                # are cached in HNVR_TRT_CACHE_DIR (first analyzer start
                # builds, ~1 min). Requires /run/opengl-driver/lib on
                # LD_LIBRARY_PATH for libcuda.so.1 (wired in enterShell
                # below). Model: yolov8n-320 exported into the shared
                # model cache (design 04; exported via the devShell's
                # ultralytics env, see pitfall #97).
                HNVR_ONNXRUNTIME_LIB = "${onnxruntimeCuda}/lib/libonnxruntime.so";
                HNVR_MODEL_PATH = "/home/pion/.local/share/hnvr/model_cache/yolov8/yolov8n-320.onnx";
                # Per-camera model resolution (cameras.model_name →
                # <dir>/<name>.onnx); holds both yolov8n-320 and
                # yolov8s-640 (pitfall #97).
                HNVR_MODEL_DIR = "/home/pion/.local/share/hnvr/model_cache/yolov8";
                # Per-host EP priority (design 04 §"Per-host EP
                # selection"). Dev box is hnvr-2 (RTX 4090): TRT wins,
                # CUDA falls back, CPU is the safety net.
                HNVR_EXEC_PROVIDERS = "tensorrt,cuda,cpu";
                # TRT engine cache (first analyzer start builds the
                # engine, ~1 min; later starts load from cache).
                HNVR_TRT_CACHE_DIR = "${config.env.DEVENV_STATE}/trt-cache";
                # Prometheus metrics endpoint (Hnvr.Web.Metrics, own
                # warp — leader + node). 9102 stays as the dev port
                # (9100 was the old devenv MinIO's port; kept to avoid
                # churn with running dev processes).
                HNVR_METRICS_PORT = "9102";
              };

              enterShell = preCommit.shellHook + ''
                # Extend the system nix-ld library path with chromium's
                # runtime deps so Playwright's `npx playwright install`
                # binary can launch inside `nix develop`. See the
                # `chromiumRuntimeDeps` binding above + tests/e2e/README.md.
                if [ -n "''${NIX_LD_LIBRARY_PATH:-}" ]; then
                  export NIX_LD_LIBRARY_PATH="${chromiumLibPath}:$NIX_LD_LIBRARY_PATH"
                else
                  export NIX_LD_LIBRARY_PATH="${chromiumLibPath}"
                fi

                # CUDA EP needs libcuda.so.1 (the kernel-driver shim),
                # which lives outside the nix store. On NixOS the
                # driver exposes it via /run/opengl-driver/lib.
                if [ -d /run/opengl-driver/lib ]; then
                  export LD_LIBRARY_PATH="/run/opengl-driver/lib:''${LD_LIBRARY_PATH:-}"
                fi

                echo ""
                echo "  HNVR dev shell — $(ghc --version)"
                echo "  Build:     cabal build all"
                echo "  REPL:      cabal repl"
                echo "  Services:  devenv up   (postgres :15432,"
                echo "                          nats :4222, mediamtx :9997)"
                echo "  S3:        hnvr.yaml → http://192.168.0.254:8333 (bucket hnvr)"
                echo "  Health:    curl localhost:8222/healthz         (nats)"
                echo "             curl localhost:9997/v2/config/paths  (mediamtx)"
                echo "  E2E:       cd tests/e2e && npm install && npx playwright install chromium && npm test"
                echo ""
              '';
            })
          ];
        };

        # -------------------------------------------------------------
        # NixOS VM smoke test (S5 deliverable, design_docs/10-test-plan.md).
        # Boots the leader VM via the test framework, waits for
        # hnvr-leader.service + /healthz, and probes the dashboard.
        # Runs as part of `nix flake check` (under #checks.x86_64-linux).
        #
        # The two-node failover variant is TODO — it requires
        # reconfiguring both VMs to peer with a shared NATS cluster so
        # health messages cross VM boundaries (current worker VM uses
        # its own localhost NATS per Phase 0 demo wiring).
        # -------------------------------------------------------------
        checks = {
          pre-commit = preCommit;
          build-all = localPkgs.hnvr-web;
          hnvr-leader-smoke = pkgs.testers.nixosTest {
            name = "hnvr-leader-smoke";

            nodes.leader = { pkgs, ... }: {
              nixpkgs.overlays = [
                ihp.overlays.default
                mediamtxOverlay
                hnvrTopOverlay
              ];

              imports = [
                self.nixosModules.hnvr-nats
                self.nixosModules.hnvr-mediamtx
                self.nixosModules.hnvr
              ];

              services.hnvr.nats.enable = true;
              services.hnvr.mediamtx.enable = true;
              services.hnvr.leader.enable = true;
              services.hnvr.leader.hostName = "hnvr-2";

              # IHP needs a Postgres. Local for the VM test; production
              # pulls from the SaaS via DATABASE_URL.
              services.postgresql.enable = true;
              services.postgresql.ensureDatabases = [ "hnvr" ];
              services.postgresql.ensureUsers = [{
                name = "hnvr";
                ensureDBOwnership = true;
              }];
              services.postgresql.authentication = ''
                local all all trust
              '';

              virtualisation.memorySize = 2048;
              virtualisation.cores = 2;

              # Trust LAN — disable firewall for dev simplicity.
              networking.firewall.enable = false;
            };

            testScript = ''
              start_all()

              # Wait for systemd to bring up the hnvr-leader service. The
              # leader has several initializers (NATS connect,
              # schema ensureTrigger, ConfigBroadcaster LISTEN,
              # MediaMTXConfigSyncer) — give it room.
              leader.wait_for_unit("hnvr-leader.service", timeout=120)
              leader.wait_for_open_port(8000, timeout=60)

              # /healthz works even when other deps are flapping
              # (Config.hs CustomMiddleware short-circuits before
              # IHP's request flow — pitfall #60).
              leader.succeed("curl -fsS -o /dev/null http://localhost:8000/healthz")

              # Login page renders (Slice 8 Aug 10 2026 admin gate).
              leader.succeed("curl -fsS -o /dev/null http://localhost:8000/NewSession")

              print("hnvr-leader-smoke: PASS")
            '';
          };
        };

        formatter = pkgs.nixpkgs-fmt;
      }))
    // {
      # NixOS modules — consumed by nixosConfigurations below, also
      # re-exportable so downstream users can `imports: [ hnvr.nixosModules.hnvr ]`.
      nixosModules = {
        hnvr-nats = import ./nix/nats-server.nix;
        hnvr-mediamtx = import ./nix/mediamtx.nix;
        hnvr-secrets = import ./nix/secrets.nix;
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
