# HNVR Phase 0–2 Audit Report

**Date:** Aug 10 2026
**Auditor:** Rune (sub-agent driven)
**Repo state:** `master` @ `24e77f0`, working tree clean, in sync with `origin/master`
**Method:** Three sub-agents gathered (1) the spec from `design_docs/00-08`, (2) the actual code state across all 7 packages + nix modules, (3) git/CI/flake state. Findings below were then verified against primary sources via direct file reads.

---

## 0. Executive summary

The MEMORIES.md claim of **"Phase 0 + 1 + 2 done (code)"** is **mostly accurate at the demo-flow level** — the recording pipeline (ffmpeg → fMP4 → S3 → NATS → Postgres → HLS archive) and live-view+multi-host spine (HealthReporter → HealthCache → AssignmentCoordinator → ConfigWatcher, MediaMTX YAML sync + WHEP proxy) are real, compile-clean code that match the design.

**However, audit found 13 concrete gaps where the implementation deviates from or omits Phase 0–2 spec.** Two are functional bugs, three are spec-mandated subjects/channels that exist only as type signatures, four are dev/CI tooling omissions explicitly listed in the roadmap, and four are acknowledged-but-undocumented stubs that the codebase presents as complete.

| Severity | Count | Examples |
|---|---:|---|
| 🔴 Critical (broken or spec-violating, blocks Phase 2 demo) | 3 | `sEnd=sStart` zero-duration segments; no `hnvr.commands.control` publish/subscribe; no `hnvr.config.>` broadcast |
| 🟡 Major (spec-omitted, works today but design-defying) | 4 | No cabal-fmt hook; no mediamtx in devShell; CI omits `cabal build all` + GHC matrix; no graceful-drain `stop` on reassignment |
| 🟢 Minor (acknowledged stub, deferrable) | 4 | HealthReporter payload stubs; EventWriter ON CONFLICT; MediaMTXConfigSyncer reconnect; sub-stream probe button |
| ⚪ Documented deviation (skip-and-recorded) | 2 | nginx-for-WHEP skipped (WAI middleware replaces it); mediamtx 1.18.2 instead of 1.20.0 (pending Slice 3 verification) |

---

## 1. Phase-by-phase verification

### Phase 0 — Bootstrap ✅ (with 2 minor deviations)

| Spec requirement | Status | Evidence |
|---|---|---|
| IHP pinned to GHC 9.12-capable commit | ✅ | `flake.nix:16-19` pins `ihp/v1.6.0`; IHP overlay exposes `ghc912` |
| GHC 9.12 jailbreak overlay | ✅ | `ihp.overlays.default` + `hnvrHaskellOverlay` (`flake.nix:40-75`) |
| `nix/module.nix` (leader service) | ✅ | `nix/module.nix` 115 LOC, systemd hardening, `preStart` session secret |
| `nix/nats-server.nix` (single-node, JetStream) | ✅ | `nix/nats-server.nix` 102 LOC; JetStream enabled |
| `hnvr-nats`: pub/sub + JSON codecs | ✅ | `Hnvr.Nats.Bus` + `Hnvr.Nats.Subjects` |
| `hnvr-nats`: **JetStream helpers** | ⚠️ **DEFERRED** | Header comment in `Bus.hs` says "JetStream explicitly deferred". Spec calls for it in Phase 0 (`00-overview.md` calls NATS "JetStream spine"). |
| `hnvr-nats`: connection pool | ⚠️ **PARTIAL** | Single `Bus` handle wraps one connection; no pool. Acceptable for v1 but not what spec says. |
| `/healthz` endpoint | ✅ | `Hnvr.Web.Config` `healthzMiddleware` |
| `nixosConfigurations.hnvr-1-vm` + `hnvr-2-vm` | ✅ | `flake.nix:269-278` |
| **`devShell.nix` contains mediamtx** (`08-roadmap.md:15`) | ❌ **MISSING** | `flake.nix:215-238` devShell has ffmpeg/onnxruntime/nats-server but **no mediamtx** |
| **CI: `nix flake check` + `cabal build all` with GHC 9.10 + 9.12 matrix** (`08-roadmap.md:17`) | ❌ **MISSING** | `.github/workflows/ci.yml` runs only `nix flake check --no-build` + `nix build .#hnvr-web .#hnvr-nats`. No cabal, no matrix. Inline comment justifies the cabal skip for `hnvr-web` only; the 6 non-web packages are buildable via cabal. |
| **`cabal-fmt` pre-commit hook** (`02-tech-stack.md:160`) | ❌ **MISSING** | `flake.nix:189-207` enables ormolu, hlint, nixpkgs-fmt, eof/whitespace fixers — no cabal-fmt hook. `cabal-fmt` is present in devShell but not run automatically. |

### Phase 1 — Recording MVP ✅ (with 2 functional caveats)

| Spec requirement | Status | Evidence |
|---|---|---|
| `hnvr-core`: `CameraId`/`Box`/`Sha256`/`HostId`/UTCTime helpers/structured logging | ✅ | All present in `hnvr-core/src/Hnvr/Core/{Id,Geometry,Time,Logging}.hs` |
| Structured logging usable at call sites | ⚠️ **PARTIAL** | `Logging.hs` is typeclass-only (`Logger m`); no concrete instance, no call site uses it. `Worker.hs:312-314` rolls its own `hPutStrLn stderr` loggers. |
| `hnvr-storage` SeaweedFS via **amazonka-s3 path-style** | ⚠️ **DEViates** | Uses `minio-hs` instead (pitfall #28). Pitfall #28 in MEMORIES.md says design doc `02-tech-stack.md` is "superseded" — but **design doc 02 has not been updated** to reflect the substitution. |
| fMP4 fragmenter ~80 LOC parser | ✅ | `Hnvr.Capture.Fmp4` 152 LOC Mealy machine |
| `CaptureWorker` state machine | ✅ | `Hnvr.Capture.Worker` 314 LOC, all 5 states (`Pending`/`Running`/`Backoff n`/`FailedPermanent`/`Stopped`), backoff 2/4/8/16/30, 5-in-60s → FailedPermanent |
| **`sEnd` populated from tfdt box** (`03-capture-and-storage.md`) | ❌ **STUB** | `Worker.hs:279`: `sEnd = ts, -- Slice 3 doesn't parse tfdt yet`. Every `SegmentWritten` event publishes `end_ts == start_ts`. **See §2.1.** |
| ffmpeg invocation flags | ✅ | `Hnvr.Capture.Ffmpeg.recordingArgs` matches the design flag list |
| SeaweedFS PutObject + metadata headers | ✅ | `Hnvr.Capture.Worker.putObjectBytes` |
| Object key format `cam-196/YYYY-MM-DD/HH/MM-SS.mmm.mp4` (ms precision) | ✅ | `Hnvr.Core.Time.formatSegmentObjectKeyMs` (pitfall #25 baked in) |
| NATS publish `hnvr.events` `SegmentWritten` | ✅ | `Worker.hs:269-285` |
| EventWriter consumes `hnvr.events` → inserts `segments` row | ✅ | `Hnvr.Web.EventWriter` 97 LOC |
| **Idempotent insert (ON CONFLICT)** | ⚠️ **MISSING** | `EventWriter.hs:76-79` comment: "Idempotency relies on the @UNIQUE (camera_id, start_ts)@ constraint ... we'd need raw SQL [for ON CONFLICT] (deferred)". Current path catches the PG unique-violation error and swallows it — works, but noisy in logs and double-publishes still cause a round-trip. |
| `cameras` table (full column list per `03-capture-and-storage.md`) | ✅ | `Schema.sql:24-50` covers all spec columns incl. `password_enc`/`password_nonce`/`manual_assign` |
| `segments` table + both indexes | ✅ | `Schema.sql:53-67` declares both `segments_cam_start_idx` and a `UNIQUE (camera_id, start_ts)` |
| Cameras CRUD (admin only) | ⚠️ **PARTIAL** | `Hnvr.Web.Controller.Cameras` implements all 9 actions; **no admin/auth check** — any visitor can create/edit/delete cameras. Spec says "admin only" (`03-capture-and-storage.md`). |
| **Probe sub-stream button fills sub-stream dims + codec** | ⚠️ **PARTIAL** | `Controller/Cameras/Probe.hs` probes one URL only (the form's `rtsp_url`); `probeAudio` is hardcoded to return `Nothing` (`Probe.hs:98`). Sub-stream dims/codec are not auto-filledable from the UI; user must type them. |
| `<video>` + `hls.js` archive player | ✅ | `View/Archive/Player.hs` 47 LOC; hls.js loaded from CDN |
| m3u8 generation with presigned S3 GETs | ✅ | `Controller/Archive.hs:72-89` |
| `Hnvr.Core.Crypto` AES-256-GCM | ✅ | `Hnvr.Core.Crypto` 110 LOC + round-trip CLI `hnvr-crypto-test` |
| sops-nix wiring (`hnvr-data-key`, S3, PG) | ⚠️ **TEMPLATE ONLY** | `nix/secrets-template.yaml` 37 LOC is placeholder text. `flake.nix:27` has the `sops-nix` input **commented out**. Slice 7a delivered crypto + template; sops-nix activation is implicitly Phase 6 — but the spec table at the top of `02-tech-stack.md` lists sops-nix as a v1 dependency. |

### Phase 2 — Live View + Multi-Host ⚠️ (3 critical spec gaps)

| Spec requirement | Status | Evidence |
|---|---|---|
| `systemd.services.mediamtx` (leader only) | ✅ | `nix/mediamtx.nix` 116 LOC; `flake.nix:123` enables only on leader VM |
| mediamtx pinned to v1.20.0 | ⚪ Deviation | nixpkgs `1.18.2` used instead. Documented in `flake.nix:21-25` as conditional fallback. **Pending Slice 3 WHEP verification** (see §3 open items). |
| `MediaMTXConfigSyncer` (LISTEN `cameras_events`, render YAML, SIGHUP) | ✅ (partial) | `Hnvr.Web.MediaMTXConfigSyncer` 246 LOC. Uses REST `PUT /v2/config/paths/<slug>` instead of SIGHUP (pitfall #45 justifies). Reconnect logic is the only stub (line 125). |
| `/live/<slug>` view + WHEP client JS | ✅ | `Controller/Live.hs` + `View/Live/Show.hs` (inline ~40 LOC WHEP client). Spec wanted `/static/whep.js`; inlined instead. |
| `/whep/<slug>` reverse proxy | ✅ | `Hnvr.Web.WhepProxy` 132 LOC WAI middleware |
| **nginx config for WHEP** (`08-roadmap.md:58`, `05-web-and-live-view.md:251`) | ⚪ Skipped | MEMORIES.md:540 explicitly skips ("WAI middleware handles it. nginx can land in Phase 6"). |
| **`AssignmentCoordinator` publishes `hnvr.commands.control.<old_host>.<cam>.stop` on reassignment** (`03-capture-and-storage.md:281`) | ❌ **MISSING** | `AssignmentCoordinator.hs:122` publishes only `commandAssign slug`. Old host never gets a stop directive — graceful drain step (#6 of the reassignment sequence in design doc) is omitted. **See §2.4.** |
| **`ConfigWatcher` subscribes `hnvr.config.>`** (`08-roadmap.md:62`) | ❌ **MISSING** | `ConfigWatcher.hs:51` subscribes `hnvr.commands.assign.>` instead. The `hnvr.config.>` subject is **never published or subscribed anywhere in the codebase** (grep confirmed). Header comment in `NodeMain.hs:11` claims `hnvr.config.>` subscription but the actual code does not. **See §2.3.** |
| **`ConfigBroadcaster` publishes `hnvr.config.cameras.<slug>` on row change** (`05-web-and-live-view.md:348`) | ❌ **MISSING** | No such module exists. `Subjects.configCameras` and `configRules` are exported but never used. |
| **`hnvr.commands.control.<host>.<cam>.<action>` channel** (`01-architecture.md:68`, `05-web-and-live-view.md:338`, `08-roadmap.md:61`) | ❌ **DEAD** | Defined in `Subjects.hs:36-38`. Never published, never subscribed. `ConfigWatcher.hs:11` header comment claims it "also subscribes `hnvr.commands.control.<host>.<cam>.<action>`" but the implementation never does. **See §2.2.** |
| `HealthReporter` publishes `hnvr.health.<host>` every 5s | ✅ | `Hnvr.Node.HealthReporter` 86 LOC. Payload fields are stubs (`hCameras=[]`, `hCpuPct=0`, `hGpuModel="stub"`, zeros elsewhere) — Phase 3+/6 fills them. |
| `HealthCache` consumes `hnvr.health.>` → IORef + UPSERT `hosts` | ✅ | `Hnvr.Web.HealthCache` 105 LOC |
| `AssignmentCoordinator` 5s poll, 15s host-down timeout | ✅ | `Hnvr.Web.AssignmentCoordinator` 155 LOC |
| `manual_assign=true` cameras never overridden | ✅ | `AssignmentCoordinator` filters by `manual_assign = FALSE` |
| Camera assignment UI: `POST /cameras/:id/assign` | ✅ | `Controller/Cameras.hs` AssignAction + `View/Cameras/Show.hs` form |
| Dashboard with camera grid + per-host panel | ✅ | `Controller/Dashboard.hs` + `View/Dashboard/Index.hs` |
| `/hosts` per-host view | ✅ | `Controller/Hosts.hs` + `View/Hosts/Index.hs` |
| Load-aware assignment (lex-smallest is naive) | ⚪ Deferred | MEMORIES.md:544 documents this; fine for 2 hosts. |

---

## 2. Critical gaps (detailed)

### 2.1 🔴 `sEnd = sStart` — every published segment has zero duration

**File:** `hnvr-capture/src/Hnvr/Capture/Worker.hs:279`

```haskell
let seg =
      Segment
        { sCamera = ccId cam,
          sSlug = ccSlug cam,
          sStart = ts,
          sEnd = ts, -- Slice 3 doesn't parse tfdt yet; refined in Slice 4
          ...
```

**Impact:**
- Every row in `segments` table has `end_ts == start_ts` (zero duration).
- `Hnvr.Web.Controller.Archive.buildPlaylist` (`Archive.hs:93`) sidesteps this by **hardcoding `#EXTINF:1.0`** for every segment regardless of true duration, so playback *appears* to work — but only because Sergey's cameras happen to emit fragments at ~1s wall-clock intervals.
- For HEVC cameras like `cam-196` (pitfall #25: "HEVC cameras emit 2+ fMP4 fragments per wall-clock second"), the player will advance 1s of timeline per fragment when the actual media is ~0.5s, causing audio/video desync after a few minutes and a stale playback window (1 hour of segments = 30 min of real video).
- Retention sweeps (Phase 6), bytes/sec metrics, "is this segment still recording" health checks will all compute against zero-length intervals.
- The `Slice 4` promise in the comment was never delivered — Phase 1 shipped Slice 4c (Cameras CRUD) without revisiting tfdt parsing.

**Fix:** Parse `tfdt` box in `Hnvr.Capture.Fmp4` to expose `baseMediaDecodeTime`, subtract from the next fragment's `tfdt` to compute duration, thread through to `sEnd`. The Mealy machine already touches `moof`/`mdat`; adding `tfdt` is ~10 LOC.

### 2.2 🔴 `hnvr.commands.control.<host>.<cam>.<action>` channel is dead

**Files:**
- Defined: `hnvr-nats/src/Hnvr/Nats/Subjects.hs:36-38`
- Claimed-subscribed: `hnvr-web/src/Hnvr/Node/ConfigWatcher.hs:11` (header comment only)
- Referenced in 3 design docs: `01-architecture.md:68`, `05-web-and-live-view.md:338`, `03-capture-and-storage.md:281`

Grep across the repo: **0 publishers, 0 subscribers** of this subject pattern. Only the type-signature helper exists, plus a stale doc comment in `ConfigWatcher` that lies about subscribing to it.

**Impact:**
- The "Force-restart worker button" UX described in `05-web-and-live-view.md:338` cannot function — there's no producer.
- The graceful drain sequence in `03-capture-and-storage.md:281` ("Old host ... gets `hnvr.commands.control.<old_host>.<cam>.stop`, drains gracefully") cannot fire — no producer.
- Once Phase 3 lands `CaptureSupervisor`, it would have no channel to receive start/stop/restart directives from.

**Fix:** Either (a) wire the producer (AssignmentCoordinator publishes `stop` to old host + `start` to new host on every reassignment; Cameras Show view publishes `restart`), plus the subscriber (ConfigWatcher fans out by `<host>` match); or (b) explicitly remove the type signature and update the design docs to mark this Phase 3+.

### 2.3 🔴 `hnvr.config.>` broadcast never happens

**Files:**
- Defined: `Subjects.hs:49-54` (`configCameras`, `configRules`)
- Specified: `08-roadmap.md:62` ("`ConfigWatcher` per host subscribes `hnvr.config.>`"), `01-architecture.md:42` (ConfigWatcher "subscribes hnvr.config.> ; updates IORef (Map CameraId Camera)"), `05-web-and-live-view.md:348` ("`ConfigBroadcaster`: publishes `hnvr.config.cameras.<slug>` JSON to NATS")

Grep: **0 publishers, 0 subscribers** of `hnvr.config.*`. ConfigWatcher subscribes `hnvr.commands.assign.>` instead, which is a different channel (one-shot reassignment vs. broadcast-on-row-change).

**Impact:**
- Phase 3+ CV pipeline (which per `01-architecture.md:42` reads its `IORef (Map CameraId Camera)` from this subject) will have no producer to populate it. The whole "config broadcast on row change" mechanism that the architecture doc centers on is unimplemented.
- Live reassignment currently works only because `AssignmentCoordinator` publishes to `hnvr.commands.assign.<slug>` and the node's `ConfigWatcher` happens to subscribe that; once the CaptureWorker actually does something on a config change (Phase 3), the missing broadcast becomes a live bug.
- Stale comment in `NodeMain.hs:11` ("ConfigWatcher subscribes `hnvr.config.>`") is misleading.

**Fix:** Either (a) implement `Hnvr.Web.ConfigBroadcaster` that LISTENs on both `cameras_events` and a future `rules_events` and publishes the row JSON to `configCameras`/`configRules`, then make ConfigWatcher fan-subscribe to both `hnvr.commands.assign.>` and `hnvr.config.>`; or (b) drop the spec requirement and update the docs.

### 2.4 🟡 No graceful drain on reassignment

**Files:** `hnvr-web/src/Hnvr/Web/AssignmentCoordinator.hs:115-122`

The reassignment path (`reassign` function) does:
1. UPDATE `cameras.assigned_host`
2. publish `commandAssign slug`

It does **not**:
3. publish `commandControl oldHost slug "stop"` to the old host

Per `03-capture-and-storage.md:281` the spec sequence explicitly calls for step 3. Even though Phase 3 will be the first phase where `stop` actually does anything, omitting the publish now means the channel is un-tested when Phase 3 needs it.

**Fix:** One-line addition in `reassign` when the camera's previous `assigned_host` was non-null and differs from `newHost`.

---

## 3. Tooling & CI gaps (Phase 0 spec, never closed)

### 3.1 🟡 `cabal-fmt` not in pre-commit hooks

**Spec:** `02-tech-stack.md:160` lists `cabal-fmt` alongside ormolu/hlint/nixpkgs-fmt.
**Reality:** `flake.nix:189-207` `hooks` block enables ormolu, hlint, nixpkgs-fmt, eof/whitespace fixers. `cabal-fmt` is in `devShells.default.buildInputs` (`flake.nix:222`) so it's manually runnable but not enforced.
**Impact:** `.cabal` files drift (field ordering, indentation); 8 cabal files in the repo are unchecked.
**Fix:** Add `cabal-fmt.enable = true;` (and `excludes = [ "^vendored/" ];`) to `hooks`.

### 3.2 🟡 `mediamtx` not in devShell

**Spec:** `08-roadmap.md:15` ("devShell.nix with cabal, ghcid, ormolu, hlint, nats-server, **mediamtx**").
**Reality:** `flake.nix:215-238` devShell has ffmpeg, onnxruntime, nats-server but **no mediamtx**. Developer cannot test WHEP end-to-end locally without installing it manually.
**Fix:** Add `pkgs.mediamtx` to `devShells.default.buildInputs`.

### 3.3 🟡 CI omits `cabal build all` + GHC 9.10 sanity matrix

**Spec:** `08-roadmap.md:17` ("CI: `nix flake check` + `cabal build all` on push (matrix GHC 9.10 sanity + 9.12 target)").
**Reality:** `.github/workflows/ci.yml` runs only `nix flake check --no-build`, `nix build .#hnvr-web`, `nix build .#hnvr-nats`. No cabal, no matrix.
**Impact:**
- The 6 non-web packages (core, nats, storage, capture, cv, ptz) are not CI-validated via cabal — only via the indirect nix build of `hnvr-web` (which depends on them transitively). A cabal-only build regression would go unnoticed.
- No 9.10 sanity check means a regression that breaks older GHC lands silently. Spec called for this as a belt-and-suspenders.
**Fix:** Add a CI job that runs `cabal build all --ghc-options=-Werror` for the 6 non-web packages (skip `hnvr-web` per pitfall #14), and optionally a 9.10 matrix entry.

---

## 4. Acknowledged stubs that should be tracked

These are present-but-stub implementations explicitly commented in code. They are not spec violations per se (most are correctly deferred to later phases) but they're listed here because MEMORIES.md describes the phases containing them as "done", which overstates completion.

| Module / function | Stub | Phase it's needed |
|---|---|---|
| `Hnvr.Node.HealthReporter` payload | `hCameras=[]`, `hCpuPct=0`, `hGpuModel="stub"`, all metrics zero | Phase 3 (cameras list), Phase 6 (CPU/GPU/mem EKG) |
| `Hnvr.Node.ConfigWatcher.handleAssign` | Logs only — no `CaptureSupervisor` dispatch | Phase 3 (when worker embeds in node process) |
| `Hnvr.Web.EventWriter` ON CONFLICT | Catches unique-violation error | Phase 6 (idempotent ingest) |
| `Hnvr.Web.MediaMTXConfigSyncer` reconnect | First-failure dies (line 125) | Phase 6 (operational hardening) |
| `Hnvr.Web.Controller.Cameras.Probe.probeAudio` | Hardcoded `Nothing` | Phase 4 if audio events matter |
| `Hnvr.Capture.Worker` SpoolDrainer | Spool write works, drain-on-reconnect not wired | Phase 6 |
| `Hnvr.Core.Logging` | Typeclass only, no concrete logger | Phase 6 |
| Cameras CRUD admin gate | None | Phase 6 (auth) |

---

## 5. Tests

**Spec:** Implicit. `03-capture-and-storage.md` references "trivial to test with QuickCheck" for `Fmp4`, but does not make tests a deliverable for Phase 0–2.

**Reality:** Zero `test-suite` stanzas across all 7 first-party packages. The only test artifacts are:
- `hnvr-core/app/CryptoTest.hs` — CLI round-trip smoke binary, not a unit test.
- `vendored/nats-queue/test/*` — 3rd-party hspec, disabled in flake (`dontCheck`).

**Recommendation:** Phase 2 close-out should land at minimum `tasty` or `hspec` suites for the pure modules (`Hnvr.Capture.Fmp4` Mealy machine, `Hnvr.Core.Time` key formatters, `Hnvr.Core.Crypto` round-trip). The fMP4 box parser especially — it's the most stateful pure code in the project and the locus of the `sEnd=sStart` bug.

---

## 6. Open items MEMORIES.md admits to

These are documented as Phase 2 open items in `MEMORIES.md:542-545` and re-confirmed by audit:

1. **WHEP not yet browser-tested** — the inline ~40 LOC WHEP client has never been exercised against Chrome 130+. Phase 2 acceptance demo ("live view keeps working") cannot be claimed until verified.
2. **mediamtx REST push untested** — `MediaMTXConfigSyncer` writes `/run/hnvr/mediamtx.yml` and issues `PUT /v2/config/paths/<slug>` but no live mediamtx has been driven by it.
3. **AssignmentCoordinator load balancing is naive** — lex-smallest host, fine for 2 hosts.
4. **mediamtx version skew** — design locks 1.20.0, code uses 1.18.2; bump is conditional on Slice 3 verification (which is itself open).

---

## 7. Documentation drift

- **`design_docs/02-tech-stack.md`** still says amazonka-s3; reality is minio-hs (pitfall #28). The design doc should be amended or marked superseded.
- **`NodeMain.hs:11`** comment claims `ConfigWatcher` subscribes `hnvr.config.>`; it actually subscribes `hnvr.commands.assign.>`.
- **`ConfigWatcher.hs:11`** comment claims it also subscribes `hnvr.commands.control.<host>.<cam>.<action>`; it does not.
- **`flake.nix:92`** comment ("hnvr-node has no NATS client yet (Phase 2)") is stale — node IS wired now.
- **MEMORIES.md** Phase 2 summary omits the `sEnd=sStart` Slice 3 sub-stub and the missing `hnvr.commands.control` / `hnvr.config.>` channels from its "open items" list.

---

## 8. Recommendations (priority order)

1. **Land Slice 4 of CaptureWorker**: parse `tfdt`, populate `sEnd`. Without this, archive playback is silently wrong for HEVC cameras and all downstream metrics are skewed. (1–2 hours)
2. **Either wire or drop `hnvr.commands.control.*`**: producer in `AssignmentCoordinator` + `Cameras.Show` view, subscriber in `ConfigWatcher`; or remove from `Subjects.hs` and update design docs. (2 hours)
3. **Either wire or drop `hnvr.config.>` broadcast**: implement `Hnvr.Web.ConfigBroadcaster` mirroring `MediaMTXConfigSyncer`'s LISTEN pattern, or update design to say "config broadcast via DB LISTEN only, no NATS echo" (which is what the code currently does). (1–3 hours)
4. **Add graceful `stop` publish on reassignment** in `AssignmentCoordinator.reassign`. (15 minutes)
5. **Wire the 3 missing CI/dev spec items**: cabal-fmt hook, mediamtx in devShell, cabal build of non-web packages in CI. (30 minutes)
6. **Add `tasty`/`hspec` test suite** for `Hnvr.Capture.Fmp4` and `Hnvr.Core.Time` at minimum. (2–3 hours)
7. **Update design docs + MEMORIES.md** to reflect: minio-hs substitution, nginx-WHEP skip, mediamtx 1.18.2, deferred JetStream, deferred auth, deferred HealthReporter payload fields. (1 hour)
8. **Run the Phase 2 live demo** against Sergey's actual cameras + browser to verify WHEP. Until then "Phase 2 code complete" is technically true but functionally unproven.

---

## Appendix: Repo state at audit time

- **Commits:** 18 total on `master`, latest `24e77f0 docs: add project README`
- **Working tree:** clean, in sync with `origin/master`, no stashes
- **First-party LOC:** ~3,975 hand-written Haskell + ~2,116 IHP-generated
- **Phases claimed complete:** Phase 0, 1, 2 (code only — live VM/browser tests pending)
- **Phases unstarted:** 3 (CV), 4 (events), 5 (PTZ), 6 (hardening), 7 (auto-track v1.1), 8 (polish)
