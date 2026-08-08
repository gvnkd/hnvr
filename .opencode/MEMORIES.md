# HNVR — Project Memories

> Read this file FIRST before any work on this project. It's the fast-onboarding
> context for new sessions. Update it whenever you make non-trivial changes.

## Identity

- **Name**: HNVR — Haskell Network Video Recorder
- **Owner**: Sergey (`omgbebebe@gmail.com`)
- **Local path**: `/home/pion/work/dev/hnvr`
- **Remote**: `gitea@192.168.0.254:omg/hnvr.git` (branch `master`)
- **Current branch state**: 4 commits. Phase 0 done + follow-ups.
  - `e08a1f7` docs: add initial HNVR design documentation
  - `ef3c743` scaffold: cabal multi-package project + flake.nix
  - `ece9519` phase 0: bootstrap IHP web + NATS bus + NixOS VMs
  - `3c45c46` phase 0 follow-ups: NATS wiring, cabal patches, worker VM broker

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
# Build everything (IHP overlay applied; first build ~30 min, then cached)
nix build .#hnvr-web

# Enter dev shell (ormolu, hlint, cabal, ffmpeg, onnxruntime, nats-server)
nix develop

# Cabal-side build of our own packages (NOT hnvr-web — see pitfalls #14):
cabal build hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv hnvr-ptz

# Run the binaries
HNVR_NATS_URI="nats://nats:nats@localhost:4222" PORT=18001 \
  ./result/bin/hnvr-leader  # IHP app + NATS connect; /healthz on PORT
HNVR_NATS_URI="nats://nats:nats@localhost:4222" \
  ./result/bin/hnvr-node    # Connects to NATS, subscribes hnvr.commands.>

# Build & boot a NixOS VM (leader). QEMU hostfwd uses COMMA separator
# for multiple ports — space-separated is silently dropped.
nix build .#nixosConfigurations.hnvr-2-vm.config.system.build.vm
NIX_DISK_IMAGE=/tmp/leader.qcow2 \
  QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:18000-:8000,hostfwd=tcp:127.0.0.1:18222-:8222" \
  ./result/bin/run-nixos-vm
curl http://localhost:18000/healthz  # → ok, HTTP 200

# Worker VM (now also runs NATS broker so node has a local peer)
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
├── .github/workflows/   ci.yml (nix flake check + nix build .#hnvr-web,
│                                       .#hnvr-nats; no cabal build — see #14)
├── cabal.project        packages + allow-newer + vendored/nats-queue
├── flake.nix            ihp overlay + hnvrHaskellOverlay + nixosConfigurations
├── flake.lock           pinned nixpkgs + flake-utils + pre-commit-hooks + ihp
├── nix/
│   ├── module.nix       NixOS module: hnvr-leader service
│   └── nats-server.nix  NixOS module: NATS + JetStream
├── vendored/
│   └── nats-queue/      2017 lib + sClose → close patch baked in
├── hnvr-core/           REAL types: Id, Geometry, Logging, Prelude
├── hnvr-nats/           REAL Bus (nats-queue wrapper) + Subjects
├── hnvr-storage/        S3 client (stub)
├── hnvr-capture/        Ffmpeg, Fmp4, Worker (all stubs)
├── hnvr-cv/             OnnxRuntime, Preprocess, Decode, Rules, AutoTrack,
│                        Tracker/Sort (all stubs)
├── hnvr-ptz/            Driver (REAL typeclass), Onvif (stub), Controller (stub)
└── hnvr-web/            Library + 2 executables (LeaderMain, NodeMain)
                         ├── src/Hnvr/Web.hs                 version stub
                         ├── src/Hnvr/Web/Config.hs          IHP config + healthz + NATS init
                         ├── src/Hnvr/Web/FrontController.hs RootApplication instances
                         ├── app/LeaderMain.hs               IHP.Server.run + NATS via addInitializer
                         └── app/NodeMain.hs                 withBus + subscribe hnvr.commands.>
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
   renamed to `close` in `network >= 3.x`. Patched in TWO places:
   `flake.nix` (overrideAttrs + substituteInPlace, for `nix build`)
   and `vendored/nats-queue/Network/Nats.hs` (for `cabal build`).
   Its test suite pulls in `cabal-test-quickcheck` (broken + base <4.14),
   so jailbreak + skip tests on the chain. No TLS, no JetStream.

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

14. **`cabal build` of hnvr-web is unsupported** — IHP's transitive deps
    (mime-mail-ses → memory/crypton) need version pins that IHP's nix
    overlay applies but cabal doesn't see. Use `nix build .#hnvr-web`
    for the canonical build. Cabal works for the 6 non-IHP packages
    (core, nats, storage, capture, cv, ptz) for fast iteration.

15. **Cabal 3.16 `source-repository-package --patch-dir` is unreliable** —
    silently skips patches. Vendor patched source in-tree instead
    (`vendored/nats-queue/`).

16. **Nix 2.34 + recent nixpkgs `postgresql` family** — uses `<|` pipe-operator
    syntax which needs `experimental-features = nix-command flakes pipe-operators`
    in `~/.config/nix/nix.conf`. Already set on Sergey's box.

17. **`pg_config` must be on PATH for `cabal build`** — postgresql-libpq-configure
    (transitive via IHP) calls it. We install it via
    `nix profile install nixpkgs#postgresql_18.pg_config` (user profile).

18. **`addInitializer` runs in a linked `async`** — exceptions propagate
    to the main thread. Wrap any fallible IO in `E.catch` or your leader
    dies on every initializer hiccup. See `Hnvr.Web.Config.connectNats`.

19. **Qualified-import syntax** — `import M qualified as X` needs
    `ImportQualifiedPost`. Use the prefix form `import qualified M as X`
    (portable, no extension).

20. **`?context :: T` implicit-param syntax** requires
    `{-# LANGUAGE ImplicitParams #-}` in the file.

21. **Type signatures in lambda patterns** (`\(e :: SomeException) -> ...`)
    require `{-# LANGUAGE ScopedTypeVariables #-}`.

22. **`catch` is ambiguous** — IHP.Prelude re-exports `catch` from
    safe-exceptions; Control.Exception also exports one. Use
    `import qualified Control.Exception as E` and `E.catch`.

23. **QEMU hostfwd multiple ports** — use COMMA separator, not space.
    `hostfwd=...,hostfwd=...` works; space-separated silently drops the
    second forward.

24. **IHP's `addInitializer` callback type** is
    `(?context :: FrameworkConfig, ?modelContext :: ModelContext) => IO ()`
    — `ModelContext` is a specific type, not polymorphic.

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
- [x] **Phase 0** — Bootstrap done. IHP wired, NATS bus implemented and
      connected at leader + node boot, `/healthz` returns 200, both NixOS
      VMs build and start their services, CI green for `nix build`.
- [ ] Phase 1 — Recording MVP
- [ ] Phase 2 — Live view + multi-host
- [ ] Phase 3 — CV detection + tracking
- [ ] Phase 4 — Events (line crossing + zone)  ← v1.0 release candidate
- [ ] Phase 5 — PTZ manual + presets          ← v1.0 release
- [ ] Phase 6 — Operational hardening
- [ ] Phase 7 — Auto-track milestone           ← v1.1
- [ ] Phase 8 — Polish

Phase 1 kickoff notes:
- Camera sub-streams (`stream=SubStream`, `stream=1`) need ffprobe
  verification before CaptureWorker real impl.
- The leader's NATS connection is best-effort (won't crash IHP on
  failure); when wiring EventWriter in Phase 1, store the Bus in an
  MVar so it's accessible to publish sites.
- Replace local Postgres in leader VM with the SaaS one when ready.
- Decide JetStream path (vendoring vs `nats` CLI subprocess).
- NATS HTTP monitor (`/connz`) on QEMU hostfwd returns TCP RST when
  probing from outside the VM (auth handshake quirk); binary-level
  connectivity test passes. Investigate before relying on monitor in
  multi-host tests.

See `design_docs/08-roadmap.md` for the full plan with demos and decision points.

## Next session quick-start

1. `cd /home/pion/work/dev/hnvr`
2. Read this file.
3. Skim `design_docs/00-overview.md` for the decisions table.
4. Check `git log --oneline` for what's new since last session.
5. `nix develop` to enter dev shell.
6. **Phase 1 kickoff**: probe Sergey's cameras' sub-streams with ffprobe;
   then start `Hnvr.Capture.Ffmpeg` real impl + `CaptureWorker` state
   machine. The hnvr-nats `Bus` module is wired but its handle isn't
   shared yet — thread it through an MVar when Phase 1 starts publishing
   on `hnvr.events`.
