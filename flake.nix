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

    # Phase 2 (live view): nixpkgs.mediamtx 1.18.2 used for packaging
    # the sidecar; if Slice 3 WHEP verification fails on Chrome 130+
    # (roadmap decision point at Phase 2 kickoff), uncomment to pin
    # v1.20.0 source and build via buildGoModule overlay.
    #   mediamtx.url = "github:bluenviron/mediamtx/v1.20.0";
    # Phase 6+ (secrets, disks):
    #   sops-nix.url   = "github:Mic92/sops-nix";
    #   disko.url      = "github:nix-community/disko";
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, pre-commit-hooks, ihp, ... }:
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
      # Per-host NixOS module stacks. Both VMs apply IHP + hnvr overlays
      # top-level (so pkgs.hnvr-web resolves). The worker VM is just a
      # stub for Phase 0 — hnvr-node has no NATS client yet (Phase 2).
      # -------------------------------------------------------------
      baseVmConfig = { config, pkgs, lib, ... }: {
        nixpkgs.overlays = [ ihp.overlays.default hnvrTopOverlay ];

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
        pkgs = nixpkgs.legacyPackages.${system}.extend ihp.overlays.default;
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
      in
      {
        # `nix build .#hnvr-web` yields a derivation with
        # bin/{hnvr-leader,hnvr-node}.
        packages = localPkgs // { default = localPkgs.hnvr-web; };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            hpkgs.ghc
            hpkgs.cabal-install
            hpkgs.ghcid
            hpkgs.hlint
            pkgs.ormolu
            hpkgs.cabal-fmt
            pkgs.nixpkgs-fmt
            # ---- Runtime deps for local testing ----------------------
            pkgs.ffmpeg_7-full
            pkgs.onnxruntime
            pkgs.nats-server
            # NOTE: cabal build all needs pg_config for postgresql-libpq-configure.
            # We currently can't pull postgresql/libpq here without enabling
            # nix's experimental pipe-operators feature (nixpkgs at our pinned
            # rev uses `<|` syntax in the postgresql family). cabal build all
            # is therefore verified in CI only (CI uses Nix 2.35+).<|code_middle|><d076e6aa>

            # ---- Utilities -------------------------------------------
            pkgs.curl
            pkgs.jq
            pkgs.direnv
          ];

          shellHook = preCommit.shellHook + ''
            echo ""
            echo "  HNVR dev shell — $(ghc --version)"
            echo "  Build:    cabal build all"
            echo "  REPL:     cabal repl"
            echo "  Nix:      nix flake check"
            echo ""
          '';
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
