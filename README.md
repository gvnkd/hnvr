# HNVR — Haskell Network Video Recorder

NVR for 6–20 RTSP cameras. Records 24/7 to SeaweedFS (S3), runs YOLOv8n
detection via ONNX Runtime on the sub-stream, fires line-crossing /
zone-intrusion events, exposes an IHP web UI for live view (MediaMTX
WebRTC), archive playback (fMP4 HLS), events, and config. Two Nvidia
hosts (leader + worker) communicate over NATS JetStream.

| | |
|---|---|
| Language | Haskell, **GHC 9.12.3** (`haskell.packages.ghc912` + IHP overlay) |
| Web | **IHP v1.6.0** (pinned flake input) |
| Build | cabal multi-package + Nix flake |
| IPC | **NATS + JetStream** via vendored `nats-queue` (patched for `network` >= 3.x) |
| Capture | ffmpeg subprocess (record `-c:v copy` main; analysis decode sub) |
| CV | ONNX Runtime via internal ~150 LOC FFI binding |
| Models | YOLOv8n-320 ONNX, optional YOLOv8s-640 on RTX 4090 |
| Tracker | SORT in pure Haskell (~250 LOC) |
| Storage | **SeaweedFS** (S3) + **PostgreSQL 18** — SaaS, out of scope |
| Live view | **MediaMTX v1.20.0** sidecar (RTSP → WebRTC WHEP), leader only |
| Secrets | sops-nix |
| Deploy | NixOS flake, 2 hosts (`hnvr-1-vm`, `hnvr-2-vm`) |

Authoritative design lives in [`design_docs/`](./design_docs/):
[`00-overview.md`](./design_docs/00-overview.md) holds the locked
decisions table; [`08-roadmap.md`](./design_docs/08-roadmap.md) holds
the phased plan.

## Repository layout

```
hnvr/
├── design_docs/         9 files, authoritative design (00-overview … 08-roadmap)
├── cabal.project        packages + allow-newer + vendored/nats-queue
├── flake.nix            ihp overlay + hnvrHaskellOverlay + nixosConfigurations
├── flake.lock           pinned nixpkgs + flake-utils + pre-commit-hooks + ihp
├── nix/
│   ├── module.nix       NixOS module: hnvr-leader service
│   ├── nats-server.nix  NixOS module: NATS + JetStream
│   ├── mediamtx.nix     NixOS module: MediaMTX sidecar (leader only)
│   └── secrets-template.yaml   sops-nix template (HNVR_DATA_KEY + S3 + DB)
├── vendored/nats-queue/ 2017 lib + sClose → close patch baked in
├── hnvr-core/           Id, Geometry, Logging, Prelude, Time, Segment, Crypto
├── hnvr-nats/           Bus (nats-queue wrapper) + Subjects
├── hnvr-storage/        S3 wrapper (minio-hs) + hnvr-s3-upload binary
├── hnvr-capture/        Fmp4, Ffmpeg, Worker state machine;
│                        exes: hnvr-record-frames, hnvr-s3-upload, hnvr-capture-loop
├── hnvr-cv/             OnnxRuntime, Preprocess, Decode, Rules, AutoTrack,
│                        Tracker/Sort (stubs)
├── hnvr-ptz/            Driver typeclass, Onvif + Controller (stubs)
└── hnvr-web/            Library + 2 executables (hnvr-leader, hnvr-node)
                         ├── Application/Schema.sql   IHP schema source of truth
                         ├── regen.sh                 regen+patch IHP codegen
                         ├── gen/Generated/...        IHP-generated types
                         └── src/Hnvr/Web/...         controllers + views
```

## Prerequisites

- **Nix 2.34+** with flakes + pipe-operators enabled:
  ```
  # ~/.config/nix/nix.conf
  experimental-features = nix-command flakes pipe-operators
  ```
- **Linux x86_64** (the only system the flake exposes).
- Optional but recommended: `direnv` + `nix-direnv` for automatic shell
  loading (`.envrc` is `use flake`).
- For `cabal build` of packages that transitively need `libpq`:
  `nix profile install nixpkgs#postgresql_18.pg_config` (user profile).

## Development environment

### Enter the dev shell

```bash
nix develop
```

Provides GHC 9.12, cabal, ghcid, hlint, ormolu, cabal-fmt, nixpkgs-fmt,
ffmpeg_7-full, onnxruntime, nats-server, curl, jq, direnv. Pre-commit
hooks (ormolu, hlint, nixpkgs-fmt, end-of-file-fixer,
trim-trailing-whitespace) are wired into the shell via
`pre-commit-hooks.nix`.

With direnv installed, the shell loads automatically on `cd` (`.envrc`
contains `use flake`).

### Build

```bash
# Canonical IHP build (applies the IHP nix overlay; first build ~30 min):
nix build .#hnvr-web

# Fast iteration on the 6 non-IHP packages (cabal works here):
cabal build hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv hnvr-ptz

# Phase 1 integration binaries:
cabal build hnvr-record-frames hnvr-s3-upload hnvr-capture-loop

# Locate a cabal binary:
BIN=$(find dist-newstyle -name 'hnvr-record-frames' -type f -executable | head -1)
```

> `cabal build hnvr-web` is **unsupported** — IHP's transitive deps
> (mime-mail-ses → memory/crypton) need version pins that only the nix
> overlay applies. Always use `nix build .#hnvr-web` for the web app.

### Lint and format

```bash
nix fmt                                  # nixpkgs-fmt on .nix files
nix build .#checks.x86_64-linux.pre-commit
```

`hnvr-web/gen/` and `vendored/` are excluded from all formatters and
pre-commit hooks (generated / vendored).

### Run unit binaries against Sergey's cameras

```bash
# Capture → local disk (fMP4 init.mp4 + fragments).
$BIN cam-197 tcp \
  'rtsp://admin:123456@192.168.0.197:554/h264PreviewCh01' /tmp/hnvr-out

# Capture → MinIO/SeaweedFS (start MinIO first; see "Local S3" below).
$S3BIN http://localhost:9100 minioadmin minioadmin hnvr-recordings \
  /tmp/hnvr-out/cam-197/init.mp4 cam-197/init.mp4

# Full vertical slice (ffmpeg → fMP4 → S3 → NATS publish, with backoff).
$LOOPBIN floor_2_5 tcp \
  'rtsp://192.168.0.197:554/user=admin&password=123456&channel=0&stream=MainStream' \
  --nats 'nats://n:n@localhost:4222' \
  --s3 http://localhost:9100 minioadmin minioadmin hnvr-recordings \
  --spool-dir /tmp/hnvr-spool \
  --host hnvr-2
```

Output layout: `/tmp/hnvr-out/<slug>/init.mp4` +
`/tmp/hnvr-out/<slug>/<YYYY-MM-DD>/<HH-MM-SS.MMM>.mp4` (millisecond
precision is required — HEVC cameras keyframe more than once per
second).

## Development VMs

Two NixOS VMs are defined in `flake.nix`:

| VM | Role | Modules |
|----|------|---------|
| `hnvr-2-vm` | Leader: IHP + NATS + MediaMTX + local Postgres | hnvr-nats, hnvr-mediamtx, hnvr (leader) |
| `hnvr-1-vm` | Worker: hnvr-node + local NATS (for Phase 0 demo) | hnvr-nats + systemd `hnvr-node` |

### Boot the leader VM

```bash
nix build .#nixosConfigurations.hnvr-2-vm.config.system.build.vm

NIX_DISK_IMAGE=/tmp/leader.qcow2 \
QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:18000-:8000,hostfwd=tcp:127.0.0.1:18222-:8222,hostfwd=tcp:127.0.0.1:18889-:8889,hostfwd=tcp:127.0.0.1:19997-:9997" \
  ./result/bin/run-nixos-vm
```

> QEMU `hostfwd` uses **comma** separator for multiple ports —
> space-separated is silently dropped.

### Boot the worker VM

```bash
nix build .#nixosConfigurations.hnvr-1-vm.config.system.build.vm
NIX_DISK_IMAGE=/tmp/worker.qcow2 ./result/bin/run-nixos-vm
```

## Accessing services

Default ports (host-side forwards via QEMU `hostfwd`, or direct when
running outside a VM):

| Service | In-VM port | Host-side (leader VM) | URL / path |
|---------|-----------|------------------------------------|
| IHP web (leader) | 8000 | 18000 | http://localhost:18000/ |
| IHP healthz | 8000 | 18000 | http://localhost:18000/healthz |
| Dashboard | 8000 | 18000 | http://localhost:18000/ |
| Hosts panel | 8000 | 18000 | http://localhost:18000/hosts |
| Live view | 8000 | 18000 | http://localhost:18000/live/<slug> |
| Archive player | 8000 | 18000 | http://localhost:18000/archive/... |
| WHEP proxy (WebRTC SDP) | 8000 | 18000 | http://localhost:18000/whep/<slug> |
| NATS monitor | 8222 | 18222 | http://localhost:18222/varz |
| MediaMTX WebRTC | 8889 | 18889 | (consumed by WHEP proxy) |
| MediaMTX REST config | 9997 | 19997 | http://localhost:19997/v2/config/paths |
| Postgres (leader VM) | 5432 | — | `postgresql:///hnvr?host=/run/postgresql` (trust auth, in-VM only) |

Smoke tests once the leader VM is up:

```bash
curl http://localhost:18000/healthz                 # → ok, HTTP 200
curl http://localhost:18000/                        # → dashboard (camera grid + hosts)
curl http://localhost:18000/hosts                   # → per-host status
curl http://localhost:19997/v2/config/paths         # → mediamtx live path config
curl -s http://localhost:18222/varz | jq '.in_msgs' # → increments ~1/s/camera
```

When running `hnvr-leader` outside a VM (e.g. on Sergey's dev box),
override `PORT` — 8000 is taken by Taiga:

```bash
HNVR_NATS_URI="nats://nats:nats@localhost:4222" PORT=8002 \
  ./result/bin/hnvr-leader
```

## Local S3 (MinIO) for testing

MinIO is `marked insecure` in nixpkgs; build it impurely:

```bash
nix build --impure --expr \
  '(import <nixpkgs> { config.permittedInsecurePackages = [ "minio-..." ]; }).minio'

MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
  minio server /tmp/minio-data --address :9100 &

mc alias set local http://localhost:9100 minioadmin minioadmin
mc mb local/hnvr-recordings
```

Production uses SeaweedFS (SaaS), not MinIO.

## Local NATS for testing

```bash
printf 'port: 4222\nhttp_port: 8222\nauthorization {\n  user: n\n  password: n\n}\n' \
  > /tmp/nats.conf
nats-server -c /tmp/nats.conf -m 8222 &
```

> `Hnvr.Nats.Bus.hostFromUri` requires `user:pass@host:port`. Bare
> `nats://localhost:4222` crashes — always include dummy creds.

## NixOS module options (`services.hnvr.leader`)

| Option | Default | Description |
|--------|---------|-------------|
| `enable` | `false` | Enable the leader service. |
| `package` | `pkgs.hnvr-web` | Derivation containing `bin/hnvr-leader`. |
| `port` | `8000` | IHP web port (also published as `PORT`). |
| `dataDir` | `/var/lib/hnvr` | IHP working dir (`static/`, session key). |
| `databaseUrl` | `postgresql:///hnvr?host=/run/postgresql` | Postgres DSN (sops-nix in real deploys). |
| `natsUri` | `nats://nats:nats@localhost:4222` | NATS URI. |
| `hostName` | `hnvr-2` | Published as `hnvr.health.<hostName>`. |
| `environment` | `{}` | Extra env vars (sops-nix secrets land here). |

Modules `services.hnvr.nats` and `services.hnvr.mediamtx` are leader-only
companions.

## CI

[`.github/workflows/ci.yml`](./.github/workflows/ci.yml) runs
`nix flake check` and `nix build .#hnvr-web .#hnvr-nats`. There is no
cabal-based CI — IHP's transitive version pins only exist in the nix
overlay.

## Status

Phases 0–2 are code-complete (live VM tests pending). See
[`design_docs/08-roadmap.md`](./design_docs/08-roadmap.md) for the full
plan. Phases 3–8 (CV, events, PTZ, hardening, auto-track, polish) are
unstarted.

## Conventions

- No comments unless requested.
- `Ormolu` for Haskell, `nixpkgs-fmt` for Nix. Both enforced via
  pre-commit.
- `IHP.Prelude` is ClassyPrelude-like — modules using it need
  `NoImplicitPrelude` to avoid double-import warnings.
- Secrets never committed; sops-nix template in
  [`nix/secrets-template.yaml`](./nix/secrets-template.yaml).
