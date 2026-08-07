# HNVR — Deployment

Multi-host NixOS deployment. Two hosts. NATS is in our scope; Postgres and SeaweedFS are external SaaS and **not** managed by this flake.

## Hosts

| Host | GPU | Default role | Cameras | Services running |
|------|-----|--------------|---------|------------------|
| `hnvr-1` | GTX 1070 (Pascal sm_61) | Worker node | ~50% | `hnvr-node.service`, `nats-server.service` (replica) |
| `hnvr-2` | RTX 4090 (Ada sm_89) | Leader | ~50% | `hnvr-leader.service`, `nats-server.service` (primary), `mediamtx.service`, `nginx.service` |

Either host can take over the other's cameras via NATS command bus. Only the leader runs the IHP web node and MediaMTX.

## Flake layout

```
hnvr/
├── flake.nix                   -- outputs: nixosModules.hnvr, nixosConfigurations.{hnvr-1,hnvr-2}, devShells
├── flake.lock
├── nix/
│   ├── module.nix              -- common NixOS module (HNVR settings, secrets, hardening)
│   ├── leader.nix              -- leader-only additions (MediaMTX, IHP, leader logic)
│   ├── nat-server.nix          -- NATS server config (clustered)
│   ├── mediamtx.nix            -- MediaMTX derivation (or flake input)
│   ├── models.nix              -- fetchurl'd ONNX models, pinned by sha256
│   ├── engines/                -- pre-built TensorRT engines per (model, sm)
│   │   ├── yolov8n-320.sm_89.engine.nix
│   │   └── yolov8s-640.sm_89.engine.nix
│   └── data-key.nix            -- placeholder; real key via sops-nix
├── secrets/
│   ├── secrets.yaml            -- sops-encrypted YAML
│   └── .sops.yaml              -- per-host key definition
├── hosts/
│   ├── hnvr-1.nix              -- host-specific config (GPU, networking, role=worker)
│   ├── hnvr-2.nix              -- host-specific config (GPU, role=leader, nginx)
│   ├── hnvr-1.hardware.nix     -- disko / hardware-config
│   └── hnvr-2.hardware.nix
├── hnvr-core/...
├── hnvr-nats/...
├── hnvr-capture/...
├── hnvr-cv/...
├── hnvr-storage/...
└── hnvr-web/...
```

## `flake.nix` skeleton

```nix
{
  description = "HNVR — Haskell Network Video Recorder";

  inputs = {
    nixpkgs.url       = "github:NixOS/nixpkgs/nixos-unstable";  # for GHC 9.12 + TensorRT
    ihp.url           = "github:digitallyinduced/ihp/<commit-with-9.12-support>";
    mediamtx.url      = "github:bluenviron/mediamtx/v1.20.0";
    sops-nix.url      = "github:Mic92/sops-nix";
    haskell-flake.url = "github:srid/haskell-flake";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    disko.url         = "github:nix-community/disko";
  };

  outputs = inputs @ { self, nixpkgs, ... }:
    let
      mkHost = { name, role, system ? "x86_64-linux" }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs name role; };
          modules = [
            inputs.disko.nixosModules.disko
            inputs.sops-nix.nixosModules.sops
            ./hosts/${name}.hardware.nix
            ./hosts/${name}.nix
            ./nix/module.nix
            (if role == "leader" then ./nix/leader.nix else {})
            ./nix/nat-server.nix
            self.nixosModules.hnvrHaskell
          ];
        };
    in {
      nixosModules.hnvr         = import ./nix/module.nix;
      nixosModules.hnvrHaskell  = import ./nix/haskell-overlay.nix inputs;

      nixosConfigurations = {
        hnvr-1 = mkHost { name = "hnvr-1"; role = "worker"; };
        hnvr-2 = mkHost { name = "hnvr-2"; role = "leader"; };
      };

      devShells.x86_64-linux.default =
        import ./nix/devshell.nix { inherit inputs; pkgs = nixpkgs.legacyPackages.x86_64-linux; };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt;
    };
}
```

## Haskell overlay (`nix/haskell-overlay.nix`)

GHC 9.12 + IHP pinned to a 9.12-capable commit. Jailbreak known-stale upper bounds.

```nix
inputs: { pkgs, config, lib, ... }:

let
  hpkgs = pkgs.haskell.packages.ghc912.override {
    overrides = self: super: {
      ihp = inputs.ihp.haskellPackages.${super.ghc.version}.ihp
          or (super.callCabal2nix "ihp" inputs.ihp { });

      # Jailbreak upper bounds blocking GHC 9.12
      amazonka-core = lib.pipe super.amazonka-core [
        (p: p.overrideAttrs (_: { jailbreak = true; }))
      ];
      amazonka-s3   = lib.pipe super.amazonka-s3 [
        (p: p.overrideAttrs (_: { jailbreak = true; }))
      ];

      # Our packages
      hnvr-core    = self.callCabal2nix "hnvr-core"    ../hnvr-core   {};
      hnvr-nats    = self.callCabal2nix "hnvr-nats"    ../hnvr-nats   {};
      hnvr-capture = self.callCabal2nix "hnvr-capture" ../hnvr-capture {};
      hnvr-cv      = self.callCabal2nix "hnvr-cv"      ../hnvr-cv      {};
      hnvr-storage = self.callCabal2nix "hnvr-storage" ../hnvr-storage {};
      hnvr-web     = self.callCabal2nix "hnvr-web"     ../hnvr-web     {};
    };
  };

  # Build the leader and node binaries
  hnvr-leader-bin = hpkgs.hnvr-web.components.exes.hnvr-leader;
  hnvr-node-bin   = hpkgs.hnvr-web.components.exes.hnvr-node;

in {
  config.services.hnvr._hpkgs = hpkgs;
  config.services.hnvr._binaries = { inherit hnvr-leader-bin hnvr-node-bin hpkgs; };
}
```

## Common NixOS module (`nix/module.nix`)

```nix
{ config, lib, pkgs, name, role, ... }:

let
  cfg = config.services.hnvr;
  inherit (cfg._binaries) hnvr-leader-bin hnvr-node-bin hpkgs;

  # Pick EPs per host (overridable per-host)
  execProviders = lib.concatStringsSep ","
    (cfg.execProviders or (if role == "leader"
                           then ["tensorrt" "cuda" "cpu"]
                           else ["cuda" "cpu"]));

  models = pkgs.callPackage ./nix/models.nix {};
in {
  options.services.hnvr = {
    enable = lib.mkEnableOption "HNVR";

    dataDir = lib.mkOption { type = lib.types.path; default = "/var/lib/hnvr"; };

    role = lib.mkOption {
      type = lib.types.enum ["worker" "leader"];
      default = role;
    };

    execProviders = lib.mkOption {
      type = lib.types.listOf (lib.types.enum ["cpu" "cuda" "tensorrt" "rocm"]);
      description = "ONNX Runtime execution providers (priority order)";
    };

    initialAdminEmail = lib.mkOption { type = lib.types.str; };
  };

  config = lib.mkIf cfg.enable {

    # ----- users -----------------------------------------------------------
    users.users.hnvr = {
      isSystemUser = true;
      group = "hnvr";
      home = cfg.dataDir;
      createHome = true;
    };
    users.groups.hnvr = {};

    # ----- secrets (sops-nix) ---------------------------------------------
    sops.secrets.hnvr-data-key       = { owner = "hnvr"; mode = "0400"; };
    sops.secrets.hnvr-db-url         = { owner = "hnvr"; mode = "0400"; };
    sops.secrets.hnvr-s3-access-key  = { owner = "hnvr"; mode = "0400"; };
    sops.secrets.hnvr-s3-secret-key  = { owner = "hnvr"; mode = "0400"; };
    sops.secrets.hnvr-nats-creds     = { owner = "hnvr"; mode = "0400"; };
    sops.secrets.initial-admin-pw    = { owner = "hnvr"; mode = "0400"; };

    # ----- hnvr-node service (worker role, runs on BOTH hosts) ------------
    systemd.services.hnvr-node = {
      description = "HNVR worker node (capture + analysis)";
      after    = [ "network-online.target" "nats.service" ];
      wants    = [ "nats.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        HNVR_HOST_ID          = name;
        HNVR_ROLE             = "worker";
        HNVR_NATS_URL         = "nats://127.0.0.1:4222";
        HNVR_NATS_CREDS_FILE  = "@${config.sops.secrets.hnvr-nats-creds.path}";
        HNVR_S3_ENDPOINT      = "https://s3.example.internal";
        HNVR_S3_ACCESS_KEY    = "@${config.sops.secrets.hnvr-s3-access-key.path}";
        HNVR_S3_SECRET_KEY    = "@${config.sops.secrets.hnvr-s3-secret-key.path}";
        HNVR_EXEC_PROVIDERS   = execProviders;
        HNVR_MODELS_DIR       = "${models}";
        HNVR_ENGINES_DIR      = "${cfg.dataDir}/engines";
      };

      path = with pkgs; [ ffmpeg_7-full onnxruntime cudaPackages.cudatoolkit ];

      serviceConfig = {
        ExecStart = "${hnvr-node-bin}/bin/hnvr-node";
        User = "hnvr"; Group = "hnvr";
        WorkingDirectory = cfg.dataDir;
        StateDirectory = "hnvr";
        RuntimeDirectory = "hnvr";
        Restart = "always"; RestartSec = "5s";
        LimitNOFILE = "65536";
        # Pin to CPU set so CV doesn't fight web on the leader
        CPUAffinity = if role == "worker" then "0-7" else "0-7";
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir "/run/hnvr" "/var/log/hnvr" ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;  # JIT in onnxruntime / GHC RTS
        SystemCallArchitectures = "native";
      };
    };

    # ----- hnvr-leader service (leader-only, on hnvr-2) --------------------
    systemd.services.hnvr-leader = lib.mkIf (role == "leader") {
      description = "HNVR leader (web + event writer + assignment coordinator)";
      after    = [ "network-online.target" "nats.service" "hnvr-node.service" ];
      wants    = [ "nats.service" "hnvr-node.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        HNVR_HOST_ID          = name;
        HNVR_ROLE             = "leader";
        HNVR_DB_URL           = "@${config.sops.secrets.hnvr-db-url.path}";
        HNVR_NATS_URL         = "nats://127.0.0.1:4222";
        HNVR_NATS_CREDS_FILE  = "@${config.sops.secrets.hnvr-nats-creds.path}";
        HNVR_S3_ENDPOINT      = "https://s3.example.internal";
        HNVR_S3_ACCESS_KEY    = "@${config.sops.secrets.hnvr-s3-access-key.path}";
        HNVR_S3_SECRET_KEY    = "@${config.sops.secrets.hnvr-s3-secret-key.path}";
        HNVR_EXEC_PROVIDERS   = execProviders;
        HNVR_MODELS_DIR       = "${models}";
        HNVR_MEDIAMTX_CFG     = "/run/hnvr/mediamtx.yml";
        INITIAL_ADMIN_EMAIL   = cfg.initialAdminEmail;
        INITIAL_ADMIN_PASSWORD= "@${config.sops.secrets.initial-admin-pw.path}";
      };

      path = with pkgs; [ ffmpeg_7-full onnxruntime cudaPackages.cudatoolkit ];

      serviceConfig = {
        ExecStart = "${hnvr-leader-bin}/bin/hnvr-leader";
        User = "hnvr"; Group = "hnvr";
        WorkingDirectory = cfg.dataDir;
        StateDirectory = "hnvr";
        RuntimeDirectory = "hnvr";
        Restart = "always"; RestartSec = "5s";
        LimitNOFILE = "65536";
        CPUAffinity = "8-15";   # leave 0-7 for the worker
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir "/run/hnvr" "/var/log/hnvr" ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
        SystemCallArchitectures = "native";
      };
    };

    # ----- logrotate -------------------------------------------------------
    services.logrotate.settings.hnvr = {
      files = [ "/var/log/hnvr/*.log" ];
      frequency = "daily";
      rotate = 14; compress = true; delaycompress = true;
      missingok = true; notifempty = true;
    };

    # ----- Prometheus node exporter (scraped by external Prometheus) ------
    services.prometheus.exporters.node = {
      enable = true; enabledCollectors = [ "nvidia" "systemd" ];
    };
    services.prometheus.exporters.nvidia-gpu = {
      enable = true; port = 9401;
    };
  };
}
```

## NATS server module (`nix/nat-server.nix`)

```nix
{ config, lib, pkgs, name, role, ... }:
let
  isPrimary = role == "leader";   # leader host = NATS primary
in {
  services.nats = {
    enable = true;
    package = pkgs.nats-server;
    serverName = name;
    port = 4222;
    jetstream = {
      enable = true;
      storage = "/var/lib/nats/jetstream";
      maxMemory = "1GB";
      maxFile = "10GB";
    };
    settings = {
      http_port = 8222;            # monitoring
      cluster = {
        name = "HNVR";
        routes = lib.optionals (!isPrimary)
          [ "nats://hnvr-2:4222" ];
        # On the primary, advertise self for inbound
        advertise = lib.optionalString isPrimary name;
      };
      # Auth via NATS creds (user accounts) — wire via sops-nix
      authorize = "user";
    };
    credentialsFile = config.sops.secrets.hnvr-nats-creds.path;
  };

  networking.firewall.allowedTCPPorts = [ 4222 6222 8222 ];
}
```

In v1, single-node NATS on hnvr-2 is sufficient. The cluster stanza is wired but the second node's `routes` is optional — only enable post-v1 when we want HA on the message bus itself.

## Leader module (`nix/leader.nix`)

Adds nginx + MediaMTX + standby IHP TLS termination.

```nix
{ config, lib, pkgs, inputs, ... }:
let
  mediamtxPkg = inputs.mediamtx.packages.${pkgs.system}.default;
in {
  # ----- MediaMTX --------------------------------------------------------
  systemd.services.mediamtx = {
    description = "MediaMTX media router";
    after    = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${mediamtxPkg}/bin/mediamtx /run/hnvr/mediamtx.yml";
      Restart = "on-failure";
      User = "hnvr";
      SupplementaryGroups = [ "hnvr" ];
      RuntimeDirectory = "hnvr";
    };
  };

  # ----- nginx reverse proxy (TLS termination) --------------------------
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    virtualHosts."nvr.example.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8000";
        proxyWebsockets = true;
      };
      locations."/whep/" = {
        proxyPass = "http://127.0.0.1:8889";
        proxyWebsockets = true;
        extraConfig = ''
          add_header Access-Control-Allow-Origin "*" always;
          client_max_body_size 0;
        '';
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 8889 ];
}
```

## Per-host files

### `hosts/hnvr-1.nix` (worker, GTX 1070)

```nix
{ config, lib, pkgs, ... }:
{
  imports = [ ./hnvr-1.hardware.nix ];

  networking.hostName = "hnvr-1";

  # Nvidia driver (Pascal supported by current driver)
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # CUDA for ONNX Runtime CUDA EP
  systemd.services.hnvr-node.environment.LD_LIBRARY_PATH =
    lib.makeLibraryPath [ pkgs.cudaPackages.cudatoolkit pkgs.cudaPackages.cudnn ];

  services.hnvr = {
    enable = true;
    role = "worker";
    initialAdminEmail = "admin@example.com";
    # execProviders default = ["cuda" "cpu"] from role
  };
}
```

### `hosts/hnvr-2.nix` (leader, RTX 4090)

```nix
{ config, lib, pkgs, ... }:
{
  imports = [ ./hnvr-2.hardware.nix ];

  networking.hostName = "hnvr-2";

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open = false;   # Ada sm_89 supported by proprietary only as of 2026
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # CUDA + TensorRT for ONNX Runtime TRT EP on RTX 4090
  systemd.services.hnvr-node.environment.LD_LIBRARY_PATH =
    lib.makeLibraryPath [
      pkgs.cudaPackages.cudatoolkit
      pkgs.cudaPackages.cudnn
      pkgs.tensorrt
    ];

  systemd.services.hnvr-leader.environment.LD_LIBRARY_PATH =
    config.systemd.services.hnvr-node.environment.LD_LIBRARY_PATH;

  services.hnvr = {
    enable = true;
    role = "leader";
    initialAdminEmail = "admin@example.com";
    # execProviders default = ["tensorrt" "cuda" "cpu"] from role
  };
}
```

## Secrets (`secrets/secrets.yaml`, sops-encrypted)

```yaml
hnvr-data-key: <base64 32 bytes>
hnvr-db-url: "postgres://hnvr:XXXX@pg.example.internal:5432/hnvr?sslmode=require"
hnvr-s3-access-key: "..."
hnvr-s3-secret-key: "..."
hnvr-nats-creds: |
  -----BEGIN NATS USER JWT-----
  ...
  -----END NATS USER JWT-----
initial-admin-pw: "..."
```

Per-host `.sops.yaml` selects the right age/PGP key. At activation, sops-nix decrypts to `/run/secrets/<name>`, mode `0400`, owned by `hnvr`.

The `hnvr-data-key` is the AES-256-GCM key for `password_enc` columns. **Losing it means losing all camera passwords.** Back it up offline.

## Models (`nix/models.nix`)

```nix
{ fetchurl }:
{
  yolov8n-320 = fetchurl {
    url    = "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.onnx";
    sha256 = "<sha256-of-converted-onnx-320>";
  };
  yolov8s-640 = fetchurl {
    url    = "https://...";
    sha256 = "...";
  };

  # Pre-built TensorRT engines for Ada (sm_89)
  yolov8n-320-sm_89 = fetchurl {
    url    = "https://internal-release/hnvr/yolov8n-320.sm_89.engine";
    sha256 = "...";
  };
}
```

Engine files are built offline via `trtexec` in a CI job against the same TensorRT version we ship, then uploaded to an internal release. Per-GPU-arch engines because TensorRT plans are not portable across sm versions.

## Log locations

| Path | Source |
|------|--------|
| `journalctl -u hnvr-node`        | hnvr-node service |
| `journalctl -u hnvr-leader`      | hnvr-leader service (leader host only) |
| `journalctl -u mediamtx`         | MediaMTX |
| `journalctl -u nats`             | NATS server |
| `/var/log/hnvr/<worker>.log`     | Per-worker `fast-logger` files |
| External                         | Postgres + SeaweedFS logs (SaaS) |
| `/var/log/nginx/access.log`      | Frontend HTTP (leader) |

All local logs rotated via logrotate.

## First-boot bootstrap

1. `nixos-rebuild boot --flake .#hnvr-2 && reboot` (leader first).
2. systemd starts nats → hnvr-node → hnvr-leader → mediamtx → nginx in order.
3. `hnvr-leader` runs IHP migrations against external Postgres.
4. Checks `users` table; if empty, reads `INITIAL_ADMIN_EMAIL` + `initial-admin-password`, creates admin user.
5. Admin logs in at `https://nvr.example.com`, forced password change.
6. Adds cameras; AssignmentCoordinator assigns to whichever host is healthy, broadcasts via NATS.
7. `nixos-rebuild boot --flake .#hnvr-1 && reboot` brings up the worker.

## Upgrades

- `nix flake update` → review diff → `nixos-rebuild test` → smoke check → `nixos-rebuild switch`.
- IHP migrations run on `hnvr-leader` start; for risky ones, stop leader, run migration manually, restart.
- GHC 9.12 jailbreaks may need adjustment when bumping nixpkgs.
- Rollbacks: `nixos-rebuild switch --rollback`. Postgres migrations are forward-only by design; partition-based archive for `events`/`segments` is the rollback strategy.

## Health checks

`hnvr-leader` exposes:

- `GET /healthz` → 200 if Postgres reachable + NATS reachable + at least one capture worker running anywhere.
- `GET /readyz` → 200 only after IHP migrations complete and leader lease acquired.
- `GET /metrics`  → Prometheus.

`hnvr-node` exposes:

- `:9100/metrics` per-host EKG.

NixOS `systemd.services.hnvr-*.unitConfig.StartLimitIntervalSec` + `RestartSec` keep the services honest.

## Resource planning

### hnvr-1 (GTX 1070, ~10 cameras)

| Component | CPU | RAM | VRAM |
|-----------|-----|-----|------|
| Capture (10 × record main + analysis sub ffmpeg) | 1 core | 2 GB | – |
| ONNX inference (CUDA EP, YOLOv8n) | 2 cores | 2 GB | 0.3 GB |
| NATS + node exporter | <0.5 core | 0.5 GB | – |
| **Total** | **~4 cores** | **~5 GB** | **0.3 GB** |

Sub-stream analysis cuts capture CPU roughly in half vs the main-stream-decode design (was ~5 cores → now ~4).

### hnvr-2 (RTX 4090, ~10 cameras + leader)

| Component | CPU | RAM | VRAM |
|-----------|-----|-----|------|
| Capture (10 × record main + analysis sub ffmpeg) | 1 core | 2 GB | – |
| ONNX inference (TRT EP, YOLOv8n) | 1 core | 2 GB | 0.8 GB |
| IHP web (leader) + MediaMTX + nginx | 2 cores | 1.5 GB | – |
| NATS + JetStream + node exporter | 0.5 core | 2 GB | – |
| **Total** | **~5 cores** | **~8 GB** | **0.8 GB** |

Both hosts comfortable. Sub-stream use frees enough headroom on hnvr-2 that we could:
- Add another 5–8 cameras per host without GPU pressure
- Bump hnvr-2 cameras to YOLOv8s-640 (better accuracy, ~3 ms/frame on TRT)
- Run the standby web node on hnvr-1 alongside its worker role (post-v1)

## Standby web node (post-v1)

Plumbing is in place: JetStream KV lease on `hnvr.leader` subject, standby mode in the binary. To enable:

1. Set `services.hnvr.role = "standby"` on hnvr-1.
2. Run `hnvr-leader --standby` binary mode: starts IHP webserver but doesn't acquire leader lease; watches `hnvr.leader` KV.
3. If lease expires, standby writes its own lease, becomes leader, starts EventWriter / MediaMTXConfigSyncer / etc.

MediaMTX on hnvr-1 (currently worker-only) needs to start on standby promotion — wire via systemd `ExecStartPre` check.

## Multi-host evolution (post-v1.1)

Capture nodes scaling out:

- Capture-only binaries can run on cheap low-power hosts near cameras.
- Frame-analyzer stays co-located with capture (frames never over the wire).
- Leader can be pinned to whichever host has the beefiest GPU.
- NATS cluster of 3+ nodes for bus HA.
- SeaweedFS and Postgres already external — transparent to us.

The per-worker isolation already in v1 makes the split mechanical, not architectural.
