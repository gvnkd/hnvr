# HNVR — Project Memories

> Read this file FIRST before any work on this project. It's the fast-onboarding
> context for new sessions. Update it whenever you make non-trivial changes.

## Identity

- **Name**: HNVR — Haskell Network Video Recorder
- **Owner**: Sergey (`omgbebebe@gmail.com`)
- **Local path**: `/home/pion/work/dev/hnvr`
- **Remote**: `gitea@192.168.0.254:omg/hnvr.git` (branch `master`)
- **Current branch state**: Phase 0 + 1 + 2 done (code; live VM tests
  pending). Phase 2 audit-and-fix pass landed Aug 10 2026 (see
  `.opencode/PHASE_AUDIT_REPORT.md` for the audit + ✅ badges on items
  that have been resolved; `.opencode/PHASE_AUDIT_REPORT_2.md` for the
  round-2 re-audit at `57aac3b`). Phase 1 slice 8 (Cameras admin gate)
  landed Aug 10 2026. Phase 2 commit history:
  - `e08a1f7` docs: add initial HNVR design documentation
  - `ef3c743` scaffold: cabal multi-package project + flake.nix
  - `ece9519` phase 0: bootstrap IHP web + NATS bus + NixOS VMs
  - `3c45c46` phase 0 follow-ups: NATS wiring, cabal patches, worker VM broker
  - `a7a4885` … `41cd4b1` phase 1 (recording MVP, slices 1–7b)
  - `59f383b` phase 2: live view + multi-host (slices 1–6)
  - `57aac3b` phase 2 audit-fix: close 8 spec/CI/tooling gaps
  - phase 1 slice 8 (Cameras admin gate — IHP AuthSupport, users table,
    SessionsController, ensureIsUser beforeAction) — Aug 10 2026

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
| Web | **IHP v1.6.0** (pinned via flake input `github:digitallyinduced/ihp/v1.6.0`) |
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

## Verified commands (Aug 10 2026 — devenv-integrated devShell)

```bash
# Build everything (IHP overlay applied; first build ~30 min, then cached)
nix build .#hnvr-web

# Enter dev shell — devenv-integrated (Postgres, MinIO, NATS, MediaMTX
# wired as services; all HNVR_* env vars pre-set). MUST pass --no-pure-eval
# (or use direnv — .envrc already passes it).
nix develop --no-pure-eval

# Start all four services in another terminal (process-compose TUI):
devenv up

# Run the leader / node against devenv-managed services (env vars already set):
./result/bin/hnvr-leader   # PORT=18001, NATS=4222, PG via $DATABASE_URL
./result/bin/hnvr-node

# Cabal-side build of our own packages (NOT hnvr-web — see pitfalls #14):
cabal build hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv hnvr-ptz

# Phase 1 capture pipeline integration binary (ffmpeg → Fmp4 → disk)
cabal build hnvr-record-frames
BIN=$(find dist-newstyle -name 'hnvr-record-frames' -type f -executable | head -1)
# Cam 197 (TCP), 196 (UDP!), 198 (TCP, XM firmware):
$BIN cam-197 tcp 'rtsp://admin:123456@192.168.0.197:554/h264PreviewCh01' /tmp/hnvr-out
$BIN cam-196 udp 'rtsp://admin:123456@192.168.0.196:554/h264PreviewCh01' /tmp/hnvr-out
$BIN cam-198 tcp 'rtsp://admin:io27pJ3wui@192.168.0.198:554/stream=0' /tmp/hnvr-out
# Output: /tmp/hnvr-out/<slug>/init.mp4 + /tmp/hnvr-out/<slug>/<YYYY-MM-DD>/<HH-MM-SS.MMM>.mp4
# Verify: cat init.mp4 frag.mp4 | ffprobe -   (fMP4 fragments need init segment)

# Phase 1 S3 wrapper integration binary (file → MinIO/SeaweedFS)
cabal build hnvr-s3-upload
S3BIN=$(find dist-newstyle -name 'hnvr-s3-upload' -type f -executable | head -1)
# Start MinIO locally (see pitfall #30 for the insecure-package bypass):
#   nix build --impure --expr '(import <nixpkgs> { ... }).minio'
#   MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin minio \
#     server /tmp/minio-data --address :9100 &
#   mc alias set local http://localhost:9100 minioadmin minioadmin
#   mc mb local/hnvr-recordings
$S3BIN http://localhost:9100 minioadmin minioadmin hnvr-recordings \
  /tmp/hnvr-out/cam-197/init.mp4 cam-197/init.mp4

# Phase 1 supervised capture worker (full vertical slice)
cabal build hnvr-capture-loop
LOOPBIN=$(find dist-newstyle -name 'hnvr-capture-loop' -type f -executable | head -1)
# Local MinIO + NATS needed (see above +:
#   printf 'port: 4222\nhttp_port: 8222\nauthorization {\n  user: n\n  password: n\n}\n' > /tmp/nats.conf
#   nats-server -c /tmp/nats.conf -m 8222 &)
$LOOPBIN floor_2_5 tcp 'rtsp://192.168.0.197:554/user=admin&password=123456&channel=0&stream=MainStream' \
  --nats 'nats://n:n@localhost:4222' \
  --s3 http://localhost:9100 minioadmin minioadmin hnvr-recordings \
  --spool-dir /tmp/hnvr-spool \
  --host hnvr-2
# Verify: mc ls --recursive local/hnvr-recordings/floor_2_5/
#         curl -s http://localhost:8222/varz | grep in_msgs (should increment ~1/s/cam)
# Test backoff: pass a broken rtsp_url; watch the [cam INFO] log show
#                "ffmpeg exit → Backoff #N for Xs" with X = 2,4,8,16,30,...

# Run the binaries
HNVR_NATS_URI="nats://nats:nats@localhost:4222" PORT=18001 \
  ./result/bin/hnvr-leader  # IHP app + NATS connect; /healthz on PORT
HNVR_NATS_URI="nats://nats:nats@localhost:4222" HNVR_HOST=hnvr-2 \
  ./result/bin/hnvr-node    # Connects to NATS, HealthReporter + ConfigWatcher

# Build & boot a NixOS VM (leader). QEMU hostfwd uses COMMA separator
# for multiple ports — space-separated is silently dropped.
# Phase 2 needs to forward WebRTC (8889), API (9997), mediamtx debug.
nix build .#nixosConfigurations.hnvr-2-vm.config.system.build.vm
NIX_DISK_IMAGE=/tmp/leader.qcow2 \
  QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:18000-:8000,hostfwd=tcp:127.0.0.1:18222-:8222,hostfwd=tcp:127.0.0.1:18889-:8889,hostfwd=tcp:127.0.0.1:19997-:9997" \
  ./result/bin/run-nixos-vm
curl http://localhost:18000/healthz        # → ok, HTTP 200
curl http://localhost:18000/               # → dashboard (cameras grid + hosts)
curl http://localhost:18000/hosts          # → per-host panel
curl http://localhost:19997/v2/config/paths # → mediamtx live config

# Worker VM (now also runs NATS broker so node has a local peer)
nix build .#nixosConfigurations.hnvr-1-vm.config.system.build.vm

# Formatter
nix fmt            # nixpkgs-fmt on .nix files

# Pre-commit checks (ormolu, hlint, nixpkgs-fmt)
nix build .#checks.x86_64-linux.pre-commit
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
├── nix/                (see "Repo layout — expanded nix/" block below)
├── vendored/
│   └── nats-queue/      2017 lib + sClose → close patch baked in
├── hnvr-core/           REAL types: Id, Geometry, Logging, Prelude, Time, Segment, Crypto
├── hnvr-nats/           REAL Bus (nats-queue wrapper) + Subjects
├── hnvr-storage/        REAL S3 wrapper (minio-hs, NOT amazonka — see pitfall #28)
│                        + hnvr-s3-upload integration binary
├── hnvr-capture/        Fmp4 (REAL), Ffmpeg (REAL), Worker (REAL state machine);
│                        exes: hnvr-record-frames (capture→disk),
│                              hnvr-s3-upload (file→S3),
│                              hnvr-capture-loop (full pipeline w/ NATS+S3+backoff)
├── hnvr-cv/             OnnxRuntime, Preprocess, Decode, Rules, AutoTrack,
│                        Tracker/Sort (all stubs)
├── hnvr-ptz/            Driver (REAL typeclass), Onvif (stub), Controller (stub)
├── hnvr-web/            Library + 2 executables (LeaderMain, NodeMain)
│                        ├── Application/Schema.sql   IHP schema source of truth
│                        ├── regen.sh                 regen+patch IHP codegen (see pitfall #32)
│                        ├── gen/Generated/...        IHP-generated types (committed)
│                        ├── src/Hnvr/Web.hs                 version stub
│                        ├── src/Hnvr/Web/Config.hs          IHP config + healthz + NATS init
│                        │                                  + EventWriter + HealthCache
│                        │                                  + AssignmentCoordinator
│                        │                                  + MediaMTXConfigSyncer + WHEP proxy
│                        ├── src/Hnvr/Web/FrontController.hs RootApplication + parseRoute for
│                        │                                  Cameras/Archive/Live/Dashboard/Hosts
│                        ├── src/Hnvr/Web/Controller/Cameras.hs      CRUD + Probe + Assign
│                        ├── src/Hnvr/Web/Controller/Cameras/Probe.hs ffprobe JSON parser
│                        ├── src/Hnvr/Web/Controller/Support/Crypto.hs encryptPassword / decryptPassword / requireKey
│                        ├── src/Hnvr/Web/Controller/Archive.hs       PlayerAction + m3u8 PlaylistAction
│                        ├── src/Hnvr/Web/Controller/Live.hs          /live/<slug> ShowAction
│                        ├── src/Hnvr/Web/Controller/Dashboard.hs     / camera grid + hosts panel
│                        ├── src/Hnvr/Web/Controller/Hosts.hs         /hosts per-host status
│                        ├── src/Hnvr/Web/EventWriter.hs              NATS hnvr.events → PG segments
│                        ├── src/Hnvr/Web/HealthCache.hs              NATS hnvr.health.> → IORef + PG
│                        ├── src/Hnvr/Web/AssignmentCoordinator.hs    5s poll, host-down → reassign
│                        ├── src/Hnvr/Web/MediaMTXConfigSyncer.hs     PG LISTEN → /run/hnvr/mediamtx.yml
│                        │                                          + PUT /v2/config/paths/<slug>
│                        ├── src/Hnvr/Web/WhepProxy.hs                WAI middleware: /whep/<slug> → mediamtx
│                        ├── src/Hnvr/Node/HealthReporter.hs          publishes hnvr.health.<host> every 5s
│                        ├── src/Hnvr/Node/ConfigWatcher.hs           subscribes hnvr.commands.assign.>
│                        ├── src/Hnvr/Web/View/Layout.hs             default HTML layout + nav
│                        ├── src/Hnvr/Web/View/Cameras/{Index,New,Edit,Show}.hs
│                        ├── src/Hnvr/Web/View/Archive/Player.hs      @\<video\>@ + hls.js
│                        ├── src/Hnvr/Web/View/Live/Show.hs           @\<video\>@ + inline whep.js
│                        ├── src/Hnvr/Web/View/Dashboard/Index.hs     camera grid + hosts table
│                        ├── src/Hnvr/Web/View/Hosts/Index.hs         per-host status + cameras
│                        ├── app/LeaderMain.hs        IHP.Server.run + all initializers
│                        └── app/NodeMain.hs          withBus + HealthReporter + ConfigWatcher
├── nix/
│   ├── module.nix       NixOS module: hnvr-leader service (HNVR_HOST env wired)
│   ├── nats-server.nix  NixOS module: NATS + JetStream
│   ├── mediamtx.nix     NixOS module: MediaMTX sidecar (leader only)
│   └── secrets-template.yaml  sops-nix template (HNVR_DATA_KEY + S3 + DB)
```

## External services (SaaS — Sergey operates, not us)

| Service | Purpose | Where creds live |
|---------|---------|------------------|
| SeaweedFS | S3 API for fMP4 segments + thumbnails + exports | env `HNVR_S3_*` (sops-nix) |
| PostgreSQL 18 | Config, events, segments index, audit | env `HNVR_DB_URL` (sops-nix) |

We own: schema migrations (`hnvr-web/Application/Schema.sql` — TBD), backups
coordination. We do NOT own: PG ops, SeaweedFS ops, replication, vacuum.

## Sergey's cameras (test fixtures — probed Aug 9 2026)

**Use Sergey's canonical URL form** (`user=admin&password=...&channel=0&stream=...`) —
it gives the true configured fps for every camera AND works over TCP for all
three (the alternative `h264PreviewCh01` URL on 196 is UDP-only and gives a
non-standard 25fps profile; the alternative `stream=0` on 198 gives 12fps
instead of 15 — both are probe artifacts of the wrong URL form).

| Slug | IP | User | Password | Main URL | Main codec/res/fps | Sub URL | Sub codec/res/fps |
|------|----|------|----------|----------|--------------------|---------|-------------------|
| low_ent | 192.168.0.198 | admin | `io27pJ3wui` | `rtsp://192.168.0.198:554/user=admin&password=io27pJ3wui&channel=0&stream=0` | HEVC 3072×2048 @15 | `...&stream=1` | HEVC 704×576 @5 (low for CV) |
| backyard | 192.168.0.196 | admin | `123456` | `rtsp://192.168.0.196:554/user=admin&password=123456&channel=0&stream=MainStream` | HEVC 4000×3000 @15 | `...&stream=SubStream` | HEVC 704×576 @5 |
| floor_2_5 | 192.168.0.197 | admin | `123456` | `rtsp://192.168.0.197:554/user=admin&password=123456&channel=0&stream=MainStream` | H.264 3840×2160 @15 | `...&stream=SubStream` | H.264 720×480 @15 |

All three work over `-rtsp_transport tcp`. Audio present on all three
(196: pcm_mulaw; 197: pcm_mulaw; 198: pcm_alaw). Phase 1 ignores audio.

**Vendor notes for later phases**:
- All three expose the H264DVR-style URL form above (`/user=&password=&channel=&stream=`),
  common to XM / icamra / generic Chinese OEM firmware.
- 196 + 197 also respond to ONVIF at `http://192.168.0.196/onvif/device_service`
  (gSOAP/2.8 server, Hikvision OEM namespaces) with WS-Security auth — useful
  for Phase 5 PTZ probe. 198 has no ONVIF.
- 198 also exposes XMeye NetSDK on port 34567 (proprietary — out of scope).
- Encoder fps is only configurable via each camera's web admin UI.

**Sub-stream fps is low on 196 + 198 (5fps)** — borderline for CV. The
design's fallback path (`use_substream_for_analysis=false` →
main-stream-with-scale, design_docs/03 §2b) covers this. Decide per-camera
at Phase 3 kickoff.

ffprobe notes:
- ffmpeg 7.x renamed `-stimeout` → `-timeout` (use `-timeout 5000000` for RTSP).
- The H264DVR URL form uses `&` separators inside the path; quote the whole
  URL when passing to shell or ffmpeg.

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

25. **HEVC cameras emit 2+ fMP4 fragments per wall-clock second** —
    ffmpeg's `-frag_duration 1000000` requests 1s but the
    `+frag_keyframe` flag splits at every keyframe, and HEVC cameras
    (cam-196 in particular) keyframe more often than once per second.
    Object keys MUST use millisecond precision
    (`formatSegmentObjectKeyMs`), otherwise later fragments in the same
    second overwrite earlier ones on disk and in S3.

26. **fMP4 fragments are NOT independently playable** — ffprobe on a
    single `moof+mdat` file errors with `trun track id unknown, no tfhd
    was found`. That's expected; the track config lives in the
    `ftyp+moov` init segment. Verify by concatenating `init.mp4` with
    one or more fragments before probing. The HLS player does this
    naturally.

27. **`Data.Fixed.Milli` is a TYPE alias, not a constructor** —
    `Milli = Fixed E3`. To pattern-match the underlying Integer, use
    `MkFixed` from `Data.Fixed`: `let ms = realToFrac dt; MkInteger n = ms`.

28. **`amazonka-s3 2.0` doesn't compile under GHC 9.12 via cabal** — its
    generated STS modules use `DuplicateRecordFields` patterns that fail
    without the extension enabled. IHP's nix overlay patches this for
    `nix build`, but cabal can't mirror it. **`Hnvr.Storage.S3` uses
    `minio-hs` instead** — purpose-built for S3-compatible storage with
    path-style by default. Same API surface (putObject/getObject/
    presignUrl/listObjects/removeObject), no AWS-SDK baggage. Design
    doc `02-tech-stack.md` still says amazonka; treat as superseded.

29. **socks-0.5.6 doesn't compile under GHC 9.12** (pre-MonadFail API).
    `cabal.project` has `constraints: socks >= 0.6.0` to force the
    fixed version. minio-hs's upper bound doesn't reflect this.

30. **MinIO is `marked insecure` in nixpkgs** — must build/bypass with
    `nix build --impure --expr '(import <nixpkgs> { config.permittedInsecurePackages = [ "minio-..." ]; }).minio'`.
    For local testing of the S3 wrapper. Production uses SeaweedFS SaaS.

31. **`Hnvr.Nats.Bus.hostFromUri` requires `user:pass@host:port`** — bare
    `nats://localhost:4222` produces an empty host and crashes the nats-queue
    connection with `Network.Socket.getAddrInfo ... does not exist`. Always
    include dummy creds in the URI when the server has no auth.

32. **IHP v1.6.0 codegen has a primary-key encoder bug** — Create*/Update*
    /Fetch* statements wrap PK in `Encoders.nullable Mapping.encoder`
    instead of `Encoders.nonNullable Mapping.encoder`. The build fails
    with `Couldn't match type Id' "<table>" with Maybe a0`. Workaround:
    run `hnvr-web/regen.sh` after every Schema.sql change — it patches
    the generated files. Upstream IHP PR TBD.

33. **IHP v1.6.0 generated types require many cabal default-extensions** —
    when wiring `gen/` into hs-source-dirs, the cabal library stanza
    needs `OverloadedStrings, OverloadedLabels, DuplicateRecordFields,
    DisambiguateRecordFields, OverloadedRecordDot, NoFieldSelectors,
    ImplicitParams` plus the IHP-standard set. See hnvr-web.cabal.

34. **`hasql-mapping` 0.1.0.2 needed for IHP v1.6.0 generated code** —
    nixpkgs pins 0.1.0.1 which lacks the `IsScalar.encoder` signature
    the codegen expects. The flake.nix `hnvrHaskellOverlay` overrides via
    `final.callHackageDirect` with the tarball hash. Bump hash if
    hasql-mapping re-releases.

35. **IHP HSX can't parse nested record patterns** — `pathTo FooAction { id = x }`
    inside an HSX expression hole fails with "parse error (possibly
    incorrect indentation or mismatched brackets)". Workaround: extract
    the path to a `let`/`where` binding and reference it as a single var.

36. **IHP `Html` type carries implicit-param constraint**
    `(?context :: RequestContext, ?request :: Request)` — so any function
    with `Html` in its signature needs the params in scope, which means
    either (a) no explicit signature (let GHC infer), or (b) RankNTypes.
    Easiest in views: omit signatures on local helpers.

37. **IHP controllers need `Data` + `AutoRoute` instances** —
    declaring `data CamerasController = IndexAction | ... ` is not enough;
    add `deriving stock (Eq, Show, Data)` (needs DeriveDataTypeable) plus
    `instance AutoRoute CamerasController` to get `parseRoute` dispatch.
    Route helpers like `redirectTo EditAction {..}` use the data
    constructor names directly (not `EditCameraAction`-style auto-aliases).

   38. **cabal `exposed-modules` MUST NOT have duplicate entries** — even
       comment lines between two listings of the same module produce a
       Cabal-5559 "duplicate-modules" error at configure time. Watch for
       stale list copies when refactoring.

   39. **IHP `Id' "table"` has no `ConvertibleStrings Text` instance** —
       `cs (h.id :: Id' "hosts") :: Text` fails with "Could not deduce
       ConvertibleStrings". Use `Data.Coerce.coerce h.id :: Text` (works
       because `Id'` is a `newtype` around `PrimaryKey table`). The
       pattern `case h.id of Id t -> t` also works but needs the
       constructor imported from `IHP.ModelSupport`.

   40. **IHP HSX can't parse lambda-piped `forEach`** — `forEach xs (\x ->
       [hsx|...|])` inside an HSX `[hsx|...|]` block triggers
       `parse error on input ')'`. Extract the inner HSX to a
       top-level helper (`renderLi x = [hsx|...|]`) and use
       `forEach xs renderLi`.

   41. **Hasql 1.9.x has no Notification module** — for LISTEN/NOTIFY,
       use `postgresql-simple` (already in IHP's transitive deps). Open
       a dedicated `PG.Connection` via `PG.connectPostgreSQL` outside
       IHP's Hasql pool (LISTEN must hold the connection idle to
       receive notifies). `PG.getNotification` blocks; wrap in
       `forever`.

   42. **`sqlExec` is deprecated in IHP v1.6.0** — emits
       `-Wdeprecations` warnings, still works. The recommended
       replacement is `[typedSql|...|]` + `sqlExecTyped` from
       `IHP.TypedSql`. We accept the warnings for now (DDL stays
       untyped; the typed quoter doesn't cover `CREATE FUNCTION` etc.).

   43. **IHP HSX `<video playsinline>` is rejected** — parser allows
       only a fixed attribute whitelist. Drop `playsinline` (Chrome
       plays inline anyway when the element is `autoplay muted`).

   44. **mediamtx REST config API** — `PUT /v2/config/paths/<id>` is
       upsert, `DELETE /v2/config/paths/<id>` removes. `GET /v2/config/paths`
       returns `{pathName: {...}, ...}` — top-level keys are path IDs.
       We use per-path ops, not the global PUT (which version-semantics
       vary across mediamtx releases).

   45. **mediamtx config SIGHUP needs polkit/systemctl; REST is simpler** —
       the leader runs as `hnvr` user, so does mediamtx. Same-user
       `kill(2)` would work if we exposed the PID, but
       `systemctl kill -s HUP` needs polkit. We use the REST API for
       live reload and write `/run/hnvr/mediamtx.yml` as the source of
       truth at mediamtx boot.

   46. **NoFieldSelectors + record fields** — with `NoFieldSelectors`
        enabled, `recField rec` (function application style) doesn't
        compile. Use `rec.recField` (OverloadedRecordDot). The cabal
        default-extensions include both.

   47. **`nix build .#hnvr-web` requires new modules to be `git add`-ed
       BEFORE invoking nix** — `callCabal2nix` only sees files in the
       git tree (pitfall #10 generalised). Adding a new module to
       `exposed-modules` without `git add`-ing the .hs file fails with
       `can't find source for Hnvr/Web/<Mod>` at the cabal configure
       step. Pre-stage with `git add` before any `nix build` after a
       new-module commit.

   48. **cabal-fmt and ormolu are pre-commit hooks now** (Aug 10 2026
       audit-fix) — `.cabal` files use 2-space indent + leading-comma
       field lists; `.hs` files use ormolu's compact record/list style
       (e.g. `Record{ field = value }` not `Record { field = value }`).
       `cabal-fmt -i` and `ormolu -i` over the tree before commit if
       you've edited anything sizeable.

   49. **IHP v1.6.0 `AuthMiddleware` lives in `IHP.FrameworkConfig.Types`**
       (Aug 10 2026 slice 8) — NOT in `IHP.LoginSupport.Middleware`.
       The latter only exports the `authMiddleware`/`adminAuthMiddleware`
       functions. Import pattern:
       `import IHP.FrameworkConfig.Types (AuthMiddleware (..), FrameworkConfig)`
       + `import IHP.LoginSupport.Middleware (authMiddleware)`.

   50. **Type family instances must be explicitly imported** (Aug 10 2026
       slice 8) — `type instance CurrentUserRecord = User` declared in
       `Hnvr.Web.Auth` is invisible to GHC unless the consuming module
       imports that module (`import Hnvr.Web.Auth ()` is enough). Without
       the import, `authMiddleware @User` and `ensureIsUser` fail with
       "Couldn't match type CurrentUserRecord with User". Affects every
       module that touches `authMiddleware @User` / `ensureIsUser` /
       `currentUserOrNothing` — currently `Config.hs`, `Controller/Cameras.hs`,
       `View/Layout.hs`. Add the empty import wherever IHP auth is used.

   51. **`regen.sh` does NOT touch `hnvr-web.cabal`** (Aug 10 2026 slice 8) —
       when adding a new table to `Schema.sql`, after `./hnvr-web/regen.sh`
       you must hand-add the new `Generated.<Table>`,
       `Generated.<Table>Include`, `Generated.ActualTypes.<Table>`,
       `Generated.Statements.{Create,CreateMany,Fetch,Update,RowDecoder}<Table>`
       entries to `exposed-modules` in `hnvr-web.cabal`. Missing entries
       pass type-checking but fail at link with `undefined reference to
       Generatedzi<table>zi..._closure` errors.

   52. **IHP v1.6.0 auth — old `LoginSupport.User` class is GONE** (Aug 10
       2026 slice 8) — replaced by `class HasNewSessionUrl user` + open
       type family `CurrentUserRecord`, both in `IHP.LoginSupport.Types`.
       The whole user-side instance surface is:
       ```
       instance HasNewSessionUrl User where
         newSessionUrl _ = "/NewSession"
       type instance CurrentUserRecord = User
       ```
       No methods to implement beyond `newSessionUrl`. Sessions
       controller is `action NewSessionAction = Sessions.newSessionAction @User`
       + 2 more from `IHP.AuthSupport.Controller.Sessions`. `beforeAction`
       gate is `ensureIsUser` from `IHP.LoginSupport.Helper.Controller`.
       Routes are top-level: `/NewSession`, `/CreateSession`, `/DeleteSession`.

   53. **IHP v1.6.0 `ensureIsUser` is NOT in `IHP.ControllerPrelude`** (Aug 10
       2026 slice 8) — add explicit `import IHP.LoginSupport.Helper.Controller (ensureIsUser)`.
       `currentUserOrNothing` IS re-exported via `IHP.ViewPrelude` from
       `IHP.LoginSupport.Helper.View` — don't double-import in views.

   54. **`hashPassword`/`verifyPassword` come from `IHP.AuthSupport.Authentication`**
       (Aug 10 2026 slice 8) — uses `pwstore-fast` under the hood (sha256
       with 17 rounds, format `sha256|17|...`). Re-exported by
       `IHP.ControllerPrelude` for controller contexts but in
       initializers (`Config.hs`) you need the explicit import. Returns
       `IO Text`. No `bcrypt-hs` dependency needed; it's all transitive
       via `ihp`.

   55. **devenv flake integration** (Aug 10 2026) — `devShells.default`
       is now `devenv.lib.mkShell` (NOT `pkgs.mkShell`). Things to know:
       - **`nix develop` MUST pass `--no-pure-eval`** — devenv needs to
         resolve `PWD` to locate state dir (`.devenv/state/`). direnv
         already does this (`.envrc` has `use flake . --no-pure-eval`).
         Pure-eval `nix develop` falls back to `inputs.self.outPath`
         which is read-only and crashes on first write.
       - **Services live via `devenv up`** in a separate terminal —
         process-compose TUI shows Postgres (:15432), MinIO (:9100/:9101),
         NATS (:4222, monitor :8222), MediaMTX (:9997, WebRTC :8889).
         Ctrl-C or `q` stops everything. No `nixosModules` or systemd
         units needed for local dev.
       - **MinIO requires `permittedInsecurePackages`** — dev only;
         `devenvPkgs = import nixpkgs { config = ...; }` constructs a
         separate pkgs instance just for the devShell. Production uses
         the SeaweedFS SaaS.
       - **Port 15432, not 5432, for devenv PG** — Sergey's dev box
         runs a system postgres on :5432 (langfuse /
         `postgresql-with-zulip-dicts`). devenv PG binds :15432;
         `DATABASE_URL=postgresql:///hnvr?host=127.0.0.1&port=15432`.
         Symptom if forgotten: PG shows "not ready" in TUI → restart
         loop → "failed".
       - **Stale `.devenv/state/postgres/` after config changes** —
         devenv only writes `pg_hba.conf` + `postgresql.conf` during
         `initdb`; on subsequent starts the existing datadir is reused
         with OLD config. Fix: `~/bin/devenv-kill --reset-pg` then
         `devenv up` again.
       - **MediaMTX 1.20.0 (was 1.18.2, bumped Aug 10 2026)** — overlay
         in flake.nix overrides nixpkgs to v1.20.0 via buildGo126Module
         (vendorHash + hls.js v1.6.16 fetched separately). API stays
         `/v3/*` so the readiness probe is unchanged. `Hnvr.Web.
         MediaMTXConfigSyncer` still calls `PUT /v2/config/paths/<slug>`
         which 404s — that's a separate bug in our code (mediamtx
         migrated to `/v3/config/paths/{add,patch}` in 1.16+), not a
         version issue. Track + fix when Phase 2 Slice 3 WHEP testing
         resumes.
       - **MediaMTX crashes if HLS port :8888 collides** — Sergey's box
         has another service on :8888. Bootstrap config
         (`mediamtxBootstrap` in flake.nix) sets `rtsp/rtmp/hls/srt/
         playback: no` since HNVR only uses API + WebRTC.
       - **Stopping a hung devenv** — `~/bin/devenv-kill` (committed
         locally to ~/bin, not the repo). Scoped to `/nix/store/...`
         paths so it never touches Sergey's system services.
       Env vars consumed by HNVR binaries (`HNVR_NATS_URI`, `HNVR_S3_*`,
       `DATABASE_URL`, `HNVR_MEDIAMTX_*`, `PORT=18001`) are pre-wired —
       cabal-built binaries drop straight into the running services.
       `nix flake check --no-build --keep-going` passes for `devShells.*`,
       `packages.*`, `checks.*`, `formatter`, `nixosModules.*`; the
       pre-existing `nixosConfigurations.hnvr-{1,2}-vm` failure (missing
       `fileSystems` + `boot.loader.grub.devices` assertions) is unrelated
       and predates devenv.

## Sergey's working style

- Direct, no hand-holding. Be concise.
- Prefers GHC 9.12 + IHP even though bleeding edge — accept the jailbreak cost.
- Uses `~/bin/env-wrap` for commands requiring project flake.nix/.envrc.
- Calls himself "Sergey" — never "user".
- Wants to design for horizontal scale even when v1 doesn't need it (hence
  NATS from day one).

## Roadmap status (Aug 9 2026)

- [x] Design docs complete
- [x] Cabal scaffold + flake.nix
- [x] **Phase 0** — Bootstrap done. IHP wired, NATS bus implemented and
      connected at leader + node boot, `/healthz` returns 200, both NixOS
      VMs build and start their services, CI green for `nix build`.
- [~] **Phase 1** — Recording MVP. **Slice 1+2+3+4a+4b+4c+5+6+7a+7b done (Aug 9 2026)**:
      - ✅ Full recording pipeline verified end-to-end on Sergey's 3 cameras
      - ✅ IHP v1.6.0 schema + Cameras CRUD + ffprobe button
      - ✅ EventWriter (NATS → PG) + Archive playback (m3u8 + hls.js)
      - ✅ Slice 7a: `Hnvr.Core.Crypto` AES-256-GCM + sops-nix template
      - ✅ Slice 7b: Schema migrated `password TEXT` → `password_enc BYTEA`
            + `password_nonce BYTEA`. Cameras Create/Update encrypt on
            write via `Hnvr.Web.Controller.Support.Crypto`; UpdateAction
            skips re-encryption when the form's password field is blank
            (keep existing). Form labels updated to make this clear.
            Decrypt path (`decryptPassword`) is wired for ProbeAction
            (deferred until rtsp_template rendering lands — currently
            rtsp_url already has creds embedded so Probe uses it
            directly).
      - ✅ Slice 8 (Aug 10 2026, phase-audit-fix): Cameras admin gate —
            IHP v1.6.0 `AuthSupport` wiring (`Hnvr.Web.Auth`,
            `Controller/Sessions.hs`, `View/Sessions.New.hs`),
            `users` table, `beforeAction = ensureIsUser` on
            `CamerasController`, `AuthMiddleware (authMiddleware @User)`
            in `Config.hs`, `seedAdminUser` initializer reads
            `INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD` env, idempotent
            INSERT with `hashPassword` (pwstore-fast). Routes:
            `/NewSession`, `/CreateSession`, `/DeleteSession` (top-level,
            IHP AutoRoute default). Nav shows Login/Logout link. Closed
            audit-report-2 §2 row "Cameras CRUD admin gate".
      - ✅ Slice 9 (Aug 10 2026, phase-audit-fix): Probe sub-stream —
            `ProbeAction` now probes main URL + (when present) sub URL
            and persists `codec` (main) + `substreamCodec`/
            `substreamWidth`/`substreamHeight` (sub). Main-probe failure
            short-circuits; sub-probe failure logs but doesn't block
            main. EditView button relabeled "Probe Streams". Closed
            audit-report-2 §2 row "Probe sub-stream button".
- [x] **Phase 1 — Recording MVP complete** (code; live VM test pending).
- [~] **Phase 2 — Live View + Multi-Host. Code complete (Aug 10 2026),
      live VM test pending**. Slices shipped:
      - ✅ Slice 1: `nix/mediamtx.nix` NixOS module + flake input.
            mediamtx bumped to v1.20.0 via `mediamtxOverlay` (Aug 10 2026) —
            matches design lock; previously nixpkgs 1.18.2.
      - ✅ Slice 2: `Hnvr.Web.MediaMTXConfigSyncer` — opens dedicated
            postgresql-simple connection for LISTEN `cameras_events`,
            regenerates `/run/hnvr/mediamtx.yml`, pushes per-path config
            to mediamtx REST API (`PUT /v2/config/paths/<slug>`).
            Trigger function installed idempotently at leader startup
            (no separate migration step).
      - ✅ Slice 3: `Hnvr.Web.WhepProxy` (WAI middleware, not an IHP
            controller — needs raw body + arbitrary methods). Path
            translation `/whep/<slug>` → `/<slug>/whep`, Location header
            rewritten back so the browser's PATCH/DELETE return to us.
            Live view (`/live/<slug>`) renders `<video>` + inline ~40-LOC
            vanilla-JS WHEP client (no npm).
      - ✅ Slice 4: `Hnvr.Node.HealthReporter` (5s heartbeat, payload
            mostly stubs — cameras list + EKG CPU/GPU/mem land in
            Phase 3+/Phase 6). `Hnvr.Web.HealthCache` subscribes
            `hnvr.health.>` → IORef + UPSERT into `hosts` table.
      - ✅ Slice 5: `Hnvr.Web.AssignmentCoordinator` — 5s poll,
            15s host-down timeout, `manual_assign=true` cameras never
            overridden, publishes `hnvr.commands.assign.<slug>` on
            change. **Slice 5 audit-fix (Aug 10 2026): also publishes
            `hnvr.commands.control.<old_host>.<slug>.stop` on cross-host
            reassignment for graceful drain.** `Hnvr.Node.ConfigWatcher`
            now subscribes three subjects: `hnvr.commands.assign.>`,
            `hnvr.commands.control.<this_host>.>`, and
            `hnvr.config.cameras.>` — all handlers decode + log;
            CaptureSupervisor dispatch lands in Phase 3.
      - ✅ Slice 6: `/` dashboard (camera grid + hosts table),
            `/hosts` per-host view, `POST /cameras/:id/assign` admin
            override (clears `manual_assign` when host field is blank).
      - **Aug 10 2026 audit-fix slice** (separate from Phase 2's
        original 1–6): closed the 8 spec/CI/tooling gaps from
        `.opencode/PHASE_AUDIT_REPORT.md`:
          * ✅ `Hnvr.Capture.Fmp4` parses `tfdt`, `MediaFragment`
                carries `baseMediaDecodeTime`; `Worker` uses wall-clock
                hold-back so `sEnd = next-fragment arrival`, not
                `sStart`.
          * ✅ `Hnvr.Web.ConfigBroadcaster` (new module) reuses
                `cameras_events` LISTEN and republishes camera row JSON
                on `hnvr.config.cameras.<slug>`; node-side
                `ConfigWatcher` subscribes.
          * ✅ `EventWriter` switched to raw SQL with
                `ON CONFLICT (camera_id, start_ts) DO NOTHING`
                (no more caught unique-violation noise).
          * ✅ Pre-commit `cabal-fmt` hook + `pkgs.mediamtx` in devShell
                + new `cabal-non-web` CI job (GHC 9.10 sanity commented).
      - nginx for WHEP **skipped** — WAI middleware handles it. nginx
            can land in Phase 6 as a public-facing layer if needed.
      - Open: WHEP not yet browser-tested; mediamtx REST push hasn't
            been exercised against a live mediamtx; AssignmentCoordinator
            load balancing is naive (lex-smallest host) — fine for 2
            hosts, real load-aware assignment deferred.
- [ ] Phase 3 — CV detection + tracking
- [ ] Phase 4 — Events (line crossing + zone)  ← v1.0 release candidate
- [ ] Phase 5 — PTZ manual + presets          ← v1.0 release
- [ ] Phase 6 — Operational hardening
- [ ] Phase 7 — Auto-track milestone           ← v1.1
- [ ] Phase 8 — Polish

Phase 1 kickoff notes:
- **DONE (Aug 9 2026)**: Camera sub-streams verified via ffprobe. All three
  cameras have a usable sub-stream; see "Sergey's cameras" fixture table
  above for Sergey's canonical URL form. Sub-stream fps is 5 on 196 + 198
  (may need main-stream-with-scale fallback for CV in Phase 3).
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
6. **Phase 1 Slice 1 done** (Aug 9 2026): capture pipeline vertical
   slice works end-to-end against all 3 cameras via the
   `hnvr-record-frames` binary. Next slices in priority order:
   - Slice 2: `Hnvr.Storage.S3` (amazonka-s3 path-style) + segment publish
   - Slice 3: `CaptureWorker` state machine (Pending/Running/Backoff/
     Stopped/FailedPermanent) wrapping ffmpeg + Fmp4 + S3 + NATS publish
   - Slice 4: `Schema.sql` + IHP cameras CRUD + ffprobe button
   - Slice 5: EventWriter on leader consuming `hnvr.events`
   - Slice 6: Archive view + m3u8 + hls.js
   - Slice 7: `Hnvr.Core.Crypto` AES-256-GCM + sops-nix wiring
   The hnvr-nats `Bus` handle isn't shared yet — thread it through an
   MVar when Slice 3 starts publishing on `hnvr.events`.
