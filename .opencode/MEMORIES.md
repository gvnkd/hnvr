# HNVR — Project Memories

> Read this file FIRST before any work on this project. It's the fast-onboarding
> context for new sessions. Update it whenever you make non-trivial changes.

## Identity

- **Name**: HNVR — Haskell Network Video Recorder
- **Owner**: Sergey (`omgbebebe@gmail.com`)
- **Local path**: `/home/pion/work/dev/hnvr`
- **Remote**: `gitea@192.168.0.254:omg/hnvr.git` (branch `master`)
- **Current branch state**: Phase 0 + 1 + 2 done (code; live VM tests
  pending). Phase 3 slices 1–9 done (CV pipeline + EKG metrics + CUDA
  EP verified live on hnvr-2, Aug 13 2026 — staged, not yet committed).
  Remaining Phase 3: TRT engine CI job, hnvr-1 CUDA 12.8 wiring,
  longer bake. Phase 2 audit-and-fix pass landed Aug 10 2026 (see
  `.opencode/PHASE_AUDIT_REPORT.md` for the audit + ✅ badges on items
  that have been resolved; `.opencode/PHASE_AUDIT_REPORT_2.md` for the
  round-2 re-audit at `57aac3b`). Phase 1 slice 8 (Cameras admin gate)
  landed Aug 10 2026. Archive browser audit-fix landed Aug 12 2026
  (`8bd8d1f`: pageSize=10, filter-preserving delete, async S3 purge,
  LimitNOFILE bump). Phase 2 commit history:
  - `e08a1f7` docs: add initial HNVR design documentation
  - `ef3c743` scaffold: cabal multi-package project + flake.nix
  - `ece9519` phase 0: bootstrap IHP web + NATS bus + NixOS VMs
  - `3c45c46` phase 0 follow-ups: NATS wiring, cabal patches, worker VM broker
  - `a7a4885` … `41cd4b1` phase 1 (recording MVP, slices 1–7b)
  - `59f383b` phase 2: live view + multi-host (slices 1–6)
  - `57aac3b` phase 2 audit-fix: close 8 spec/CI/tooling gaps
  - phase 1 slice 8 (Cameras admin gate — IHP AuthSupport, users table,
    SessionsController, ensureIsUser beforeAction) — Aug 10 2026
  - `8bd8d1f` archive audit-fix: pageSize=10 + filter-preserving delete +
    async S3 purge + LimitNOFILE + 4 new pitfalls (#85–#88) — Aug 12 2026

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
# Prometheus metrics (both binaries; own warp, not IHP):
#   HNVR_METRICS_PORT=9102 curl localhost:9102/metrics   # devenv: MinIO owns :9100

# Build & boot a NixOS VM (leader). QEMU hostfwd uses COMMA separator
# for multiple ports — space-separated is silently dropped.
# Phase 2 needs to forward WebRTC (8889), API (9997), mediamtx debug.
nix build .#nixosConfigurations.hnvr-2-vm.config.system.build.vm
NIX_DISK_IMAGE=/tmp/leader.qcow2 \
  QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:18000-:8000,hostfwd=tcp:127.0.0.1:18222-:8222,hostfwd=tcp:127.0.0.1:18889-:8889,hostfwd=tcp:127.0.0.1:19997-:9997" \
  ./result/bin/run-nixos-vm
curl http://localhost:18000/healthz        # → 200 OK (WAI CustomMiddleware; works again post-Aug-10-2026 fix)
curl http://localhost:18000/               # → Dashboard (via startPage DashboardAction)
curl http://localhost:18000/Hosts          # → per-host panel (capital H — IHP-canonical URL)
curl http://localhost:18000/Dashboard      # → same as /
curl http://localhost:19997/v3/config/paths/list # → mediamtx v1.20+ live config (v2 removed)

# Worker VM (now also runs NATS broker so node has a local peer)
nix build .#nixosConfigurations.hnvr-1-vm.config.system.build.vm

# Formatter
nix fmt            # nixpkgs-fmt on .nix files

# Pre-commit checks (ormolu, hlint, nixpkgs-fmt)
nix build .#checks.x86_64-linux.pre-commit

# ---- Test suite (Aug 11 2026) -----------------------------------------
# All Haskell unit + property tests (fast lane; no services required)
cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture

# Same + integration tests against devenv MinIO/NATS (must `devenv up` first)
HNVR_TEST_INTEGRATION=1 cabal test hnvr-nats hnvr-storage

# NixOS leader smoke test (boots VM, curls /healthz + /NewSession; ~10 s)
nix build .#checks.x86_64-linux.hnvr-leader-smoke

# Playwright UI tests — chromium launches cleanly inside nix develop
# (chromiumRuntimeDeps in flake.nix wires NIX_LD_LIBRARY_PATH).
# Requires devenv services up + a leader on :18001.
cd tests/e2e && npm install && npx playwright install chromium   # one-time
nix develop --command bash -c 'cd tests/e2e && npm test'           # ~6 s
```

## Repo layout

```
hnvr/
├── design_docs/         11 files (00–08 original + 09-testing.md +
│                        10-test-plan.md added Aug 11 2026)
├── tests/
│   └── e2e/             Playwright TypeScript suite (S4/S5 Aug 11 2026
│                        + archive-browser slice Aug 12 2026)
│                        — login.spec, cameras-crud.spec, archive-playback.spec,
│                          live-view.spec, archive-browser.spec (14 specs),
│                          lib/auth.ts (loggedInPage fixture)
├── .github/workflows/   ci.yml (nix flake check + nix build .#hnvr-web/.#hnvr-nats
│                        + cabal-non-web + cabal-test-non-web + nightly playwright-e2e)
├── cabal.project        packages + allow-newer + vendored/nats-queue
├── flake.nix            ihp overlay + hnvrHaskellOverlay + nixosConfigurations
│                        + chromiumRuntimeDeps (S5 nix-ld wiring) +
│                        checks.hnvr-leader-smoke (S5 NixOS VM test)
├── flake.lock           pinned nixpkgs + flake-utils + pre-commit-hooks + ihp + devenv
├── nix/                (see "Repo layout — expanded nix/" block below)
├── vendored/
│   └── nats-queue/      2017 lib + sClose → close patch baked in
├── hnvr-core/           REAL types + S3-extracted pure logic
│   ├── src/Hnvr/Core/   Id, Geometry, Logging, Metrics, Prelude, Time,
│   │                    Segment, Crypto, Whep (extracted from hnvr-web S3),
│   │                    Assignment (extracted from hnvr-web S3),
│   │                    ArchiveBrowser (extracted from Web.Controller.Archive S3)
│   ├── test/            S1+S3 spec suite + ArchiveBrowserSpec (97 tests total)
│   └── app/CryptoTest.hs
├── hnvr-nats/           REAL Bus (nats-queue wrapper) + Subjects
│   └── test/            S2 spec suite (16 tests; env-gated integration)
├── hnvr-storage/        REAL S3 wrapper (minio-hs, NOT amazonka — see pitfall #28)
│   ├── src/Hnvr/Storage/S3.hs
│   ├── test/            S2 spec suite (5 tests; env-gated against MinIO)
│   └── app/S3Upload.hs  hnvr-s3-upload integration binary
├── hnvr-capture/        Fmp4 (REAL), Ffmpeg (REAL), Worker (REAL state machine);
│   ├── test/            S1+S2 spec suite (8 + 17 tests; Fmp4 chunk-boundary
│   │                    property is the anchor test)
│   └── app/             exes: hnvr-record-frames, hnvr-s3-upload, hnvr-capture-loop
├── hnvr-cv/             OnnxRuntime (REAL FFI binding + Internal vtable
│   │                    loader, smoke-tested vs libonnxruntime 1.24.4),
│   │                    Preprocess, Decode, Rules, AutoTrack,
│   │                    Tracker/Sort (stubs — land with Phase 3 slices)
│   └── test/            S6 started: OnnxRuntimeSpec (2 smoke tests,
│                        env-gated on HNVR_ONNXRUNTIME_LIB, pitfall #91)
├── hnvr-ptz/            Driver (REAL typeclass), Onvif (stub), Controller (stub)
├── hnvr-web/            Library + 2 executables (LeaderMain, NodeMain)
│                        ├── Application/Schema.sql   IHP schema source of truth
│                        ├── regen.sh                 regen+patch IHP codegen (see pitfall #32)
│                        ├── gen/Generated/...        IHP-generated types (committed)
│                        ├── src/Hnvr/Web.hs                 version stub
│                        ├── src/Hnvr/Web/Config.hs          IHP config + healthz + NATS init
│                        │                                  + EventWriter + HealthCache
│                        │                                  + AssignmentCoordinator (imports
│                        │                                    Hnvr.Core.Assignment — S3 extraction)
│                        │                                  + MediaMTXConfigSyncer
│                        ├── src/Hnvr/Web/FrontController.hs RootApplication + parseRoute
│                        ├── src/Web/Controller/Cameras.hs      CRUD + Probe + Assign
│                        ├── src/Web/Controller/Cameras/Probe.hs ffprobe JSON parser
│                        ├── src/Web/Controller/Support/Crypto.hs encryptPassword / decryptPassword / requireKey
│                        ├── src/Web/Controller/{Archive,Live,Dashboard,Hosts,Sessions}.hs
│                        ├── src/Hnvr/Web/{EventWriter,HealthCache,AssignmentCoordinator,
│                        │                  ConfigBroadcaster,MediaMTXConfigSyncer,WhepProxy,
│                        │                  Metrics}.hs
│                        │   (WhepProxy imports Hnvr.Core.Whep — S3 extraction)
│                        ├── src/Hnvr/Node/{HealthReporter,ConfigWatcher}.hs
│                        ├── src/Hnvr/Web/View/{Layout,Cameras/*,Archive/Player,Live/Show,
│                        │                  Dashboard/Index,Hosts/Index,Sessions/New}.hs
│                        └── app/{LeaderMain,NodeMain}.hs
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

## Test infrastructure (Aug 12 2026 — S1–S5 complete + archive-browser slice)

Test pyramid + framework rationale: `design_docs/09-testing.md`.
Per-package inventory + sprint schedule: `design_docs/10-test-plan.md`.
Both committed Aug 11 2026 (commit `fdf16e3`); S1–S5 delivered in 7 commits.
Archive-browser slice added Aug 12 2026 (commit `8bd8d1f`).

**143 Haskell tests + 20 Playwright specs + 1 NixOS VM smoke test.**

> Aug 13 2026: now **217 Haskell tests** (103 core + 35 capture +
> 58 cv + 16 nats + 5 storage) after the Phase 3 EKG slice.

| Layer | Where | Status |
|-------|-------|--------|
| Unit + property (tasty + QuickCheck) | `hnvr-{core,nats,storage,capture}/test/` | 143 tests (97 core + 16 nats + 5 storage + 25 capture), all green via `cabal test` |
| Integration (NATS, S3 MinIO) | `hnvr-nats/test/Hnvr/Nats/BusSpec.hs`, `hnvr-storage/test/Hnvr/Storage/S3Spec.hs` | env-gated on `HNVR_TEST_INTEGRATION=1`; verified green against devenv services |
| Web UI (Playwright + chromium) | `tests/e2e/` | 20 specs (14 archive-browser + 1 archive-playback + 1 cameras-crud + 1 live-view + 3 login), all green; chromium launches cleanly inside `nix develop` via `chromiumRuntimeDeps` in flake.nix |
| NixOS VM smoke | `flake.nix` `#checks.x86_64-linux.hnvr-leader-smoke` | boots leader VM, asserts `/healthz` + `/NewSession`; runs in ~10 s; verified PASS |

**Verified commands** (Aug 11 2026):

```bash
# All Haskell unit + property tests (fast; no services required)
cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture

# Same + integration tests against devenv MinIO/NATS
HNVR_TEST_INTEGRATION=1 cabal test hnvr-nats hnvr-storage

# Pre-commit hooks (ormolu, cabal-fmt, nixpkgs-fmt, hlint)
nix build .#checks.x86_64-linux.pre-commit

# NixOS leader smoke test (boots VM, curls /healthz)
nix build .#checks.x86_64-linux.hnvr-leader-smoke

# Playwright UI tests (start devenv up + ./result/bin/hnvr-leader first)
cd tests/e2e && npm install && npx playwright install chromium
nix develop --command bash -c 'cd tests/e2e && npm test'
```

**CI matrix** (`.github/workflows/ci.yml`):
- `nix-flake-check` — `nix flake check` + `nix build .#hnvr-web` + `.#hnvr-nats`
- `cabal-non-web` — `cabal build` of the 6 non-IHP packages
- `cabal-test-non-web` — `cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture`
- `playwright-e2e` — nightly + on master; boots devenv + leader, runs npm test

**Env-gating pattern for integration tests**: tests look up
`HNVR_TEST_INTEGRATION` and silently skip with `pure ()` unless it's
`"1"`. Sergey's devenv-always-up workflow means integration tests are
run with `HNVR_TEST_INTEGRATION=1 cabal test`; CI runs only the pure
layer. See `Hnvr.Nats.BusSpec.integrationTest` for the canonical
helper.

**Pure-helper extraction pattern** (S3, when hnvr-web modules can't be
cabal-tested per pitfall #14): extract the pure decision logic into a
new `Hnvr.Core.<Name>` module, hnvr-web imports it and projects the
IHP record into the pure-shape type at the call site. Established
Aug 11 2026 with `Hnvr.Core.Whep` (from `WhepProxy`) and
`Hnvr.Core.Assignment` (from `AssignmentCoordinator`). Extended
Aug 12 2026 with `Hnvr.Core.ArchiveBrowser` (from
`Web.Controller.Archive` — pagination math, window resolution,
filter query-string round-trip, datetime-local parsing). Pattern is
generalisable to future leader-side testable extractions.

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
    overlay applies but cabal doesn't see. **Confirmed Aug 11 2026: even
    with `pkgs.icu` + `pkgs.icu.dev` wired into devenv `packages` and
    `PKG_CONFIG_PATH=${pkgs.icu.dev}/lib/pkgconfig` set, `cabal build
    hnvr-web` still fails — `text-icu-0.7.1.0` itself has a GHC 9.12
    source-level incompatibility (`Word8` vs `Word16` in
    `Data.Text.ICU.Internal.hsc:58`); IHP's nix overlay patches
    text-icu but cabal can't see the patch.** The 6 non-IHP packages
    (core, nats, storage, capture, cv, ptz) are cabal-buildable; hnvr-web
    is `nix build .#hnvr-web` only. **Workaround for testing**: extract
    pure logic from hnvr-web modules into `Hnvr.Core.*` (testable via
    cabal). Pattern established Aug 11 2026 with
    `Hnvr.Core.Whep` (extracted from `Hnvr.Web.WhepProxy`) and
    `Hnvr.Core.Assignment` (extracted from
    `Hnvr.Web.AssignmentCoordinator`); hnvr-web imports these and
    projects IHP records into the pure-shape types at the call site.

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

    42. **IHP v1.6.0 `sqlExec`/`unsafeSqlExec` are broken for DDL** — emits
        `-Wdeprecations` warnings AND fails at runtime on DDL
        (`CREATE FUNCTION`, `CREATE TRIGGER`, `DROP TRIGGER IF EXISTS`)
        with `UnexpectedResultStatementError "Empty bytes"`: the IHP
        Statement is built with a row-expecting decoder regardless of
        the doc claim that `unsafeSqlExec` is the DDL escape hatch —
        they're true aliases. **Workaround: use `postgresql-simple`
        (already in IHP's transitive deps) for any DDL.** Open a
        one-shot `PG.connectPostgreSQL` connection, `PG.execute_` the
        statements, `PG.close`. `Hnvr.Web.MediaMTXConfigSyncer.ensureTrigger`
        is the canonical example. The recommended `[typedSql|...|]`
        + `sqlExecTyped` quasi-quoter doesn't cover `CREATE FUNCTION`
        either, so DDL stays on pg-simple indefinitely.

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
       `currentUserOrNothing` — currently `Config.hs`,
       `Web/Controller/Cameras.hs` (renamed from `Hnvr.Web.Controller.*`
       in commit `ce739c1`, see pitfall #59), `View/Layout.hs`. Add the
       empty import wherever IHP auth is used.

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
         `/v3/*` so the readiness probe is unchanged. **`Hnvr.Web.
         MediaMTXConfigSyncer` still calls `PUT /v2/config/paths/<slug>`
         which 404s — tracked in Taiga issue #467** (Priority High,
         Severity Important, blocks Phase 2 Slice 3 WHEP demo). Fix:
         migrate to `/v3/config/paths/{add,patch}/<slug>` per v1.20.0
         openapi.yaml. The bug is in our code (mediamtx migrated in
         v1.16), not a version issue — v1.20.0 bump did NOT auto-fix it.
       - **MediaMTX crashes if HLS port :8888 collides** — Sergey's box
         has another service on :8888. Bootstrap config
         (`mediamtxBootstrap` in flake.nix) sets `rtsp/rtmp/hls/srt/
         playback: no` since HNVR only uses API + WebRTC.
       - **Stopping a hung devenv** — `~/bin/devenv-kill` (committed
         locally to ~/bin, not the repo). Scoped to `/nix/store/...`
         paths so it never touches Sergey's system services.
        Env vars consumed by HNVR binaries (`HNVR_NATS_URI`, `HNVR_S3_*`,
        `DATABASE_URL`, `HNVR_MEDIAMTX_*`, `PORT=18001`, `HNVR_DATA_KEY`)
        are pre-wired —
       cabal-built binaries drop straight into the running services.
       `nix flake check --no-build --keep-going` passes for `devShells.*`,
       `packages.*`, `checks.*`, `formatter`, `nixosModules.*`; the
       pre-existing `nixosConfigurations.hnvr-{1,2}-vm` failure (missing
       `fileSystems` + `boot.loader.grub.devices` assertions) is unrelated
        and predates devenv.

   56. **Web UI build pipeline — Tailwind standalone CLI** (Aug 10 2026) —       CSS lives in `hnvr-web/static/src.css` (input) and compiles to
       `hnvr-web/static/app.css` via the **tailwind standalone CLI**
       (`nixpkgs#tailwindcss`, v3.4.17) — **no npm, no node, no postcss**.
       Component classes via `@apply` are defined in `src.css`; HSX views
       use semantic class names (`.btn`, `.card`, `.led`, `.badge`, etc.).
       Things to know:
       - **Production**: `flake.nix`'s `hnvr-static` derivation (exposed
         via `hnvrTopOverlay` so `pkgs.hnvr-static` resolves in NixOS)
         runs `tailwindcss --minify` to produce `$out/app.css`. The
         `services.hnvr.leader.staticAssets` option (nix/module.nix)
         defaults to this derivation; preStart copies it into
         `${dataDir}/static/app.css` (idempotent on every service start).
       - **Dev**: `devenv up` runs a tailwind watcher process
         (`processes.tailwind.exec`) that rebuilds
         `hnvr-web/static/app.css` on HSX/src.css changes. The dev
         leader binary serves it via `APP_STATIC=hnvr-web/static`
         (relative to CWD — Sergey runs from repo root).
       - **First-time dev setup**: if `hnvr-web/static/app.css` doesn't
         exist (e.g. fresh checkout, watcher not yet run), the leader
         serves a 404 for `/static/app.css` and pages render unstyled.
         Manual rebuild: `cd hnvr-web && tailwindcss --input static/src.css --output static/app.css --minify`.
       - **Tailwind pitfall: `@apply group` is rejected** — the `group`
         utility is a marker class, not a real CSS property. Put `group`
         directly in HSX alongside the component class
         (`<div class="cam-card group">`) instead of via `@apply`.
       - **Tailwind pitfall: `tailwind.config.js` `content` globs are
         resolved relative to the config file** — the `hnvr-static`
         derivation copies the whole `hnvr-web/` tree as `src` so
         tailwind can scan `src/Hnvr/Web/View/**/*.hs` for class names.
       - **IHP static serving**: IHP's static middleware reads
         `APP_STATIC` env (default `"static/"` relative to CWD). Module
         already wires `APP_STATIC = "${cfg.dataDir}/static"`. Files in
         that dir are served at `/static/<filename>` with proper cache
         headers (no cache in dev, `max-age=forever` in prod with
         asset-path hash busting via `IHP_ASSET_VERSION`).
        - **`Html`-typed local helpers** (pitfall #36 still applies) —
          keep view helpers in the `where` block of the `View` instance
          method so the implicit-param constraint flows from the
          enclosing scope; top-level helpers need either
          `(?context :: RequestContext, ?request :: Request) =>` or no
          signature.

    57. **`HNVR_DATA_KEY` must be set before any Cameras CRUD write** (Aug 10
       2026) — `Web.Controller.Support.Crypto.requireKey` throws
       `userError "HNVR_DATA_KEY not set; cannot encrypt/decrypt camera
       passwords"` at the action level if missing. Symptom: `/NewCamera`
       form POST → IHP exception page. Fix landed in devenv: a stable
       dev-only base64 32-byte key is baked into the `env` block in
       `flake.nix` (matches the `INITIAL_ADMIN_PASSWORD` dev-convenience
       pattern). Production sources via sops-nix (Phase 6).

    58. **hasql serialises `String` as a PG array, not TEXT** (Aug 10 2026) —
       `Env.lookupEnv` returns `IO (Maybe String)` and `String = [Char]`.
       Passing that `String` straight to `sqlExec`'s tuple makes hasql
       pick the `[Char]` `ToField` instance, which encodes a PG **array**
       of char — the value lands in the column as `{a,d,m,i,n,@,...}`
       instead of `admin@hnvr.local`. Symptom: IHP's
       `filterWhereCaseInsensitive (#email, ...)` in
       `createSessionAction` never matches, so login always 302s back
       to `/NewSession` with "Invalid Credentials". Fix: `cs` to `Text`
       before the SQL tuple: `let emailT = cs email :: Text in sqlExec
       ... (emailT, hash)`. Rule: never pass a `String` to hasql —
       always coerce to `Text` first.

       While here: `Hnvr.Web.Config.config` now `setEnv "APP_STATIC"
       "hnvr-web/static"` when the env var is unset, so the dev leader
       binary serves `/static/app.css` without needing
       `APP_STATIC=hnvr-web/static` on the command line. Production
       overrides via `nix/module.nix`'s `APP_STATIC = "${dataDir}/static"`.
       And devenv's env block now ships dev defaults
       (`admin@hnvr.local` / `hnvr-dev`) so `devenv up` + leader just
       works.

   59. **IHP `actionPrefixText` derives URL prefix from the controller
       module's FIRST dot-segment** (Aug 10 2026, commit `ce739c1`) —
       modules under `Hnvr.Web.Controller.*` got the URL prefix `/hnvr/`
       (not `/`), so every route 404'd with "Action not found". IHP's
       `IHP.RouterSupport` isPrefixOf check matches `"Web."` literally,
       so controllers MUST live under `Web.Controller.*` for the prefix
       to collapse to `/`. Symptom: `curl http://localhost:18000/` →
       404 "Action not found" while `curl http://localhost:18000/hnvr/`
       worked. Fix: `git mv hnvr-web/src/Hnvr/Web/Controller
       hnvr-web/src/Web/Controller` + update all imports. Views stay
       under `Hnvr.Web.View.*` (only the `isPrefixOf "Web."` check on
       controllers matters). **Always put IHP controllers under
       `Web.Controller.*`, never namespaced under the project name.**

       Companion gotcha: IHP AutoRoute generates URLs from constructor
       names, so `IndexAction` in every controller collides on `/Index`.
       Use IHP-canonical per-resource form: `CamerasAction`,
       `ShowCameraAction`, `EditCameraAction`, `CreateCameraAction`,
       `UpdateCameraAction`, `DeleteCameraAction`, `ProbeCameraAction`,
       `AssignCameraAction`, `HostsAction`, `DashboardAction`,
       `PlayerArchiveAction`, `PlaylistArchiveAction`, `ShowLiveAction`.
       Sessions is already canonical (`NewSessionAction` /
       `CreateSessionAction` / `DeleteSessionAction`) — left as-is.

       Companion: `startPage DashboardAction` in the `FrontController`
       instance maps `/` → the named action without consuming an
       AutoRoute slot. Use it for the root URL (don't try to make an
       `IndexAction` live at `/`).

       Open follow-up: `/healthz` 404s — `Config.hs`'s `CustomMiddleware`
       is not being applied by IHP v1.6.0's middleware chain. Tracked
       separately. **Closed Aug 10 2026**: see pitfall #60.

   60. **IHP `option` is FIRST-write-wins, not last-write-wins** (Aug 10
       2026) — `IHP.FrameworkConfig.option` is implemented as
       `State.modify (\map -> if TMap.member @option map then map else TMap.insert value map)`
       (i.e. insert-if-absent). And `buildFrameworkConfig` runs
       `appConfig >> ihpDefaultConfig` — user config FIRST, defaults
       SECOND. So calling `option $ CustomMiddleware X` followed by
       `option $ CustomMiddleware Y` silently DROPS Y. Symptom: Sergey
       had two `option $ CustomMiddleware` calls (whep + healthz); only
       whep was active, so `/healthz` 404'd for all of Phase 2. Fix:
       compose into one CustomMiddleware call:
       `option $ CustomMiddleware (whepMiddleware . healthzMiddleware)`.
       Same trap applies to any other option type — check the IHP
       source if a `option` call seems to have no effect. Affects:
       `CustomMiddleware`, `AuthMiddleware`, `SessionCookie`,
       `RLSAuthenticatedRole`, etc.

   61. **MediaMTX v1.16+ split the upsert PUT into add/patch/delete**
       (Aug 10 2026, Taiga #467 closed) — the old `PUT /v2/config/paths/<id>`
       is GONE in v1.20.0. v3 API surface (confirmed against
       `internal/api/api.go` of mediamtx v1.20.0):
         * `GET    /v3/config/paths/list`              → `{itemCount, pageCount, items:[...]}`
         * `GET    /v3/config/paths/get/<name>`        → single path object
         * `POST   /v3/config/paths/add/<name>`        → create, 400 if exists
         * `PATCH  /v3/config/paths/patch/<name>`      → patch, 404 if not exists
         * `POST   /v3/config/paths/replace/<name>`    → replace, 404 if not exists
         * `DELETE /v3/config/paths/delete/<name>`     → delete, 404 if not exists
       Methods MATTER: `add` is POST, `patch` is PATCH, `delete` is
       DELETE. `Hnvr.Web.MediaMTXConfigSyncer.pushPaths` does
       list → diff → for each desired: `add` if new, `patch` if exists;
       for orphans: `delete`. List response is `{items:[{name,...}]}`,
       NOT the old map form — decode with `Aeson.Types.parseMaybe` +
       `withObject "PathList" (.: "items")`. Read-only endpoints are
       auth-free in default config; mutating endpoints need either
       no auth configured or a credentials header (we run with
       `api: yes` and no auth in dev/leader).

   62. **WAI Middleware composition order** (Aug 10 2026) — when composing
       `Middleware`s with `.`, the LEFTMOST runs FIRST on incoming
       requests: `(f . g) app = f (g app)`. So
       `whepMiddleware . healthzMiddleware` means whep gets the request
       first (matches `/whep/*`), then healthz (`/healthz`), then IHP.
       Put the most-specific path-prefix middleware leftmost.

   63. **IHP HSX does NOT splice `{...}` inside `<script>` or `<style>`
       tags** (Aug 10 2026) — `ihp-hsx/IHP/HSX/Parser.hs:111-124` treats
       script/style bodies as pre-escaped raw text (so CSS like
       `h1 { color:red }` doesn't get re-parsed as a splice). Symptom:
       `[hsx|<script>{myJs}</script>|]` outputs the literal string
       `{myJs}` as JS → browser JS parse error
       (`Uncaught SyntaxError: missing ) after argument list` at
       column 1, since the literal text starts with `{`). Both
       `View/Live/Show.hs` and `View/Archive/Player.hs` had this bug
       for ~all of Phase 2 (live view JS never ran, archive player
       silently no-op'd). Fix: build the entire `<script>…</script>`
       element in Haskell and inject as a single body-level splice:
       ```haskell
       [hsx|
         ...
         <div>...</div>
         {scriptTag}
       |]
         where
           scriptTag = preEscapedTextValue ("<script>" <> js <> "</script>" :: Text)
       ```
       Verify via `curl -b cookie http://leader/ShowLive?... | grep script` —
       you should see actual JS, not `{preEscapedTextValue …}`.

    64. **nixpkgs `xorg.*` attribute naming is inconsistent** (Aug 11 2026
        S5 chromium runtime deps) — there is no rule, every attr has to be
        tested. The cases that bit me:
        - `xorg.libx11` ❌ → `xorg.libX11` ✓
        - `xorg.libXscrnsaver` ❌ → `xorg.libXScrnSaver` ✓
        - `xorg.libXshmfence` ❌ → `xorg.libxshmfence` ✓ (lowercase 's'!)
        - `xorg.libxcb` ✓ (correct as lowercase, NOT `libXcb`)
        Quick check before committing a list:
        `nix eval --impure --raw --expr 'let pkgs = import <nixpkgs> {}; in if pkgs.xorg ? ATTR then "yes" else "no"'`.

    65. **`libgbm` is a separate nixpkgs package, NOT in `pkgs.mesa`**
        (Aug 11 2026 S5) — `mesa` ships libGL but `libgbm.so.1` lives in
        `pkgs.mesa-libgbm`/`pkgs.libgbm`. Chromium and Playwright's
        chrome-headless-shell both need it. The full chromium runtime
        deps list (verified working Aug 11 2026) is the
        `chromiumRuntimeDeps` binding in flake.nix — copy from there
        rather than re-deriving.

    66. **`pkgs.nixosTest` was renamed to `pkgs.testers.nixosTest`**
        (renamed 2025-10-27, converted to throw) — using the old name
        produces `error: 'nixosTest' has been renamed to/replaced by
        'testers.nixosTest'`. Documented in `nixpkgs/pkgs/top-level/
        aliases.nix`. Always use `pkgs.testers.nixosTest` for VM tests
        now; same API.

    67. **IHP AutoRoute maps `DeleteCameraAction` to HTTP DELETE, not POST**
        (Aug 11 2026 S5) — verified via curl: POST returns 405, DELETE
        returns 302 (success). The Cameras controller comment line 16
        documents this (`@/DeleteCamera?cameraId=…@ (DELETE)`) — IHP's
        convention is to use the HTTP method matching the action verb
        prefix (Create→POST, Update→POST, Delete→DELETE). HTML forms
        can't do DELETE natively, so v1 has no UI for delete — the
        Playwright test calls it via `page.request.delete(...)` directly.

        Companion: **Playwright's `page.request.delete()` follows 302
        redirects with the SAME method (DELETE)**, which 405s on the
        redirect target (`/Cameras` doesn't accept DELETE). Use
        `{maxRedirects: 0}` + `expect(resp.status()).toBe(302)` to
        short-circuit.

    68. **Headless chromium reports `canPlayType('application/vnd.apple.
        mpegurl')` as `'maybe'`** (truthy) — even in `chrome-headless-shell`
        (no real Safari involved). This means the View/Archive/Player.hs
        "Native HLS (Safari)" branch fires under headless chromium, so
        the status pill text becomes `"Native HLS (Safari)"` rather
        than `"Loading player…"`. Playwright tests on this page must
        accept either branch; pinning to `"Loading player…"` is a
        timing-sensitive flake.

    69. **cabal test target syntax is `pkg:testsuite-name`, not
        `pkg:test:testsuite-name`** (Aug 11 2026 S1) — the latter gives
        "Unknown target". The full form: `cabal test hnvr-core:hnvr-core-test`
        where `hnvr-core-test` is the value of the `test-suite` stanza's
        `name` field. `cabal test hnvr-core` (no component) runs ALL
        test-suites in that package; the explicit form lets you scope
        to one when iterating.

    70. **The `cabal test` exit code propagates** (Aug 11 2026 S1) —
        `cabal test` returns non-zero on test failure AND on build
        failure. CI jobs that gate merges on cabal-test should use
        `cabal test` directly (not `cabal build && cabal test`) so a
        compile failure isn't double-counted.

    71. **`time-1.14` (GHC 9.12) hides the `UTCTime` constructor** (Aug
        11 2026 S1) — `import Data.Time.Clock (UTCTime)` brings only the
        TYPE; the constructor needs explicit `(..)`:
        `import Data.Time.Clock (UTCTime (..))`. Without it, GHC errors
        with `[GHC-01928] Illegal term-level use of the type constructor
        'UTCTime'`. No `mkUTCTime` shim exists in this version; the
        pattern `UTCTime day diffTime` still works once the constructor
        is in scope.

    72. **IHP `Id' "table"` constructor import** (Aug 11 2026 M1) — to
        extract the underlying `UUID` from a `Camera`'s `id` field for
        wire transmission, neither `Data.Coerce.coerce` nor the
        apparent `import IHP.ModelSupport (Id (..))` works. Coerce
        fails with `[GHC-18872] Couldn't match representation ... The
        data constructor 'IHP.ModelSupport.Types.Id' of newtype
        'IHP.ModelSupport.Types.Id'' is not in scope`. The `Id (..)`
        import only brings the TYPE alias into scope (no constructor).
        **Working pattern**:
        ```haskell
        import IHP.ModelSupport (Id' (Id))
        ...
        case cam |> get #id of Id uuid -> uuid
        ```
        `Id'` is the type constructor (with prime); `Id` (no prime) is
        the data constructor. `IHP.ModelSupport (Id' (Id))` exports
        both correctly. The generated code in `View/Hosts/Index.hs`
        uses `Data.Coerce (coerce)` to `Text` and works because
        `IHP.ViewPrelude` re-exports the constructor transitively.

    73. **`file-embed`'s `embedFile` vs `embedFileRelative` under nix
        sandbox** (Aug 11 2026 M2) — `embedFileRelative` claims to
        resolve relative to the source file but in nix sandbox it
        resolves relative to CWD (the package root). Result: the same
        splice works under cabal but errors out under nix build with
        `/build/hnvr-web/../../Application/Schema.sql: does not exist`.
        **Use `embedFile "Application/Schema.sql"`** (CWD-relative,
        works in both) for any file outside the cabal `hs-source-dirs`
        listing. CWD is reliably set to the package root by both
        cabal-install and nix's `callCabal2nix`.

    74. **`postgresql-simple-migration` 0.1.15.0 API** (Aug 11 2026 M2):
        - `MigrationResult` is **kind `* -> *`**, parameterized by the
          error payload type. `MigrationInitialization` produces
          `MigrationResult String`, `MigrationScript` produces
          `MigrationResult ByteString`. Write handlers as
          `Show a => ... -> MigrationResult a -> ...` or split into
          two specialized handlers.
        - Constructors: `MigrationSuccess` (no payload) and
          `MigrationError a` (payload of type `a`).
        - `runMigration` requires the caller to wrap in
          `withTransaction` — the library does NOT auto-commit.
        - Hackage 0.1.15.0 cabal revision 1 + nixpkgs both ship the
          `* -> *` version. The plain `data MigrationResult` shape
          shown in old blog posts is from a pre-0.1.x release.
        - The library's `bytestring <0.11`, `text <1.3`, `time <1.10`
          bounds are stale on GHC 9.12; `doJailbreak` in
          `flake.nix`'s `hnvrHaskellOverlay` lifts them.

    75. **NoFieldSelectors pitfall generalised** (Aug 11 2026 M1,
         extends pitfall #46) — `rec.field` is the ONLY access form
         inside hnvr-web library modules (NoFieldSelectors is in the
         library default-extensions). This applies to BOTH reads
         (`sup.csConfig`) AND writes via record-update in module-
         qualified positions. The trap fires whenever you write a new
         module in hnvr-web with the standard extension set. Watch for
         `[GHC-88464] Variable not in scope: <fieldSelector> ::
         <Type> -> <FieldType> Suggested fix: Notice that '<field>' is
         a field selector belonging to the type '<Type>' that has been
         suppressed by NoFieldSelectors.` Fix: switch `f x` → `x.f`.
         Add `{-# LANGUAGE OverloadedRecordDot #-}` to the module if
         it's not already there (it IS in hnvr-web.cabal
         default-extensions but module-local LANGUAGE pragmas can
         shadow).

    76. **hlint misparses OverloadedRecordDot `c.id` as composition**
         (Aug 11 2026 archive-browser) — `camUuid c = case c.id of ...`
         trips "Redundant id" (hlint sees `c . id`). Fix: use
         `case c |> get #id of Id u -> u` instead of record dot for
         `id` fields specifically; other field names are unaffected.

    77. **IHP `paramOrNothing` is PURE** (Aug 11 2026 archive-browser) —
         `paramOrNothing :: (?request :: Request) => ByteString -> Maybe Text`,
         not `IO (Maybe Text)`. Bind with `let`, not `<-`. Ideal for
         optional query params when AutoRoute only handles the typed
         constructor fields.

    78. **Never edit an already-applied migration file** (Aug 11 2026) —
         m3-m8 appended the BRIN index to `migrations/0001-initial.sql`
         AFTER dev DBs had applied it → `schema_migrations` checksum
         mismatch → leader refuses to boot with the cryptic error
         `SchemaMigration 0001-initial failed: "0001-initial"`. Fixed by
         restoring 0001 to its applied checksum and moving the index to
         `0002-brin-index.sql` (+ a second `MigrationScript` in
         `SchemaMigration.runLeaderMigrations`). Policy (already written
         in the file header, now enforced by pain): new schema change =
         new `NNNN-name.sql` + new embed + new runMigration call.

    79. **Headless `devenv up` needs a pseudo-TTY** (Aug 11 2026) —
         `devenv up --detach` does NOT exist (process-compose prints its
         own usage and exits); `nohup … devenv up` dies with
         `TUI startup error: open /dev/tty`. Working headless form:
         `nohup script -qec "nix develop --no-pure-eval --command devenv up" /tmp/pc.log &`.

    80. **Playwright strict mode + hidden form inputs** (Aug 11 2026) —
         `locator('input[name="from"]')` matches BOTH the filter-form
         datetime input AND the hidden inputs in per-row delete forms →
         strict-mode violation. Scope form assertions to
         `page.locator('form[action="/Archive"] …')` whenever a page
         carries more than one form.

    81. **Timeline grouping must partition by camera** (Aug 11 2026) —
         `groupRecordings` on a mixed-camera segment list merged all
         three cameras into a handful of cross-camera "recordings"
         (concurrent captures interleave at sub-second offsets, far
         below the 30s split tolerance). Symptom: /Archive showed 4
         rows all labeled low_ent instead of ~12 across 3 cameras.
         `Hnvr.Core.Recording.Span` now carries `spCameraId` and
         grouping is `groupRecordingsBy spCameraId`. Any future
         timeline/density logic has the same constraint.

    82. **IHP AutoRoute maps `Delete*` constructors to HTTP DELETE
         only** (Aug 12 2026) — `DeleteRecordingAction` 405'd our plain
         `<form method="POST">` with `UnexpectedMethodException
         {allowedMethods = [DELETE]}`. IHP's own delete forms rely on
         ihp.js's method-override helper, which our custom Layout.hs
         doesn't load; there is no `_method` middleware in v1.6.0.
         Workaround: name destructive POST actions without the `Delete`
         prefix (`PurgeRecordingAction`, same pattern as
         `AssignCameraAction`).

    83. **`nix build` overwrites `./result` with the LAST-built attr**
         (Aug 12 2026) — running `nix build .#checks…pre-commit` after
         `.#hnvr-web` replaced `./result` with the pre-commit-run
         output, and the next leader restart died with
         `result/bin/hnvr-leader: No such file or directory`. Use a
         dedicated out-link for the app: `nix build .#hnvr-web -o
         result-web` and run `./result-web/bin/hnvr-leader`.

    84. **S3 row-key deletes are blind to legacy/orphan objects**
         (Aug 12 2026) — rows written before the ms-key fix store
         second-precision keys while the objects are ms-precision, and
         S3 DELETE of a nonexistent key silently succeeds. Purging
         via DB keys alone orphaned ~9.8k objects (4.2 GB) and wedged
         dev MinIO at its free-drive threshold (`XMinioStorageFull`).
         `PurgeRecordingAction` now also lists `<slug>/<date>/` per day
         in the window and deletes by key-embedded timestamp
         (`parseKeyTimestamp`), independent of the rows. `init.mp4`
         never matches the segment layout and is deliberately kept.
         Companion dev fix: `HNVR_SPOOL_DIR` is now set in the devenv
         env block — NodeMain's `/var/lib/hnvr/spool` default is
         unwritable outside NixOS, so the spool fallback had been
         silently failing in dev.

    85. **IHP AutoRoute field names share the URL param namespace with
        filters** (Aug 12 2026) — `PurgeRecordingAction {cameraId :: Id
        Camera}` made IHP generate URLs like `/PurgeRecording?cameraId=…`.
        The archive browser also round-trips a `cameraId` *filter* param
        through the same URL (so the post-delete redirect can land back
        on the same filtered view). With both names colliding we got
        `?cameraId=X&cameraId=X` — Sergey caught it in DevTools.
        Workaround: rename the AutoRoute field to a verb-prefixed name
        (`purgeCameraId`) so the filter name has its own slot. Same trap
        applies to any controller action that round-trips filter params
        through its own URL — keep action-field names distinct from
        filter param names. Same pattern was already used for
        `from`/`to` (form body `purgeFrom`/`purgeTo` vs URL filter
        `from`/`to`).

    86. **systemd default `LimitNOFILE=1024` is too low for the leader**
        (Aug 12 2026) — under Sergey's 3-camera 24/7 capture load the
        leader holds many concurrent FDs: per-camera ffmpeg subprocess
        pipes, MinIO upload sockets, WHEP/WebRTC session sockets, async
        S3-purge workers (`PurgeRecordingAction` walks thousands of
        segment keys). It peaked past 1024 and
        `Network.Socket.accept: resource exhausted (Too many open files)`
        started refusing new connections — `/NewSession` got `EAGAIN`,
        Playwright's `page.goto` retried for 30 s, the cameras-crud
        test looked "hung on login". Sergey's interactive shell has
        `ulimit -n 524288` so he never hit it; the systemd unit
        inherited the 1024 default. Fix: `nix/module.nix` sets
        `serviceConfig.LimitNOFILE = 524288;`. Symptom signature: a
        test that times out on `page.goto` while `curl localhost:port`
        from the same shell works fine — check
        `journalctl ... | grep "resource exhausted"`.

    87. **`deleteRecords` issues N round-trips, not a bulk DELETE**
        (Aug 12 2026) — IHP's `deleteRecords :: [record] -> IO ()`
        loops one SQL DELETE per record. For Sergey's 2h+ recordings
        (8k+ segment rows) that's 8k round-trips, each acquiring a
        pooled connection. Under load this contended with concurrent
        requests enough to slow the cameras-crud login lookup past its
        Playwright timeout. Bulk form for windows of N>100 rows:
        ```haskell
        _ <- sqlExec
          "DELETE FROM segments WHERE camera_id = ? AND end_ts > ? AND start_ts <= ?"
          (cameraUuid, from, to)
        ```
        Plain DELETE is DML — `sqlExec` works fine (the pitfall #42
        breakage is DDL-only). The trade-off: you lose IHP's
        per-record `beforeDelete`/`afterDelete` hooks, which we don't
        use anyway.

    88. **`Async.async` for destructive actions: capture `?modelContext`
        explicitly** (Aug 12 2026) — `PurgeRecordingAction` walks
        thousands of S3 keys; doing it in the request thread made the
        form POST "keep pending forever" (Sergey's words). Pattern for
        spawning the work into a background thread while keeping DB
        access:
        ```haskell
        let mc = ?modelContext
        _ <- liftIO $ Async.async $
          let ?modelContext = mc
           in purgeRecordingInBackground camera cid from to
        ```
        `ModelContext` is a connection pool — safe to share across
        threads. `?context` (ControllerContext) is request-scoped and
        must NOT be captured into a long-lived thread (it carries the
        current request's response handles). The async worker wraps
        its body in `E.handle (\(e :: SomeException) -> …)` so a
        transient S3 hiccup doesn't crash the leader; RetentionSweeper
        is the canonical convergence path for any leftover S3 state.

    89. **ORT `CreateSession` takes `OrtEnv*` as its FIRST arg** (Aug 12
        2026, Phase 3 slice 1) — signature is
        `CreateSession(env, model_path, options, out)`, NOT
        `(model_path, options, out)`. Omitting env segfaults inside
        `OrtApis::CreateSession` (interprets the path CString as an
        env pointer). Caught via gdb backtrace: versionString smoke
        test passed but CreateSession crashed. Debugging recipe:
        `nix shell nixpkgs#gdb --command gdb -batch -ex run -ex bt <bin>`.

    90. **ONNX Runtime vtable indices are version-locked** (Aug 12 2026)
        — `Hnvr.Cv.OnnxRuntime.Internal`'s `idx*` constants were
        generated by parsing `struct OrtApi` from
        `onnxruntime_c_api.h` of the PINNED nixpkgs onnxruntime
        (1.24.4, ORT_API_VERSION 24). ~415 entries, split-by-`;` then
        match `ORT_API2_STATUS/ORT_API_T/ORT_CLASS_RELEASE/(ORT_API_CALL*`.
        Bumping the nixpkgs onnxruntime version = regenerate indices
        FIRST (stale indices are silent memory corruption, not compile
        errors). The python one-liner is in git history (Phase 3
        slice 1 session). Note `GetVersionString`/`GetApi` live on
        `OrtApiBase` (indices 0/1 there), not the OrtApi vtable.

    91. **hnvr-cv smoke tests gate on `HNVR_ONNXRUNTIME_LIB`** (Aug 12
        2026) — absolute path to `libonnxruntime.so` (e.g.
        `/nix/store/…-onnxruntime-1.24.4/lib/libonnxruntime.so`). Same
        skip-silently pattern as `HNVR_TEST_INTEGRATION`. Same env var
        is read by `loadApi` at runtime, so dev/NixOS wiring just sets
        it to the nixpkgs package output. nixpkgs onnxruntime 1.24.4
        is CPU-only by default (`cudaSupport ? false`); the CUDA/TRT
        EP append path is written but untested until we override with
        `cudaSupport = true` — sessions fall through to CPU cleanly
        (verified in the smoke test's fallback assertion).

    92. **massiv `Ix3` is EXACTLY 3 dimensions** (Aug 12 2026, Phase 3
        slice 2) — the design doc's `Array S B (Ix3 1 3 320 320)` is
        aspirational; a 4-dim NCHW tensor needs `Ix4`. Indexing
        pattern for Ix4 is `0 :> c :> y :. x` — `:>` (from
        `IxN ((:>))`) prepends all but the last two dims, `:.` (from
        `Ix2 ((:.))`) terminates. `Sz4` used as a pattern needs
        `pattern Sz4` in the import list (+ PatternSynonyms pragma);
        `S` needs `S (S)`; `makeArray` results want a
        `:: Array D Ix4 Float` annotation or `computeAs` ambiguity
        bites. Sergey's model cache lives at
        `~/.local/share/hnvr/model_cache` (yolov7 `.trt` engines +
        facedet/paddleocr/license-plate ONNX — NO yolov8n-320 yet;
        reconcile at AnalyzerWorker slice).

    93. **ORT `CastTypeInfoToTensorInfo` output is NOT caller-owned**
        (Aug 12 2026, Phase 3 slice 5) — header says "Do not free this
        value, it will be valid until type_info is freed". Releasing
        it AND the OrtTypeInfo double-frees (`free(): double free
        detected in tcache 2` at process exit). Contrast with
        `GetTensorTypeAndShape` (on an OrtValue) whose output IS
        caller-owned. Read dims while the TypeInfo is alive, release
        only the TypeInfo.

    94. **cabal repl + dlopen = SIGABRT** (Aug 12 2026) — probing
        models via `cabal repl hnvr-cv` + `withSession` dies with
        exit code -6 (ghci dynamic-loading vs dlopen'd libonnxruntime).
        Compiled test binaries are fine. Model probing recipe: set
        `HNVR_ONNXRUNTIME_LIB` + `HNVR_TEST_MODEL` and run
        `cabal test hnvr-cv` — the gated AnalyzerSpec prints
        `HNVR_TEST_MODEL probe: input=… output=…` to stderr.

    95. **Model cache probed Aug 12 2026** — no YOLOv8-format model in
        `~/.local/share/hnvr/model_cache`:
        `facedet.onnx` = `[1,3,640,640] → [1,6400,1]`;
        `yolov9-256-license-plates.onnx` = `[1,3,256,256] → [-1,7]`
        (post-NMS). Pipeline integration test (`HNVR_TEST_MODEL`)
        needs a real `yolov8n-320.onnx` (`[1,3,320,320] → [1,84,2100]`)
        — pending Sergey's ultralytics export.

    96. **ORT C API argument-order traps** (Aug 12 2026) —
        `Run(…, output_names, output_names_len, outputs)`: the
        output_names_len comes BEFORE the outputs pointer (swapped =
        garbage span length → SIGSEGV inside `InferenceSession::Run`).
        And `CreateTensorWithDataAsOrtValue`'s `p_data_len` is BYTES,
        not elements ("not enough space: expected 1228800, got
        307200"). Both caught by the first real-model gated test.

    97. **ultralytics in the devShell (Aug 12 2026)** — top-level
        `pkgs.ultralytics` omits the optional ONNX export deps
        (`import onnx` fails mid-export). devenv wires
        `python3.withPackages [ultralytics onnx onnxslim]` (8.4.x
        uses onnxslim, not the old onnxsim). AGPL-3.0 — export tool
        only, never in NixOS closures. Multi-GB torch closure on
        first `nix develop`. Verified exports:
        ```bash
        yolo export model=yolov8n.pt format=onnx imgsz=320 opset=17 simplify=True dynamic=False
        yolo export model=yolov8s.pt format=onnx imgsz=640 opset=17 simplify=True dynamic=False
        ```
        installed at `~/.local/share/hnvr/model_cache/yolov8/
        {yolov8n-320,yolov8s-640}.onnx`. Probes: n-320 =
        `[1,3,320,320]→[1,84,2100]`, s-640 = `[1,3,640,640]→[1,84,8400]`.
        Real-frame validation: cam-197 sub-stream raw frame (720×480,
        `ffmpeg -pix_fmt rgb24 -f rawvideo`) through analyzeFrame →
        person detection at conf 0.10 (suppressed at default 0.35,
        visible via HNVR_TEST_FRAME=path:WxH gated probe). CPU
        inference ~80 ms/frame vs design's ~10 ms target — CPU EP on
        this box is slower than design's i7-12700 estimate; CUDA/TRT
        EP will matter.

    98. **`nixpkgs#attr` via registry ≠ flake's pinned
        `inputs.nixpkgs`** (Aug 12 2026) — the ORT vtable indices were
        first generated from the CHANNEL's onnxruntime 1.24.4 while
        the project's pinned nixpkgs ships 1.27.1. Caught when devenv
        wired `HNVR_ONNXRUNTIME_LIB = ${pkgs.onnxruntime}/…` and the
        versionString test reported 1.27.1. ORT's append-only ABI
        saved us: every index we use is identical across 1.24.4→1.27.1
        (verified by re-parsing the 1.27.1 header from the `-dev`
        store output — `/nix/store/*-onnxruntime-V-dev/include/
        onnxruntime/onnxruntime_c_api.h`). Rule: for anything the
        flake builds against, parse headers from
        `github:NixOS/nixpkgs/<flake.lock rev>#<pkg>.src` or the
        store `-dev` output, never the channel. `ortApiVersion` is
        now 27; the versionString test asserts only the "1." prefix
        (nixpkgs bumps minors regularly).

    99. **ORT output slots must be zeroed before `Run`** (Aug 12 2026,
        the 4-hour leader SIGSEGV hunt) — `alloca $ \outValOut`
        leaves stack garbage in the slot; ORT's contract is
        `output[i] == NULL` → ORT allocates the output OrtValue.
        Non-null garbage → ORT copy-constructs from a garbage
        `OrtValue*` → `mov (%r14),%rax` on packed-small-int junk
        (`0x6800000053`-style) inside `InferenceSession::Run`.
        **Symptom signature: passes all isolated stress tests (fresh
        native stacks read as zero), crashes in the long-lived leader
        (reused stacks carry non-null junk).** Fix: `poke outValOut
        nullPtr` before the Run call. Forensics path that worked:
        `coredumpctl debug <pid>` (systemd-coredump captures cores
        even for setsid'd processes) → faulting addr pattern → match
        the crashing loop to ORT source
        (`inference_session.cc` span-Run fetch loop). Also: ORT
        `CreateTensorWithDataAsOrtValue` DOES copy the shape dims
        (TensorShape ctor), and `VS.unsafeWith` liveness must wrap
        the whole create+Run, not just creation.

    100. **Shell traps that ate hours of debugging** (Aug 12 2026):
        - `pkill -f "bin/hnvr-leader"` matches the INVOKING SHELL's
          own `zsh -c` command line → kills your own command chain
          silently. Use `pkill -f "bin/hnvr-lead[e]r"`. Aug 13 2026
          addendum: the `[e]` trick does NOT save you if the same
          compound command ALSO contains the literal string
          `bin/hnvr-leader` (e.g. `pkill …; setsid ./result-web/bin/
          hnvr-leader …`) — the regex matches the restart half of
          your own cmdline. Run pkill in its own tool call, start in
          the next.
        - `grep -c pattern` exits 1 on zero matches → `cmd && grep -c
          x && next` silently skips `next`. Append `|| true` or use
          `if` guards.
        - `nix log` output has ANSI color codes → `grep "error"`
          misses colored diagnostics; errors mid-log (parallel cabal
          continues compiling other modules past a failure) — read
          the FULL log, not just the tail.
        - Backgrounding via `nix develop --command bash -c '… &'`
          gets reaped when the session exits; use `setsid … &
          disown`. And nix develop eval on a dirty tree now takes
          ~90 s — for rapid leader restarts, export the env vars
          directly (see /tmp/opencode/leader-env.sh pattern) and skip
          nix develop entirely.

    101. **ekg-core `Distribution` min/max are garbage under `-N`**
         (Aug 13 2026, Phase 3 EKG slice) — the store is 8 striped
         `Distrib`s keyed by capability; `read`/`sampleAll` folds them
         via `combine`, which copies `minPos`/`maxPos` from the LAST
         stripe unconditionally (untouched stripes stay 0.0). With
         `-N`, `_max` renders as 0.0 while count/sum are correct.
         `Hnvr.Core.Metrics.renderPrometheus` therefore emits only
         `_count` + `_sum` for distributions (avg latency =
         rate(sum)/rate(count) — the Prometheus-idiomatic shape).
         Also: ekg metric names are arbitrary Text — we embed
         Prometheus label sets directly in the name
         (`hnvr_frames_decoded_total{camera="floor_2_5"}`) and the
         renderer splits at the first `{` when adding suffixes.

    102. **Metrics endpoint is its own warp, NOT IHP middleware**
         (Aug 13 2026) — `Hnvr.Web.Metrics.startMetricsServer` runs on
         `HNVR_METRICS_PORT` (default 9100) in BOTH hnvr-leader and
         hnvr-node (node has no IHP chain to hang it on; also avoids
         the pitfall-#60 first-write-wins `option` trap). Dev port is
         9102 because devenv MinIO owns :9100 — devenv env block sets
         it. `CaptureConfig.capMetrics :: Hnvr.Core.Metrics.Metrics`
         (record of IO actions) is the seam: hnvr-capture/hnvr-cv
         stay ekg-free, hnvr-web backs the actions with an ekg-core
         `Store`. ekg-core errors on duplicate registration — the
         per-camera/per-EP metric caches in `Hnvr.Web.Metrics.newMetrics`
         are load-bearing, don't "simplify" them away.

## Sergey's working style

- Direct, no hand-holding. Be concise.
- Prefers GHC 9.12 + IHP even though bleeding edge — accept the jailbreak cost.
- Uses `~/bin/env-wrap` for commands requiring project flake.nix/.envrc.
- Calls himself "Sergey" — never "user".
- Wants to design for horizontal scale even when v1 doesn't need it (hence
  NATS from day one).

## Roadmap status (Aug 12 2026 — archive-browser audit-fix landed)

- [x] **Archive browser/manager** (Aug 11 2026, audit-fixed Aug 12 2026) —
      `/Archive`: filter by camera/time-window (24h cap)/min-duration/
      slug-search, segments grouped into recordings (30s gap tolerance)
      via pure `Hnvr.Core.Recording` + `Hnvr.Core.Playlist`
      (cabal-tested, pitfall #14 extraction pattern); windowed playlist
      (from/to, ≤6h per design 05, default = last 1h ending at latest
      segment) fixing the oldest-3600-segments bug; player deep-links
      `?from&to&t` with hls.js startPosition; admin-gated
      DeleteRecording (S3 best-effort + rows). Prereq fix:
      `toSegmentWritten` now takes the ms-precision upload key as a
      param — DB object_key no longer diverges from the uploaded object
      (pitfall #25 class). Auth gate now covers ArchiveController (was:
      presigned URLs served unauthenticated).
      **Aug 12 2026 audit-fix** (commit `8bd8d1f`): three Sergey-reported
      bugs closed:
        * pageSize 25 → 10 — single-camera 24h window previously fit on
          one page, so the "1/1" pagination badge looked broken with 12
          visible rows.
        * Filter params (cameraId/from/to/q/minDuration/page) now
          round-trip through `PurgeRecordingAction`'s redirect via
          `browseQueryString` — was redirecting to bare `/Archive`,
          landing the user on the default window which read as "the
          deleted row is still there".
        * S3 purge moved to `Async.async` — `purgeObjects` walks
          thousands of keys sequentially; the synchronous request
          "kept pending forever". Pattern documented in pitfall #88.
      Two URL/payload name clashes surfaced + fixed (pitfall #85):
      `PurgeRecordingAction {cameraId}` → `{purgeCameraId}` (collided
      with the filter cameraId); form body `from`/`to` → `purgeFrom`/
      `purgeTo` (collided with the filter from/to).
      Performance + ops hardening: bulk `DELETE FROM segments WHERE …`
      replaced `deleteRecords` (pitfall #87); `LimitNOFILE=524288`
      added to `nix/module.nix` (pitfall #86 — systemd default 1024
      was too low).
      Pure extraction: `Hnvr.Core.ArchiveBrowser` (paginate,
      resolveBrowseWindow, browseQueryString, parseWhen) — 21 unit +
      3 property tests in `Hnvr.Core.ArchiveBrowserSpec`. Cabal tests
      now 143 total (97 in hnvr-core).
      Playwright `archive-browser.spec.ts` extended to 14 specs (was
      7): pageSize hard cap, "Next →" link + badge text, filter
      preserved in form action URL, hidden-input name-prefix contract,
      full delete round-trip with filter preservation, page param
      preserved on page >1. Total Playwright: 20 specs (19 active +
      1 skip gated on >10 recordings).

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
            write via `Web.Controller.Support.Crypto` (renamed from
            `Hnvr.Web.Controller.*` in commit `ce739c1`, see pitfall #59);
            `UpdateCameraAction` skips re-encryption when the form's
            password field is blank (keep existing). Form labels updated
            to make this clear. Decrypt path (`decryptPassword`) is wired
            for `ProbeCameraAction` (deferred until rtsp_template
            rendering lands — currently rtsp_url already has creds
            embedded so Probe uses it directly).
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
- [~] **Phase 1 — Recording MVP.** Audit (Aug 11 2026,
      `.opencode/PHASE1_COMPLETION_MILESTONES.md`) found the previous
      "Phase 1 complete" claim overstated: no `CaptureSupervisor`
      existed, so nothing actually recorded in production. **M1 + M2
      landed Aug 11 2026** (this commit):
      - ✅ **M1 — CaptureSupervisor wiring.** New modules
            `Hnvr.Node.CaptureSupervisor` (per-worker async + stop TVar
            + idempotent start/stop/restart), `Hnvr.Web.CommandTypes`
            (`AssignPayload`/`ControlPayload` carrying full
            `CameraSnapshot` so receiving host spawns worker without
            extra round-trip), `Hnvr.Web.SnapshotResponder` (leader
            answers `hnvr.commands.snapshot.<host>` with current camera
            set; bridges the no-JetStream bootstrap problem),
            `Hnvr.Core.CameraSnapshot` (wire type for camera→worker
            config). `Bus.request`/`requestJson`/`reply` added to
            `Hnvr.Nats.Bus` (nats-queue has `Nats.request` but no
            timeout — wrapped with `System.Timeout.timeout`).
            `ConfigWatcher` now dispatches to CaptureSupervisor
            (start/stop/restart) instead of just logging.
            `AssignmentCoordinator.applyAssignment` projects Camera →
            CameraSnapshot via `projectCamera` and includes it in
            AssignPayload. NodeMain + LeaderMain (via Config.hs
            `startNodeRoles`) both spawn CaptureSupervisor, request
            initial snapshot from leader, and start workers for
            assigned cameras. Schema gained `rtsp_transport` column
            (default `'tcp'`) on `cameras` so the node knows whether
            to use `-rtsp_transport tcp` or `udp`.
      - ✅ **M2 — Versioned migrations via postgresql-simple-migration.**
            New module `Hnvr.Web.SchemaMigration` runs
            `MigrationInitialization` + `MigrationScript "0001-initial"`
            (embedded `Application/Schema.sql` via `file-embed`'s
            `embedFile`) inside a transaction at leader boot, BEFORE
            `IHP.Server.run`. Tracked in `schema_migrations` table so
            subsequent boots skip. `postgresql-simple-migration`
            jailbroken in `flake.nix` `hnvrHaskellOverlay` (0.1.15.0
            pins bytestring/text/time bounds that are stale on GHC
            9.12). `MigrationResult a` is parameterized by error type
            (`String` for init, `ByteString` for script) — `handleResult`
            is `Show a => String -> MigrationResult a -> IO ()`.
      - ✅ **M1+M2 integration test (verified Aug 11 2026):** all 3
            Sergey's cameras record continuously — 5633 segments in
            MinIO + matching rows in Postgres; mediamtx-as-single-
            puller architecture confirmed working (worker ffmpegs
            pull from rtsp://localhost:8554/<slug>, mediamtx holds
            single camera RTSP session, all 3 cameras' WHEP live
            view works concurrently with recording).
      - ✅ **M3-M7 (Aug 11 2026, post-M1 stability):**
          * M3 — `password_enc`/`password_nonce` decrypt path is now
            wired via `TestCryptoCameraAction` (POST endpoint + Show
            view "Test password decryption" button). Catches the
            silent HNVR_DATA_KEY rotation bug. Architectural reality:
            the mediamtx-as-single-puller change made the recording
            path's credential needs moot (worker pulls from local
            mediamtx, no creds), so password_enc stays as future-
            proofing for UI rotation/audit, not a hot-path concern.
          * M4 — sops-nix flake input uncommented, `nix/secrets.nix`
            module declares `services.hnvr.secrets.{enable,sopsFile,
            ageKeyFile}` + 8 sops.secrets.* entries. `nix/module.nix`
            preStart generates per-KEY systemd EnvironmentFile
            fragments from /run/secrets/* (sops writes one value per
            file; systemd wants KEY=value). Dev (devenv) unaffected —
            sops is opt-in via `services.hnvr.secrets.enable = true`.
          * M5 — `Hnvr.Capture.Ffmpeg.audioArgs` (the third ffmpeg per
            `03-capture-and-storage.md` §3). `Worker.runOnce` spawns
            it in parallel via `concurrently` when `ccRecordAudio=True`.
            Audio fragments use `.m4a` extension via new
            `formatSegmentObjectKeyMsExt` helper. NATS publish skipped
            for audio (no DB rows for v1; HLS audio group tagged for
            a future slice). Probe now does 2 ffprobe calls (v:0 + a:0)
            and populates `probeAudio`.
          * M6 — `Hnvr.Web.RetentionSweeper` hourly cron. Trust-the-DB
            sweep: queries `object_key` from `segments` past cutoff,
            deletes from S3 + Postgres in lockstep. Per-camera
            retention_days column drives the cutoff.
          * M7 — `Hnvr.Capture.SpoolDrainer` process-wide async
            started by CaptureSupervisor. 30 s drain interval, 60-
            file-per-camera cap (drops oldest), re-uploads spooled
            fragments to S3 when connectivity returns.
      - ✅ **M8 (Aug 11 2026):** doc cleanup — `design_docs/02-tech-stack.md`
            amazonka→minio-hs updated; HealthCache IORef-is-write-only
            Haddock corrected; migrations/0001-initial.sql gained the
            missing `segments_start_ts_brin` BRIN index from the design.
      - **Phase 1 — Recording MVP genuinely complete** (Aug 11 2026).
            M8 (doc cleanup) — see `.opencode/PHASE1_COMPLETION_MILESTONES.md`.
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
      - **Aug 10 2026 routing rename** (commits `ce739c1` + `87cd6c3`):
            controllers moved `Hnvr.Web.Controller.*` → `Web.Controller.*`
            and action constructors renamed to IHP-canonical per-resource
            form. See pitfall #59 for the IHP `actionPrefixText` gotcha.
            URL map now: `/` → dashboard (via `startPage DashboardAction`),
            `/Cameras` (list), `/ShowCamera?cameraId=…`, `/NewCamera`,
            `/EditCamera?cameraId=…`, `/CreateCamera`, `/UpdateCamera`,
            `/DeleteCamera`, `/ProbeCamera?cameraId=…`, `/AssignCamera`,
            `/PlayerArchive?cameraId=…`, `/PlaylistArchive?cameraId=…`,
            `/ShowLive?cameraId=…`, `/Hosts`, `/Dashboard`,
            `/NewSession`, `/CreateSession`, `/DeleteSession`. Views
            stayed under `Hnvr.Web.View.*` (only controllers moved).
      - **Aug 10 2026 Phase 2 blocker sweep** (closed 3 of 4 open items):
            * ✅ Taiga #467 closed — `MediaMTXConfigSyncer` migrated from
                  `/v2/config/paths/*` (gone in mediamtx v1.20) to
                  `/v3/config/paths/{list,add,patch,delete}`. See pitfall #61.
            * ✅ `/healthz` 404 fixed — root cause: two
                  `option $ CustomMiddleware` calls in `Config.hs` had only
                  the FIRST one active (IHP `option` is first-write-wins,
                  see pitfall #60). Fix: compose whep + healthz into one
                  `CustomMiddleware (whepMiddleware . healthzMiddleware)`.
            * ✅ WHEP `/whep/<slug>/session/<id>` path translation bug —
                  `WhepProxy.translatePath` was appending `/whep` at the
                  END instead of after the slug. Browser ICE-restart /
                  teardown (PATCH/DELETE on session URLs) now reaches
                  mediamtx correctly. See pitfall #62 for the middleware
                  composition order rule.
            * ✅ WHEP browser-tested end-to-end via curl probes (POST
                  `/whep/x` and PATCH `/whep/x/session/y` both reach
                  mediamtx; full SDP flow needs Sergey to verify in
                  Chrome against a live RTSP camera).
            Remaining: full Phase 2 demo (kill hnvr-1 → 15 s reassign)
            not yet exercised. AssignmentCoordinator load balancing
            still naive (lex-smallest host) — fine for 2 hosts.
- [x] **Test infrastructure (S1–S5 done Aug 11 2026)** — 94 Haskell
      tests + 6 Playwright specs + 1 NixOS VM smoke test. See
      "Test infrastructure (Aug 11 2026)" section above. The 5-sprint
      scope matches design_docs/10-test-plan.md v1.0 milestone exactly.
      Real bug found + fixed during S3: `WhepProxy.translateBack` was
      duplicating `/whep` in the middle of session URLs (latent
      throughout Phase 2 because pitfall #63 meant the WHEP JS never
      ran end-to-end). S6 (hnvr-cv tests) + S7 (hnvr-ptz tests) are
      gated on Phase 3 / Phase 5 implementation landing.
- [ ] **Phase 3 — CV detection + tracking. Slice 1 done (Aug 12 2026)**:
      `Hnvr.Cv.OnnxRuntime` + `Hnvr.Cv.OnnxRuntime.Internal` — internal
      FFI binding (dlopen + vtable, no Hackage dep) per locked design
      decision. `withSession` tries EPs in priority order
      (`SessionOptionsAppendExecutionProvider_{CUDA,TensorRT}_V2`), CPU
      fallback; `infer` wraps input in-place, copies output out. 2
      smoke tests env-gated on `HNVR_ONNXRUNTIME_LIB` pass against
      nixpkgs libonnxruntime 1.24.4 (CPU-only build). CI
      `cabal-test-non-web` now includes hnvr-cv. Open: no real model
      yet (yolov8n-320.onnx fetch/export is a later slice);
      cudaSupport override + TRT engine pre-build still pending.
      Next slices: Preprocess (massiv letterbox) → Decode/NMS →
      Tracker.Sort → AnalyzerWorker.
      **Slice 2 done (Aug 12 2026)**: `Hnvr.Core.Frame` (RGB24 storable
      frame type, producer/consumer seam between capture and cv) +
      `Hnvr.Cv.Preprocess` — `letterboxGeometry` (pure, property-pinned),
      `preprocessTo`/`preprocess` (bilinear letterbox → `Array S Ix4
      Float` 1×3×320×320, 114/255 pad), `toTensor` FFI adapter. 10 new
      tests (4 unit + 3 geometry + 3 properties — half-pixel rounding
      invariant + one-axis-fills + value range). hnvr-cv suite: 12
      tests total. Next slice: Decode (YOLOv8 [1,84,2100] anchor decode
      + per-class NMS, `nms . nms == nms` property per 09-testing.md).
      **Slice 3 done (Aug 12 2026)**: `Hnvr.Cv.Decode` — `decode`
      ([1,84,anchors] → `V.Vector Detection`, conf threshold + class
      whitelist, defaults 0.35 / [0,1,2,3,5,7] per design), `nms`
      (per-class, desc-score greedy, list-based — `V.groupBy` doesn't
      exist in boxed Data.Vector; suppression-stable so idempotence
      holds), `iou`, `unletterboxBox` (Letterbox → source pixels).
      15 new tests: golden [1,84,3] decode, IoU arithmetic, 5 NMS
      behavior pins, unletterbox golden, + 3 QuickCheck props
      (idempotence, subset, filter-respect). hnvr-cv suite: 27 total.
      **Slice 5 done (Aug 12 2026)**: `Hnvr.Cv.Analyzer` — per-camera
      pipeline kernel (`withAnalyzer` wraps `withSession`; `analyzeFrame`:
      preprocess → infer → decode+NMS → unletterbox → SORT update →
      confirmed tracks). `parseExecProviders` (strict Either;
      `trt` alias; loud on typos) + `execProvidersFromEnv` (defaults
      [CPU]). OnnxRuntime extended with shape introspection
      (`sessionInputShape`/`sessionOutputShape` via
      SessionGet{Input,Output}TypeInfo idx 33/34 + Cast 55 +
      ReleaseTypeInfo 98 — pitfall #93). Gated pipeline test on
      `HNVR_TEST_MODEL` (also doubles as a model-shape probe,
      pitfall #94/#95). hnvr-cv suite: 53 total.
      **Slice 6 done (Aug 12 2026)**: analysis frame path wired
      end-to-end. `Hnvr.Capture.Ffmpeg.analysisArgs` (sub-stream
      decode OR relay+scale=640:360 fallback per 03 §2b),
      `Hnvr.Capture.FrameSource` (ffmpeg → RGB24 slice → bounded
      TBQueue, drop-oldest — CV never backpressures the pipe;
      backoff-supervised `frameSourceLoop`), `Hnvr.Cv.AnalyzerRunner`
      (queue → analyzeFrame → sink, session reused across restarts).
      `CameraSnapshot` extended (+csRtspSubUrl/csUseSubstream/
      csSubWidth/csSubHeight/csAnalysisFps; projectCamera +
      SnapshotResponder SQL updated). `CaptureSupervisor` spawns the
      analysis pair per camera when `HNVR_MODEL_PATH` set and
      `HNVR_ANALYSIS_ENABLED != 0`; `latestAnalysis` exposes
      (frame, confirmed tracks) TVar for the /debug view. hnvr-web
      now deps on hnvr-cv — `nix build .#hnvr-web` green. devenv
      env: HNVR_ONNXRUNTIME_LIB (pinned store path), HNVR_MODEL_PATH
      (yolov8n-320), HNVR_EXEC_PROVIDERS="tensorrt,cuda,cpu".
      Pitfall #98: pinned-vs-channel onnxruntime (1.27.1 vs 1.24.4),
      indices verified identical, ortApiVersion now 27. Tests: 34
      capture + 97 core + 53 cv + 16 nats + 5 storage = 205 cabal.
      **Slice 8 done (Aug 13 2026)**: EKG metrics. `Hnvr.Core.Metrics`
      (Metrics record of IO actions + pure `renderPrometheus` —
      hnvr-capture/hnvr-cv stay ekg-free), `Hnvr.Web.Metrics`
      (ekg-core Store, per-camera/per-EP lazy metric caches, warp
      /metrics on HNVR_METRICS_PORT default 9100, nvidia-smi GPU
      gauge poller). `CaptureConfig.capMetrics` is the seam;
      `FrameSource.writeDropOldest` now returns STM Bool for the drop
      counter; `AnalyzerRunner` times `analyzeFrame` and records under
      the session's ACTUAL EP (`sessionActiveEp`). Metrics live:
      `hnvr_frames_decoded_total{camera}`, `hnvr_frames_dropped_total{camera}`,
      `hnvr_inference_seconds_{count,sum}{ep}`,
      `hnvr_substream_fallback_total{camera}`,
      `hnvr_gpu_memory_used_bytes`. Verified live on all 3 cams (ep
      label correctly reports cpu pre-CUDA-build). Pitfalls #101
      (ekg-core min/max broken under -N — renderer emits count/sum
      only) + #102 (metrics = own warp, not IHP middleware). hnvr-core
      103 tests, capture 35 — total 217 cabal.
      **Slice 9 done (Aug 13 2026)**: CUDA. flake.nix gains
      `cudaPkgs` (separate nixpkgs import: `cudaSupport=true`,
      `cudaCapabilities=["8.9"]`, `allowUnfree`) +
      `packages.onnxruntime-cuda` (1.27.1, `pythonSupport=false`;
      derivation verified: USE_CUDA=TRUE, CMAKE_CUDA_ARCHITECTURES=89).
      devenv HNVR_ONNXRUNTIME_LIB flipped to the CUDA build;
      enterShell prepends /run/opengl-driver/lib to LD_LIBRARY_PATH
      (libcuda.so.1 discovery). Build: `nix build .#onnxruntime-cuda`
      (~30 min on Sergey's box; pulls opencv into the dep chain).
      **Verified live**: leader on the CUDA lib reports
      `hnvr_inference_seconds{ep="cuda"}` — 3170 inferences in 3 min,
      ~9.2 ms/frame full pipeline (vs ~13.2 ms CPU), no crashes.
      Note: pinned nixpkgs builds no TensorRT EP — `tensorrt` in
      HNVR_EXEC_PROVIDERS falls through to cuda; TRT engine CI job
      still open. hnvr-1 (sm_61 Pascal) needs cudaPackages_12_8 —
      CUDA 12.9 dropped Pascal; wire with the NixOS module GPU slice.
      **Slice 7 done (Aug 12 2026)**: /debug view + the great SIGSEGV
      hunt. `Hnvr.Cv.DebugRender` (pure: palette box overlay +
      JuicyPixels PNG — MJPEG→PNG-multipart deviation documented;
      no JPEG encoder in JuicyPixels), `Hnvr.Web.DebugStream` WAI
      middleware (`/debug-stream/<uuid>` multipart stream, STM
      blocking on the analysis TVar), `Web.Controller.Debug` +
      `View.Debug.Show` (auth-gated HTML shell + track legend with
      matching CSS colors), `Hnvr.Web.SupervisorRegistry`
      (process-wide IORef; supervisor is created in an IHP
      initializer so `option` can't carry it). **Root-caused the
      leader crash: uninitialized ORT output slot** (pitfall #99) —
      alloca garbage read as non-null `OrtValue*` → ORT copy-ctor on
      garbage pointer. Also landed: input-vector liveness wrapping
      all of create+Run, SetIntraOpNumThreads=4 + DisableMemPattern +
      DisableCpuMemArena (multi-session hygiene), HNVR_ORT_DEBUG=1
      stderr tracing, HNVR_STRESS=1 gated stress test (2000-frame
      analyzeFrame loop with GC churn). Verified live: 3 cameras ×
      analysis, 4+ min stable (all prior crash points were 30–130s),
      debug streams for floor_2_5 (direct sub) + low_ent (relay
      fallback) both serve multipart PNG at 5fps. cv suite: 58.
      Remaining Phase 3: EKG metrics, TRT engine CI job, longer bake.
      Next slice: analysis ffmpeg (sub-stream → Frame TChan producer)
      + worker loop wiring into hnvr-capture/NodeMain.
      Next slice: Tracker.Sort (Kalman 6×4 + Hungarian,
      `hungarian-algorithm` pkg, determinism property).
      **Slice 4 done (Aug 12 2026)**: `Hnvr.Cv.Tracker.{Kalman,Hungarian,
      Sort}`. Design-doc corrections: **`hungarian-algorithm-1.0.0` does
      NOT exist on Hackage** — implemented Kuhn–Munkres in-tree
      (`Hungarian.hs`, e-maxx port over Data.Vector+ST, rectangular via
      dummy-cost square padding, deterministic tie-breaks); and massiv
      has no 4×4 inverse, so Kalman carries its own tiny dense-matrix
      ops (Gauss-Jordan partial pivot). Sort: predict → assign (1−IoU
      cost, gate 0.3) → update/birth/prune; defaults maxAge=30,
      minHits=3 per design. 17 new tests (6 Hungarian golden + 3 Kalman
      + 6 Sort + determinism & ID-stability props). hnvr-cv suite: 44
      total. Watch out: QuickCheck default size × O(n³) Hungarian =
      minutes — `resize 12` in the determinism prop.
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
5. `nix develop --no-pure-eval` (or direnv) to enter dev shell.
6. **Phase 1 + Phase 2 + test infrastructure (S1–S5) all done**.
   Next priorities (pick one):
   - **Phase 3 CV pipeline** — implement `Hnvr.Cv.OnnxRuntime` (FFI
     binding), `Preprocess`, `Decode`, `Tracker.Sort`. Then S6 test
     slice lands alongside per design_docs/10-test-plan.md.
   - **Two-node NixOS failover test** — reconfigure both VMs to peer
     with a shared NATS cluster so `hnvr.health.>` crosses VM
     boundaries (current worker VM uses its own localhost NATS per
     Phase 0 demo wiring). Then write `nixosTests.hnvr-failover`.
   - **Phase 6 operational hardening** — sops-nix secrets wiring,
     mediamtx auth, retention sweep.
