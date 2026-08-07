{
  description = "HNVR — Haskell Network Video Recorder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Deferred to Phase 0 (need a 9.12-capable commit):
    #   ihp.url        = "github:digitallyinduced/ihp/<commit>";
    # Phase 2+ (live view):
    #   mediamtx.url   = "github:bluenviron/mediamtx/v1.20.0";
    # Phase 6+ (secrets, disks):
    #   sops-nix.url   = "github:Mic92/sops-nix";
    #   disko.url      = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, flake-utils, pre-commit-hooks, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) haskell lib;

        # -------------------------------------------------------------
        # GHC 9.12 + jailbreaks for stale upper bounds + our local
        # packages, all in one overlay so callCabal2nix's dependency
        # inference finds our local versions of hnvr-*.
        # -------------------------------------------------------------
        haskellOverlay = final: prev: {
          # amazonka 2.0 caps at GHC 9.6; we lift it for 9.12.
          # Add more entries as `cabal build all` discovers failures.
          amazonka-core = lib.pipe prev.amazonka-core [
            haskell.lib.markUnbroken
            haskell.lib.doJailbreak
          ];
          amazonka-s3 = lib.pipe prev.amazonka-s3 [
            haskell.lib.markUnbroken
            haskell.lib.doJailbreak
          ];

          # Our packages. `final:` ensures hnvr-web sees our hnvr-core,
          # hnvr-capture sees our hnvr-storage, etc.
          hnvr-core    = final.callCabal2nix "hnvr-core"    ./hnvr-core    {};
          hnvr-nats    = final.callCabal2nix "hnvr-nats"    ./hnvr-nats    {};
          hnvr-capture = final.callCabal2nix "hnvr-capture" ./hnvr-capture {};
          hnvr-cv      = final.callCabal2nix "hnvr-cv"      ./hnvr-cv      {};
          hnvr-ptz     = final.callCabal2nix "hnvr-ptz"     ./hnvr-ptz     {};
          hnvr-storage = final.callCabal2nix "hnvr-storage" ./hnvr-storage {};
          hnvr-web     = final.callCabal2nix "hnvr-web"     ./hnvr-web     {};
        };

        hpkgs = pkgs.haskell.packages.ghc912.extend haskellOverlay;

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
            hlint  = hpkgs.hlint;
          };
          hooks = {
            ormolu.enable = true;
            hlint.enable = true;
            nixpkgs-fmt.enable = true;
            end-of-file-fixer.enable = true;
            trim-trailing-whitespace.enable = true;
          };
        };
      in {
        # What `nix build .#<name>` produces
        #
        # Building .#hnvr-web (or .#default) yields both binaries in
        # result/bin/{hnvr-leader,hnvr-node}.
        packages = localPkgs // {
          default = localPkgs.hnvr-web;
        };

        # What `nix develop` drops you into
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # ---- Haskell toolchain (GHC 9.12) -------------------------
            hpkgs.ghc
            hpkgs.cabal-install
            hpkgs.ghcid
            hpkgs.hlint
            # (haskell-language-server omitted — may not yet be available
            # for ghc912 on every nixpkgs revision; add when needed)

            # ---- Formatters ------------------------------------------
            pkgs.ormolu
            hpkgs.cabal-fmt
            pkgs.nixpkgs-fmt

            # ---- Runtime deps for local testing ----------------------
            pkgs.ffmpeg_7-full
            pkgs.onnxruntime
            pkgs.nats-server

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

        # What `nix flake check` runs
        checks = {
          pre-commit = preCommit;
          build-all = localPkgs.hnvr-web;
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
