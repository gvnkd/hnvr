# HNVR — Project Memories

> Read this file FIRST before any work on this project. It's the fast-onboarding
> context for new sessions. Update it whenever you make non-trivial changes.

## Identity

- **Name**: HNVR — Haskell Network Video Recorder
- **Owner**: Sergey (`omgbebebe@gmail.com`)
- **Local path**: `/home/pion/work/dev/hnvr`
- **Remote**: `gitea@192.168.0.254:omg/hnvr.git` (branch `master`)
- **Current branch state**: 2 commits (docs + scaffold) + Phase 0 work
  uncommitted in working tree. Phase 0 demo verified Aug 8 2026.
  - `e08a1f7` docs: add initial HNVR design documentation
  - `ef3c743` scaffold: cabal multi-package project + flake.nix

## What this is

NVR for 6–20 RTSP cameras. Records 24/7 to SeaweedFS (S3 SaaS), runs YOLOv8n
detection via ONNX Runtime on the sub-stream, fires line-crossing/zone-intrusion
events, exposes an IHP web UI for live view (MediaMTX WebRTC), archive playback
(fMP4 HLS), events, and config. Two Nvidia hosts: hnvr-1 (GTX 1070, worker),
hnvr-2 (RTX 4090, leader). NATS JetStream as IPC spine. Manual ONVIF PTZ in v1;
auto-track via PID closed loop in v1.1.

**Full design**: `design_docs/00-overview.md` through `08-roadmap.md`. Read
`00-overview.md` for the locked decisions table and `08-roadmap.md` for the
phased plan. This file is the cheat-sheet; the design docs are authoritative.

## Locked tech stack

| | |
|---|---|
| Language | Haskell, **GHC 9.12.3** (nixpkgs `haskell.packages.ghc912`, IHP overlay applied) |
| Web | **IHP HEAD pinned at `7de9e44`** (Aug 7 2026) — wired via flake input |
| Build | cabal multi-package + Nix flake |
| IPC | **NATS + JetStream** via @nats-queue@ (2017-era lib, patched for `network` >= 3.x; JetStream **deferred**) |
| Capture | ffmpeg subprocess (record `-c:v copy` main; analysis decode sub) |
| CV | ONNX Runtime via **internal ~150 LOC FFI binding** (not hs-onnxruntime-capi) |
| Models | YOLOv8n-320 ONNX, optional YOLOv8s-640 on RTX 4090 |
| Tracker | SORT in pure Haskell (~250 LOC) |
| Storage | **SeaweedFS** (S3 SaaS) + **PostgreSQL 18** (SaaS) — OUT of project scope |
| Live view | **MediaMTX v1.20.0** sidecar (RTSP → WebRTC WHEP), leader host only |
| Secrets | sops-nix |
| Deploy | NixOS flake, 2 hosts (`hnvr-1-vm`, `hnvr-2-vm` wired) |

## Verified commands (Aug 8 2026)

```bash
# Build everything (IHP overlay applied; first build is ~30 min, then cached)
nix build .#hnvr-web

# Enter dev shell (ormolu, hlint, cabal, ffmpeg, onnxruntime, nats-server)
nix develop

# Cabal-side build (faster iteration inside nix develop)
cabal build all

# Run the stub binaries
./result/bin/hnvr-leader  # IHP app; serves /healthz on :8000
./result/bin/hnvr-node    # Stub

# Build & boot a NixOS VM (leader)
nix build .#nixosConfigurations.hnvr-2-vm.config.system.build.vm
QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:18000-:8000" ./result/bin/run-nixos-vm
curl http://localhost:18000/healthz  # → ok, HTTP 200

# Worker VM
nix build .#nixosConfigurations.hnvr-1-vm.config.system.build.vm

# Formatter
nix fmt            # nixpkgs-fmt on .nix files

# Pre-commit checks (ormolu, hlint, nixpkgs-fmt)
nix flake check
```

## Repo layout

```
hnvr/
├── design_docs/         9 files, ~3000 lines, authoritative design
├── .github/workflows/   ci.yml (nix flake check + cabal build all)
├── cabal.project        packages + allow-newer for GHC 9.12
├── flake.nix            ihp overlay + hnvrHaskellOverlay + nixosConfigurations
├── flake.lock           pinned nixpkgs + flake-utils + pre-commit-hooks + ihp
├── nix/
│   ├── module.nix       NixOS module: hnvr-leader service
│   └── nats-server.nix  NixOS module: NATS + JetStream
├── hnvr-core/           REAL types: Id, Geometry, Logging, Prelude
├── hnvr-nats/           REAL Bus (nats-queue wrapper) + Subjects
├── hnvr-storage/        S3 client (stub)
├── hnvr-capture/        Ffmpeg, Fmp4, Worker (all stubs)
├── hnvr-cv/             OnnxRuntime, Preprocess, Decode, Rules, AutoTrack,
│                        Tracker/Sort (all stubs)
├── hnvr-ptz/            Driver (REAL typeclass), Onvif (stub), Controller (stub)
└── hnvr-web/            Library + 2 executables (LeaderMain, NodeMain)
                         ├── src/Hnvr/Web/Config.hs         IHP FrameworkConfig + healthz
                         └── src/Hnvr/Web/FrontController.hs RootApplication instances
```

## External services (SaaS — Sergey operates, not us)

| Service | Purpose | Where creds live |
|---------|---------|------------------|
| SeaweedFS | S3 API for fMP4 segments + thumbnails + exports | env `HNVR_S3_*` (sops-nix) |
| PostgreSQL 18 | Config, events, segments index, audit | env `HNVR_DB_URL` (sops-nix) |

We own: schema migrations (`hnvr-web/Application/Schema.sql` — TBD), backups
coordination. We do NOT own: PG ops, SeaweedFS ops, replication, vacuum.

## Sergey's cameras (test fixtures)

| IP | Codec | Res | FPS | Stream URL scheme |
|----|-------|-----|-----|-------------------|
| 192.168.0.196 | HEVC | 4000×3000 | 15 | `stream=MainStream` (try `stream=SubStream`) |
| 192.168.0.197 | H.264 | 3840×2160 | 15 | `stream=MainStream` |
| 192.168.0.198 | HEVC | 3072×2048 | 25 | `stream=0` (try `stream=1`) |
| All | RTSP TCP | | | Credentials: `admin` per camera |

**Verify before Phase 1**: probe sub-streams + ONVIF PTZ with ffprobe.

## Sergey's hardware

| Host | GPU | Role |
|------|-----|-----|
| hnvr-1 | GTX 1070 (Pascal sm_61) | Worker — CUDA EP only, no TensorRT |
| hnvr-2 (this dev box) | RTX 4090 (Ada sm_89) | Leader — TensorRT EP + IHP + MediaMTX + NATS |

## Known pitfalls (do NOT re-discover these)

1. **GHC 9.12 jailbreaks** — instead of maintaining our own jailbreak list,
   we apply IHP's overlay (`ihp.overlays.default`) which already pins
   hasql to 1.10.3.7, jailbreaks hasql-interpolate, disables flaky tests
   (say, text-icu, cryptonite). Our packages layer on top of
   `pkgs.ghc912` exposed by that overlay.

2. **nats-queue is from 2017** — uses `Network.Socket.sClose` which was
   renamed to `close` in `network >= 3.x`. We patch the call site in
   `flake.nix` via `substituteInPlace`. Its test suite also pulls in
   `cabal-test-quickcheck` (broken + base <4.14), so jailbreak + skip
   tests. No TLS, no JetStream. JetStream lands via subprocess or
   upstream fork in a later phase.

3. **DerivingStrategies required** — any file using `deriving stock` /
   `deriving newtype` syntax needs `{-# LANGUAGE DerivingStrategies #-}`.

4. **`show Text` produces `"foo"` with quotes** — use `T.unpack` then `putStrLn`.

5. **ByteString JSON instances have constraint issues via newtype deriving** —
   for `Sha256` we dropped ToJSON/FromJSON for now. Re-add via hex encoding when
   the segment publisher is wired in Phase 1.

6. **IHP needs a Postgres at boot** — `withModelContext` is called by
   `IHP.Server.run` before serving HTTP. For the leader VM we run a local
   postgresql service. The SaaS Postgres plugs in via `DATABASE_URL`.
   /healthz works even when the DB is unreachable (our `CustomMiddleware`
   in `Hnvr.Web.Config` short-circuits before IHP's request flow).

7. **IHP disables library profiling** — `disableLibraryProfiling` is
   applied to all our packages in `flake.nix`'s `hnvrHaskellOverlay`.
   Without it, building our packages with profiling fails because IHP
   doesn't ship profiling libs (matches IHP's own `fastBuild`).

8. **Explicit class imports need `(..)`** — `import M (ClassName)` brings
   only the name; methods require `import M (ClassName (..))`.

9. **`OverloadedStrings` + `length` ambiguity** — don't write
   `length "nats://"`; the literal is `IsString a => a` and `length`
   can't pick a type. Use an explicit `String` binding or hardcode the
   numeric length.

10. **flakes require git-tracked files** — must `git add` new files
    before `nix build` will see them. "Git tree is dirty" warning is
    normal.

11. **Two RTSP sessions per camera** (record + analyze). Watch per-camera
    concurrent session cap (~4 on consumer IPCs) during host failover.

12. **`IHP.Prelude` is ClassyPrelude-like** — modules using it should
    `{-# LANGUAGE NoImplicitPrelude #-}` to avoid double-import warnings.

13. **Port 8000 may be occupied on Sergey's dev box** — Taiga runs there.
    Use `PORT=8002` or similar when running hnvr-leader outside a VM.

## Sergey's working style

- Direct, no hand-holding. Be concise.
- Prefers GHC 9.12 + IHP even though bleeding edge — accept the jailbreak cost.
- Uses `~/bin/env-wrap` for commands requiring project flake.nix/.envrc.
- Calls himself "Sergey" — never "user".
- Wants to design for horizontal scale even when v1 doesn't need it (hence
  NATS from day one).

## Roadmap status (Aug 8 2026)

- [x] Design docs complete
- [x] Cabal scaffold + flake.nix
- [x] **Phase 0** — Bootstrap (IHP HEAD wired, NATS client picked, healthz action, NixOS VMs build, demo verified)
- [ ] Phase 1 — Recording MVP
- [ ] Phase 2 — Live view + multi-host
- [ ] Phase 3 — CV detection + tracking
- [ ] Phase 4 — Events (line crossing + zone)  ← v1.0 release candidate
- [ ] Phase 5 — PTZ manual + presets          ← v1.0 release
- [ ] Phase 6 — Operational hardening
- [ ] Phase 7 — Auto-track milestone           ← v1.1
- [ ] Phase 8 — Polish

Phase 0 follow-ups (not blockers for Phase 1):
- Wire NATS into hnvr-leader so it actually connects at boot (Bus.connect
  is implemented but unused; plug into the leader startup).
- Wire NATS into hnvr-node so the worker is a real NATS client.
- Replace local Postgres in leader VM with the SaaS one when ready.
- Decide JetStream path (vendoring vs `nats` CLI subprocess).

See `design_docs/08-roadmap.md` for the full plan with demos and decision points.

## Next session quick-start

1. `cd /home/pion/work/dev/hnvr`
2. Read this file.
3. Skim `design_docs/00-overview.md` for the decisions table.
4. Check `git log --oneline` for what's new since last session.
5. `nix develop` to enter dev shell.
6. **Phase 1 kickoff**: probe Sergey's cameras' sub-streams with ffprobe;
   then start `Hnvr.Capture.Ffmpeg` real impl + `CaptureWorker` state
   machine. The hnvr-nats `Bus` module is ready for use as-is.
