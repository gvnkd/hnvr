# HNVR — Test Plan

Concrete implementation plan companion to `09-testing.md`. Per-package
inventory, priority, schedule, and acceptance criteria. Anchored to the
phases in `08-roadmap.md`.

## Priority levels

- **P0** — ships in Sprint 1. Blocks the "tests are real" claim. Pure
  code with no external deps; highest value-per-LOC.
- **P1** — ships in Sprint 2. Closes the contract gaps (NATS, S3, PG,
  controllers). Needed before Phase 3 kicks off.
- **P2** — ships alongside Phase 3. Test infrastructure for the CV
  pipeline.
- **P3** — ships in Phase 6 (Operational Hardening). E2E, NixOS VM
  failover, Playwright UI.

## Per-package inventory

### hnvr-core (P0 — highest leverage)

Pure, no IO except `Crypto` (random nonce).

| Module | Test type | What to assert | Priority |
|--------|-----------|----------------|----------|
| `Hnvr.Core.Crypto` | unit + property | `encryptText k t >>= decryptText k == pure t`; auth-failure on byte flip; `initKey` rejects non-base64 / wrong length; `generateKey` output roundtrips through `initKey` | P0 |
| `Hnvr.Core.Time` | property | `formatSegmentObjectKeyMs` is injective for ms-distinct timestamps; `formatYmdHmsMs` zero-pads ms under 100; `formatSegmentDir` is a prefix of `formatSegmentObjectKey` for the same `(slug, ts)` | P0 |
| `Hnvr.Core.Geometry` | property | `Functor`/`Foldable`/`Traversable` laws for `Box a`; `V2` functor identity | P0 |
| `Hnvr.Core.Segment` | unit | `toSegmentWritten` projects every field correctly; `swObjectKey` matches `formatSegmentObjectKey (sSlug s) (sStart s)`; `swBytes == B.length (sBytes s)`; `ToJSON`/`FromJSON` roundtrip on `SegmentWritten` | P0 |
| `Hnvr.Core.Id` | unit | `Sha256` hex encoding helpers; `CameraId`/`HostId` `IsString`/`Show` instances behave | P0 |
| `Hnvr.Core.Logging` | — | skip; thin wrapper over `fast-logger` | — |
| `Hnvr.Core.Prelude` | — | skip; re-exports | — |

**Estimated effort:** 1.5 days. ~25 properties + 15 unit cases.

### hnvr-capture (P0/P1 mix)

The Fmp4 parser is documented as QuickCheck-testable in its own Haddock.
The Worker is integration territory.

| Module | Test type | What to assert | Priority |
|--------|-----------|----------------|----------|
| `Hnvr.Capture.Fmp4` | property (P0) | **chunk-boundary invariance**: feeding the same bytes in arbitrary chunkings yields the same `Fragment` sequence; `findTfdt` returns the first tfdt's `baseMediaDecodeTime` (both version 0 and 1); `parseBox` handles sizes 0, 1, and standard correctly | P0 |
| `Hnvr.Capture.Fmp4` | unit (P0) | `finish` flushes the open `MediaFragment`; `InitFragment` is emitted exactly once before the first `MediaFragment`; golden test against `tests/fixtures/fmp4/cam-197-init.mp4` + one real fragment | P0 |
| `Hnvr.Capture.Fmp4` | unit (P0) | Negative cases: truncated box header (fewer than 8 bytes), truncated 64-bit size, missing `tfdt` (returns 0), stray `mdat` before `moof` (absorbed into init) | P0 |
| `Hnvr.Capture.Ffmpeg` | golden (P1) | `recordingArgs` produces the documented arg list for TCP + UDP transports; pin to a snapshot | P1 |
| `Hnvr.Capture.Worker` | integration (P1) | `backoffDuration` table (2/4/8/16/30/30/...); `countRecent` keeps last 60 s; `transition` state machine covers every documented edge (Pending→Backoff, 5-in-60s→FailedPermanent, FailedPermanent cooldown→Pending, Stopped idempotent) | P1 |
| `Hnvr.Capture.Worker` | integration (P1) | Full loop against a real ffmpeg reading `tests/fixtures/fmp4/cam-197-init.mp4` on stdin via a fake RTSP (`ffmpeg -re -i fixture.mp4 -f rtsp rtsp://localhost:8554/test`) → assert fragments land in MinIO + `hnvr.events` is published | P1 |

**Estimated effort:** 3 days. Property suite for Fmp4 is the bulk.

### hnvr-nats (P1 — needs ephemeral NATS)

| Module | Test type | What to assert | Priority |
|--------|-----------|----------------|----------|
| `Hnvr.Nats.Subjects` | unit (P1) | Every subject matches its documented pattern (`hnvr.commands.assign.<cam>`, etc.); no two constructors collide on a prefix; `commandControl` joins 4 segments with `.`; round-trip parse from constructed subject back to args | P1 |
| `Hnvr.Nats.Bus` | integration (P1) | Spawn `nats-server` on a random port per test; assert `publishJson` + `subscribe` roundtrips a `SegmentWritten`; assert `Message` payload decode is total over malformed bytes | P1 |
| `Hnvr.Nats.Bus` | integration (P1) | Authenticated connection (`user:pass@host:port`) — matches pitfall #31 (no bare URI); assert `hostFromUri` rejects `nats://localhost:4222` | P1 |

**Estimated effort:** 1.5 days. Spawn-and-wait plumbing dominates.

### hnvr-storage (P1 — needs MinIO)

| Module | Test type | What to assert | Priority |
|--------|-----------|----------------|----------|
| `Hnvr.Storage.S3` | integration (P1) | Against devenv MinIO at `:9100`: `putObjectBytes` then `getObject` roundtrip; content-type preserved; `listObjects` returns uploaded keys in lexicographic order; `removeObject` is idempotent; `presignUrl` returns a URL that `wreq` GETs successfully | P1 |
| `Hnvr.Storage.S3` | integration (P1) | Error paths: bucket-not-found, connection refused, malformed endpoint | P1 |

**Estimated effort:** 1 day. MinIO fixture already in devenv.

### hnvr-cv (P2 — gated on Phase 3 implementation)

Currently all stubs. Tests land alongside the implementation per `08-roadmap.md` Phase 3.

| Module | Test type | What to assert | Priority |
|--------|-----------|----------------|----------|
| `Hnvr.Cv.OnnxRuntime` | integration (P2) | Smoke load YOLOv8n-320 ONNX on CPU EP; one-frame inference returns expected box count on a known input tensor; TensorRT + CUDA EP skip on hosts without GPU | P2 |
| `Hnvr.Cv.Preprocess` | property (P2) | Letterbox is invertible: `letterbox (320,320) img  →  unletterbox` recovers the original bbox coords (within rounding); normalize output range `[-1, 1]` | P2 |
| `Hnvr.Cv.Decode` | property (P2) | NMS idempotence; threshold filter strict; per-class NMS independent; golden test on a real YOLOv8 raw output tensor | P2 |
| `Hnvr.Cv.Tracker.Sort` | property (P2) | Determinism under `Data.Map` traversal reordering; birth-after-3-hits; death-after-30-misses; IoU Hungarian assignment matches brute-force on small inputs | P2 |
| `Hnvr.Cv.Rules` | property (P2 — Phase 4) | Cooldown enforcement; direction filter on line crossing; zone entry/exit fires exactly once per track transition | P2 |
| `Hnvr.Cv.AutoTrack` | integration (P2 — Phase 7) | PID closed-loop stability on a synthetic target trajectory; out of scope until v1.1 | P3 |

**Estimated effort:** 5 days, gated on Phase 3 implementation.

### hnvr-ptz (P2/P3 — gated on Phase 5)

| Module | Test type | What to assert | Priority |
|--------|-----------|----------------|----------|
| `Hnvr.Ptz.Driver` | unit (P2) | `Driver` typeclass laws — every instance has `moveAbsolute`/`moveRelative`/`preset` returning immediately | P2 |
| `Hnvr.Ptz.Onvif` | integration (P3) | Against a mock ONVIF server (Python `onvif-cli` or a small wai stub): `ContinuousMove`, `Stop`, `GotoPreset` produce well-formed SOAP envelopes; WS-Security header present | P3 |
| `Hnvr.Ptz.Controller` | property (P3) | PID controller converges; rate-limited commands don't exceed documented Hz; manual override cancels auto-track | P3 |

**Estimated effort:** 3 days, gated on Phase 5.

### hnvr-web (P1 for controllers, P3 for E2E)

| Module | Test type | What to assert | Priority |
|--------|-----------|----------------|----------|
| `Web.Controller.Sessions` | WAI unit (P1) | `POST /CreateSession` with valid creds → 302 to `/`; invalid creds → 302 to `/NewSession`; `DeleteSession` clears cookie; rate-limit kicks in after N attempts (when wired) | P1 |
| `Web.Controller.Cameras` | WAI unit (P1) | CRUD all routes require auth (redirect to `/NewSession`); `IndexAction` lists seeded cameras; `CreateCameraAction` encrypts password (assert `password_enc` non-null in DB); `UpdateCameraAction` with blank password keeps existing; `ProbeCameraAction` with a fixture ffprobe JSON returns parsed `ProbeInfo` | P1 |
| `Web.Controller.Cameras.Probe` | unit (P1) | `probe` parses all 4 ffprobe JSON fixtures (`cam-197-main.json`, `cam-197-sub.json`, `cam-196-main.json`, `cam-198-main.json`) into the expected `ProbeInfo`; rejects malformed JSON with a clear `Left` | P1 |
| `Web.Controller.Archive` | WAI unit (P1) | `PlaylistArchiveAction` returns a valid m3u8 with segments ordered by timestamp; `PlayerArchiveAction` returns 200 with the video element | P1 |
| `Web.Controller.Live` | WAI unit (P1) | `ShowLiveAction` returns 200 + the WHEP JS for a known camera slug | P1 |
| `Web.Controller.Dashboard`, `Hosts` | WAI unit (P1) | Auth-required; renders without exceptions with empty DB | P1 |
| `Hnvr.Web.Config` (CustomMiddleware) | WAI unit (P1) | `/healthz` returns 200 even when DB is unreachable; middleware composition order (`whep . healthz`) — assert whep runs first (pitfall #62) | P1 |
| `Hnvr.Web.Auth` | unit (P1) | `type instance CurrentUserRecord = User` is imported; `ensureIsUser` gates every controller (pitfall #50) | P1 |
| `Hnvr.Web.EventWriter` | integration (P1) | Subscribe to NATS, publish a `SegmentWritten` envelope, assert a row appears in `segments` table within 1 s; `ON CONFLICT DO NOTHING` deduplicates a replayed publish | P1 |
| `Hnvr.Web.HealthCache` | integration (P1) | Publish `hnvr.health.<host>` → row upserted in `hosts` table; stale (>15 s) host row marked unhealthy on next sweep | P1 |
| `Hnvr.Web.AssignmentCoordinator` | integration (P1) | 5 s poll picks lex-smallest healthy host; `manual_assign=true` never overridden; host-down → reassign within 15 s; `hnvr.commands.control.<old>.<cam>.stop` published on cross-host reassign (audit-fix Aug 10 2026) | P1 |
| `Hnvr.Web.ConfigBroadcaster` | integration (P1) | PG LISTEN `cameras_events` → republish on `hnvr.config.cameras.<slug>` with the row JSON | P1 |
| `Hnvr.Web.MediaMTXConfigSyncer` | integration (P1) | PG LISTEN → `/run/hnvr/mediamtx.yml` regenerated; per-path v3 API calls (`POST /v3/config/paths/add/<slug>`, `PATCH`, `DELETE`) issued to a mock HTTP server; idempotent on re-listen (pitfall #61) | P1 |
| `Hnvr.Web.WhepProxy` | WAI unit (P1) | Path translation `POST /whep/<slug>` → mediamtx; `PATCH /whep/<slug>/session/<id>` translates correctly (pitfall #62 Aug 10 2026 fix); Location header rewritten back; 404 for unknown slug | P1 |
| `Hnvr.Node.HealthReporter` | integration (P1) | Publishes `hnvr.health.<this_host>` every 5 s with monotonic timestamps | P1 |
| `Hnvr.Node.ConfigWatcher` | integration (P1) | Subscribes three subjects (`assign.>`, `control.<host>.>`, `config.cameras.>`); handler decodes + logs without throwing | P1 |
| Schema migrations (`Application/Schema.sql`) | integration (P1) | `tmp-postgres` per-test → run IHP migration → assert expected tables + columns exist; `users` seed row inserted on leader boot via `seedAdminUser` | P1 |

**Estimated effort:** 6 days for P1 (controllers + middleware + integration). WAI tests are the bulk.

### Cross-cutting

| Concern | Test type | Priority |
|---------|-----------|----------|
| `cabal.project` `allow-newer` set is current | CI job fails on bump | P1 |
| `flake.nix` `hnvrHaskellOverlay` jailbreaks match `cabal.project` | CI job (cabal-non-web vs nix-build diff) | P1 |
| Pre-commit hooks (`ormolu`, `cabal-fmt`, `nixpkgs-fmt`, `hlint`) | Already wired | done |
| `regen.sh` produces idempotent generated `gen/` tree | Shell test: `regen.sh && git diff --exit-code hnvr-web/gen/` | P1 |

## Playwright E2E suite (`tests/e2e/`) — P3

In-repo, Nix-managed via `pkgs.nodePackages` + `playwright-driver`.

| Spec | What it covers | Priority |
|------|----------------|----------|
| `login.spec.ts` | `/NewSession` → admin login → cookie set → redirect to `/`; logout clears cookie | P3 |
| `cameras-crud.spec.ts` | Add camera via UI → probe → assign → edit → delete; admin gate kicks non-logged-in | P3 |
| `archive-playback.spec.ts` | Open archive for a seeded camera; assert `<video>` element reaches `HAVE_METADATA`; hls.js triggers `MANIFEST_PARSED` | P3 |
| `live-view.spec.ts` | Open `/ShowLive?cameraId=…`; assert WHEP POST returns 201; `<video>` reaches `readyState >= 2`; covers pitfall #63 (inline JS now splices correctly) | P3 |
| `archive-browser.spec.ts` | `pageSize` hard cap, pagination badge + "Next →" link, filter-form round-trip, delete form action URL + hidden-input name-prefix contract, full delete round-trip preserves filter + page params | P3 (added Aug 12 2026) |
| `failover.spec.ts` | Two-node setup via devenv; kill node process; assert AssignmentCoordinator reassigns within 15 s; live view for reassigned camera recovers | P3 |

**Estimated effort:** 4 days. Includes Playwright project setup + Nix
wiring (`playwright-test` + browser binaries via `pkgs.playwright-driver`).

## NixOS VM test (`nixosTests.hnvr-failover`) — P3

Closes the open Phase 2 demo item from MEMORIES.md. Lives in `nix/vm-test.nix`.

```nix
# Sketch
{
  nodes = {
    leader = { ... }: {
      imports = [ nix/module.nix ];
      services.hnvr.leader.enable = true;
      virtualisation.memorySize = 2048;
    };
    worker = { ... }: {
      imports = [ nix/module.nix ];
      services.hnvr.node.enable = true;
      HNVR_HOST = "hnvr-1";
    };
  };

  testScript = ''
    leader.start()
    worker.start()
    leader.wait_for_unit("hnvr-leader.service")
    worker.wait_for_unit("hnvr-node.service")
    leader.wait_for_open_port(8000)
    leader.succeed("curl -sf http://localhost/healthz")
    # Kill the worker, assert reassign
    worker.crash()
    leader.wait_until_succeeds("curl -sf http://localhost/Hosts | grep -q 'reassigned'")
  '';
}
```

**Estimated effort:** 2 days. The two existing `nixosConfigurations`
already need fixes for `fileSystems` + `boot.loader.grub.devices`
assertions (per MEMORIES.md §55) — address that as a precondition.

## Sprint schedule

| Sprint | Window | Deliverables |
|--------|--------|--------------|
| S1 (P0) | Week 1 | `hnvr-core` test suite + `hnvr-capture` Fmp4 property suite + CI `cabal-test-non-web` job |
| S2 (P1) | Weeks 2–3 | `hnvr-nats`/`hnvr-storage`/`hnvr-capture.Worker` integration suites + `hnvr-web` WAI controller tests + CI `cabal-test-web` job + `tmp-postgres` per-test DB |
| S3 (P1 cont.) | Week 4 | Leader-side integration (`EventWriter`, `HealthCache`, `AssignmentCoordinator`, `MediaMTXConfigSyncer`, `WhepProxy`) against devenv services |
| S4 (P3 prep) | Week 5 | Playwright project scaffold + `login.spec.ts` + `cameras-crud.spec.ts`; CI `playwright-e2e` nightly job |
| S5 (P3 cont.) | Week 6 | `archive-playback.spec.ts` + `live-view.spec.ts` + `nixosTests.hnvr-failover` |
| S6+ (P2) | Parallel with Phase 3 | `hnvr-cv` test suite as each module lands (`OnnxRuntime` smoke, `Preprocess` property, `Decode` golden, `Tracker.Sort` property) |
| S7+ (P2/P3) | Parallel with Phase 5 | `hnvr-ptz` test suite |

S1–S3 are sequential (each unlocks the next). S4–S5 are independent of
S6+ — can run in parallel with Phase 3 work.

## Acceptance criteria

A test plan item is "done" when:

1. The `cabal test-suite` stanza compiles on `nix develop` and runs to
   green locally.
2. The corresponding CI job runs it on push (or nightly, per the matrix
   in `09-testing.md`).
3. Failure messages are actionable: property shrink sequences, HUnit
   `assertEqual` labels, or Playwright traces — not bare segfaults.
4. The test appears in the per-package `Main.hs` Tasty tree.
5. Any new fixture file is documented in this doc and committed under
   `tests/fixtures/`.

## Effort summary

| Sprint | Days |
|--------|------|
| S1 (P0) | 4.5 |
| S2 (P1) | 8.5 |
| S3 (P1) | 6 |
| S4 (P3 prep) | 4 |
| S5 (P3 cont.) | 4 |
| **v1.0 total** | **27** |
| S6+ (P2, with Phase 3) | 5 |
| S7+ (P3, with Phase 5) | 3 |
| **Grand total** | **35** |

27 dev-days gets the v1.0 test infrastructure (P0+P1+P3) in place; 8
more days track Phase 3 and Phase 5 deliveries.

## Sequencing rationale

- **Pure code first** — highest ROI, no infra, no flakiness. The Fmp4
  parser is explicitly called out in its Haddock as QuickCheck-friendly;
  delivering it first proves the framework choice.
- **`hnvr-web` WAI tests before integration** — controllers are the
  contract surface; bugs caught here don't reach devenv.
- **Playwright after WAI tests** — UI tests are slow and flaky; keep
  them out of the fast lane. They're a complement, not a replacement.
- **NixOS VM test last** — most expensive to maintain; only justified
  once the AssignmentCoordinator's reassign logic has settled (it has —
  Aug 10 2026 audit-fix).

## What we explicitly defer

- **Performance / load tests** — separate doc when Phase 6 demands it.
- **Chaos testing** (network partition between hosts, NATS split-brain) —
  Phase 6 or post-v1.
- **Fuzz testing of the Fmp4 parser against arbitrary bytestrings** —
  QuickCheck's arbitrary `ByteString` already covers this; a dedicated
  AFL/libFuzzer harness is overkill until a real-world bug surfaces.
- **Visual regression** — out of scope per `09-testing.md` non-goals.
