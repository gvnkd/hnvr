# HNVR — Project Memories

Read this file FIRST before any work. It holds pitfalls, environment facts,
and architecture invariants. Change history lives in `git log` — do NOT add
narrative changelogs here; update this file only with durable lessons,
traps, and facts. Pitfall numbers are referenced from code comments —
never renumber.

## Identity & current state

- **HNVR** — Haskell Network Video Recorder. Owner: Sergey (`omgbebebe@gmail.com`).
- Local path `/home/pion/work/dev/hnvr`; remotes `origin` = gitea@192.168.0.254:omg/hnvr.git, `github` = git@github.com:gvnkd/hnvr.git (push both, branch master).
- Current version **0.23.0.0** (single source of truth: `hnvr-web/hnvr-web.cabal` `version:` — bump on every feature/fix; `Hnvr.Web.version` re-exports via `Paths_hnvr_web` which MUST be in both `autogen-modules` and `other-modules` or link fails).
- Live leader on **:18001** (runs `./result/bin/hnvr-leader` via env-wrap — it is SERGEY'S; never kill it blindly). Test leader on **:18002** (roles-disabled via HNVR_DISABLE_* gates, used for e2e).
- Tests: ~449 Haskell + 35 Playwright e2e + 1 NixOS smoke.
- Design docs `design_docs/00–12` are authoritative for architecture; this file is the cheat-sheet.

## Environment & verified commands

- Prefix anything needing the project flake/.envrc with `~/bin/env-wrap`.
- Dev shell: `nix develop --no-pure-eval` (direnv does this). **Pure-eval `nix develop` is fatal** — devenv.root falls back to the read-only store path (task-cache init error).
- Services: `devenv up` (PG :15432 — Sergey's system PG owns :5432; NATS :4222 auth nats/nats, monitor :8222; mediamtx API :9997, WebRTC :8889, RTSP :8554). Headless: `nohup script -qec "nix develop --no-pure-eval --command devenv up" /tmp/pc.log &` (needs pseudo-TTY; newer devenv also has `--detach` — CI uses it).
- Ports: leader dev `PORT=18001`, test leader 18002, metrics 9102, **hnvr-admin 18010** (HNVR_ADMIN_PORT, binds HNVR_ADMIN_LISTEN default 127.0.0.1), **8000 = Taiga** (never use), **18080 = SeaweedFS** (never use), devenv **nginx test proxy 127.0.0.1:18081 → 18001** (reverse-proxy smoke for `nginx.example.conf`; system nginx owns :80).
- **hnvr-admin** (package `hnvr-admin/`, nix-only like hnvr-web): management front door (M3). IHP is single-app per binary — admin's `AdminWeb.FrontController` is an intentional orphan `FrontController RootApplication` instance; never import Hnvr.Web.FrontController there. Controllers under `Web.Controller.*` again (pitfall #59); Web.Controller.Sessions/Views are home-package shadows of hnvr-web's (View (NewView User) instance too). Cookie `hnvr_admin`. `AdminWeb.Server.runAdmin` replicates IHP.Server.run with Warp.setHost (IHP has no bind-addr option) + wai-app-static for /static. Bootstrap: `hnvr-admin create-user --email --password` (parses args BEFORE IHP — no pitfall-#122 boot) or INITIAL_ADMIN_* env. Grant tables (composite PK) have NO IHP models — raw SQL in AdminWeb.Grants; roles/admin_audit are Generated (Schema.sql). Every mutation → admin_audit row + NOTIFY roles_events. Last-superadmin guards: pure fns in Hnvr.Core.Authz (canDeleteRole/canRemoveSuperadminGrant/canDeleteUser). pg-simple 0.7: `withConnection` is GONE — bracket+connectPostgreSQL. **M4: leader is read-mostly — /Cameras, /Rules, /PtzPresets (incl. ShowCamera) exist ONLY on hnvr-admin; admin connects NATS and republishes assigns on mutation (busRegistry shared).** `runLeaderMigrations` takes PG advisory lock 727272 — concurrent leader+admin cold boots race schema_migrations otherwise (23505).
- S3: external SeaweedFS `http://192.168.0.254:8333`, bucket `hnvr`, creds in gitignored `hnvr.yaml` (`HNVR_CONFIG`; `hnvr.example.yaml` is the template). `HNVR_S3_*` env overrides per-section. ro identity (`s3cRoAccessKey`) signs browser presigned URLs.
- Build: `nix build .#hnvr-web` (IHP path; first ~30 min). Cabal lane: `cabal build hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv hnvr-ptz` (hnvr-web excluded, pitfall #14).
- Tests: `cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv`; integration gated on `HNVR_TEST_INTEGRATION=1` (nats/storage) and `HNVR_ONNXRUNTIME_LIB` (cv ORT smoke).
- e2e: needs devenv up + a leader on :18002 with all HNVR_DISABLE_* gates; `cd tests/e2e && npm install && npx playwright install chromium && npm test`. Run from repo root with the leader already started — a missing `./result/bin/hnvr-leader` fails ALL specs fast. Screenshots: `tests/e2e/scripts/screenshots.mjs` (LIVE_URL=:18001, FRESH_URL=:18002) — blurs camera pixels for the public README: CSS blur on video/frame-imgs/thumbs re-injected on a 250 ms interval (IHP's in-page morph drops foreign `<head>` children, one-shot injection vanishes); rule-editor canvas redrawn in-page (ctx.filter blur + sharp geometry); timeline cursor = now-4min (30 min can land in a coverage gap → "no recording").
- Pre-commit: ormolu, hlint, cabal-fmt, nixpkgs-fmt (ormolu runs in the nix sandbox and does NOT modify the tree — run `ormolu -i` yourself before committing). `nix build .#checks.x86_64-linux.pre-commit`.
- CSS: edit `hnvr-web/static/src.css`, rebuild tracked `app.css` via `tailwindcss -i src.css -o app.css --minify` (in hnvr-web/; env-wrap has the CLI; devenv has a watcher process).
- NixOS VM smoke: `nix build .#checks.x86_64-linux.hnvr-leader-smoke`.

## CI (GitHub Actions)

- Jobs: nix-flake-check (builds .#hnvr-web/.#hnvr-nats THEN `flake check --no-build` — order matters: `--no-build` can't realise callCabal2nix IFD outputs on a fresh store), cabal-non-web, cabal-test-non-web, nightly/master playwright-e2e.
- All `nix develop` calls use `--no-pure-eval .#ci`. `devShells.ci` = default shell minus CUDA onnxruntime + ultralytics (runner disk is ~14 GB; the CUDA stack is ~15 GB source builds). `mkDevShell = ci: …` in flake.nix.
- `flake check` evaluates nixosConfigurations toplevels → baseVmConfig carries placeholder `fileSystems."/"` + `boot.loader.grub.devices`.

## Sergey's hardware & cameras

| Host | GPU | Role |
|------|-----|------|
| hnvr-1 | GTX 1070 (Pascal sm_61) | Worker — CPU EP only (cuDNN ≥9.12 dropped Pascal, pitfall #103) |
| hnvr-2 (dev box) | RTX 4090 (sm_89) | Leader — TRT EP + IHP + MediaMTX + NATS |

Models: `~/.local/share/hnvr/model_cache/yolov8/{yolov8n-320,yolov8s-640}.onnx`; per-camera `cameras.model_name` (backyard+low_ent → s-640, floor_2_5 → n-320). TRT engine cache per host (`HNVR_TRT_CACHE_DIR`).

Cameras (HNVR slugs: low_ent=198, backyard=196, floor_2_5=197):
- **198 low_ent — OpenIPC/Majestic** (flashed from XM stock; runbook `design_docs/11-openipc-lowent-runbook.md`, backups `~/hw-backups/low_ent-699Q3/`). IP 192.168.0.198, root / `io27pJ3wui` (SSH+RTSP+web follow /etc/shadow). **RTSP URLs are query-style `/stream=0` `/stream=1`** — path-form silently falls back to MAIN. Main h264 2592×1520@15, sub h264 640×360@15. ONVIF on **port 80**, cleartext onvif.username/password in /etc/majestic.yaml; needs an HTTP Basic header (Digest also accepted, WSSE-only = 401); ver20-only media configs (ver10 GetVideoEncoderConfigurations faults → tr2 fallback); GovLength unmanaged; NO audio encoder configs over ONVIF; per-token options return the GLOBAL list.
- **196/197 — Hik-OEM** (admin/`123456`), canonical URL form `rtsp://…:554/user=admin&password=…&channel=0&stream={Main,Sub}Stream`. ONVIF at `/onvif/device_service` with WSSE. **SetAudioEncoderConfiguration is BROKEN** — even a no-op set drops the conn, AAC attempts fault, repeated attempts WEDGE the media service (recovery: tds:SystemReboot); switch AAC in the camera web UI. G.711 is sampled 16 kHz but clocked at 8 kHz (RFC-3551) → old recordings have skewed/slowed audio (asetrate fix-forward in v0.15; client-side fmp4RewritePlaylist handles legacy windows). 197: BitrateLimit readback unreliable, H265 silently not applied. 196 rejects a Set right after a Set (ter:ConfigModify) — pace ONVIF Sets ≥8 s, retry after ~3 s.
- XM/ONVIF encoding field is decorative — ffprobe is ground truth. ffprobe `r_frame_rate` on short probes is garbage; trust avg_frame_rate / ONVIF readback. ffmpeg 7.x: `-timeout` (not `-stimeout`). Quote H264DVR URLs (`&` in path).
- WS-Discovery gets no answers on this LAN — never conclude ONVIF absence from it.

## Architecture invariants

- **Leader embeds the full node role** — NEVER run hnvr-node on the leader host with the same HNVR_HOST (double-records every camera; snapshot-claim guard refuses, pitfall #117). hnvr-node is for worker hosts only.
- Nodes claim their host snapshot BEFORE starting ConfigWatcher (retries 30 s).
- mediamtx is the single RTSP ingestion point per camera (session caps, pitfall #11); CaptureWorker pulls `rtsp://localhost:8554/<slug>`. Live view goes through a second per-camera path `<slug>-live` (runOnDemand ffmpeg: relay pull → video copy → Opus with asetrate retag) — raw-relay WHEP can NEVER serve correct G.711 audio (WebRTC honors the declared 8 kHz clock; no browser-side fix exists). `Hnvr.Core.Whep` maps `/whep/<slug>` onto `<slug>-live`.
- Audio-rate truth chain (Aug 2026 incident): prod DB `audio_sample_rate_khz` was NULL → snapshot `csAudioInputRateHz: null` → recorder ffmpeg without `asetrate` → every recording 2× slowed/low. Fallbacks since 0.17: the node probes the relay when the snapshot lacks the rate (`Hnvr.Web.AudioProbe` + `Hnvr.Core.AudioProbe`, ~7 s, cached per camera per boot), and the leader probes for `-live` path rendering. Probing only retags fixed-clock codecs (pcmu/pcma/g726) — media-time math always reproduces the declared 8000; only payload-bytes-vs-wall-clock-arrival (least-squares slope) carries the true rate.
- Pure-extraction pattern (pitfall #14): hnvr-web can't be cabal-tested → pure logic lives in `Hnvr.Core.*`, hnvr-web projects IHP records into the pure types at the call site.
- Migrations: versioned files `hnvr-web/migrations/NNNN-name.sql` wired into `Hnvr.Web.SchemaMigration`; **never edit an applied migration** (checksum mismatch = leader won't boot). Complex partial indexes live ONLY in migrations (schema-compiler can't parse them). After Schema.sql change run `hnvr-web/regen.sh` (pitfalls #32/#123) and hand-add new Generated modules to hnvr-web.cabal (pitfall #51).
- IHP checkbox forms: absent checkbox params leave fill fields unchanged → explicit `set` after fill (paramOrNothing=="on"); absent Maybe params in fill lists get wiped to NULL — keep no-input fields out of `fill`.
- Event dedup: UNIQUE (camera_id, rule_id, track_id, ts) + ON CONFLICT DO NOTHING. `ADD CONSTRAINT` duplicate raises `duplicate_table` (42P07), not duplicate_object — idempotency DO-blocks catch both.
- Timeline UI is THE archive UI (single active player; markers NEWEST-FIRST; window playlists 10 min chained; moof-probe `HNVR.fmp4RewritePlaylist` repairs EXTINF + strips legacy skewed audio; hls.js FIRST, native only as Safari fallback). `/Archive` table is deleted.
- TZ rendering: views emit UTC in `tzTime` spans (`data-utc-ts`), app.js rewrites via `Intl.DateTimeFormat("sv-SE", {timeZone})`; `HNVR.viewerTz()` = body data-user-tz || browser tz.
- Env kill switches for every background role: `HNVR_DISABLE_NODEROLES`, `_HEALTHREPORTER`, `_SNAPSHOTRESPONDER`, `_EVENTWRITER`, `_HEALTHCACHE`, `_COORDINATOR`, `_BROADCASTER`, `_MEDIAMTX`, `_RETENTION`, `_PENDINGPURGE`, `_METRICS`, `_SNAPSHOTWRITER`, `_PTZSTATUSCACHE`, `_PTZAUDIT`, `_ONVIFSYNC`, `_AUTHZ` — used for bisect and for the :18002 test leader.
- Roles & ACL (design_docs/13, M1+M2 landed): policy in `Hnvr.Core.Authz` (RoleSet: wildcard ∪ per-camera override; override REPLACES wildcard for that camera). `Hnvr.Web.Authz.authzMiddleware` runs in the AuthMiddleware chain (after authMiddleware — vault pattern from IHP.LoginSupport.Types) and resolves RoleSet once per request (30 s IORef cache, LISTEN `roles_events` busts). Subject: user→union of roles (superadmin = fullRoleSet via membership), anonymous→`guest` role — an ORDINARY role since 0.23/0019: edit its grants in hnvr-admin or DELETE it for a full login wall (`hnvr-admin enable-guest` re-creates it; anonymous with no guest row fails closed). Since **0.24** a denied anonymous GET/HEAD redirects to `/NewSession` with redirect-after-login (`denyUnless` in Hnvr.Web.Authz) instead of a bare 403; logged-in denials and non-GET/HEAD stay 403. Well-known UUIDs in migration 0016 / Hnvr.Core.Authz. Enforcement: `ensurePerm`/`ensurePagePerm` (403 via IHP accessDeniedUnless), `aclFilterCameras`/`aclCameraIds` for SQL list filtering, `currentRoleSet` pure in views for hiding. Page→grant mapping: Stats/AuditLog/Debug→PageSettings, rules↔ManageEvents, events/timeline/archive↔ViewArchive, clips view ViewArchive / purge PurgeArchive, PTZ status ViewLive. CameraAction ctor `PtzPresetOp` dodges Generated.Types.PtzPreset. **/whep proxy moved out of CustomMiddleware into authzMiddleware** (CustomMiddleware runs before session/auth) — 404 on deny/unknown slug. `/debug-frame/<uuid>` stays anonymous (dashboard wall). CI (.github/workflows/ci.yml) is workflow_dispatch-only (broken, per Sergey 2026-08-30).
- Auth: dashboard + /ShowLive are anonymous-readable; everything else `ensureIsUser`. PTZ markup not rendered for anonymous.
- Metrics: own warp on HNVR_METRICS_PORT in both binaries (pitfall #102); `Hnvr.Core.Metrics` record-of-IO-actions seam.

## Known pitfalls (do NOT re-discover)

1. GHC 9.12 jailbreaks come from IHP's overlay (`ihp.overlays.default`); our packages layer on `pkgs.ghc912`.
2. nats-queue (2017): `sClose`→`close` patched in flake.nix AND `vendored/nats-queue/`; jailbreak+dontCheck its test chain. No TLS, no JetStream.
3. `DerivingStrategies` needed for `deriving stock`/`newtype` syntax.
4. `show` on Text adds quotes — use T.unpack.
6. IHP needs Postgres at boot; `/healthz` short-circuits in CustomMiddleware before IHP's flow.
7. `disableLibraryProfiling` on all our packages (IHP ships no profiling libs).
8. Class imports need `(..)` for methods.
9. `OverloadedStrings` + `length "lit"` ambiguity — bind explicitly.
10/47. Flakes see only git-tracked files — `git add` new modules BEFORE `nix build` ("can't find source for …").
11. Consumer IPCs cap concurrent RTSP sessions (~4).
12. Modules using IHP.Prelude: `NoImplicitPrelude`.
13. Port 8000 = Taiga.
14. `cabal build hnvr-web` unsupported (IHP version pins + text-icu GHC 9.12 patch only exist in the nix overlay). Test hnvr-web logic via `Hnvr.Core.*` extraction.
15. cabal `source-repository-package --patch-dir` silently skips patches — vendor instead.
16. Needs `experimental-features = nix-command flakes pipe-operators` (nixpkgs postgresql family uses `<|`).
17. `pg_config` must be on PATH for cabal build (devenv provides it).
18. IHP `addInitializer` runs in a linked async — wrap fallible IO in E.catch or the leader dies on hiccups.
19. Use prefix `import qualified M as X` (no ImportQualifiedPost).
20. `?context :: T` needs ImplicitParams.
21. Lambda type signatures need ScopedTypeVariables.
22. `catch` ambiguous (IHP.Prelude vs Control.Exception) — use `E.catch`.
23. QEMU hostfwd: comma-separated, space silently drops.
25. HEVC cams emit 2+ fragments/sec → object keys MUST be ms-precision.
26. fMP4 fragments aren't independently playable — `cat init.mp4 frag.mp4 | ffprobe -`.
27. `Data.Fixed.Milli` is a type alias; match with `MkFixed`.
28. amazonka-s3 broken under GHC 9.12/cabal — use minio-hs (vendored, see #116/#118).
29. `constraints: socks >= 0.6.0` in cabal.project (0.5.6 pre-MonadFail).
31. NATS URI must include `user:pass@` or getAddrInfo crashes.
32/123. IHP codegen wraps PKs in `nullable` encoder → run `hnvr-web/regen.sh` after every Schema.sql change; its blanket sed also breaks legitimately-nullable FKs (it re-patches the three Camera statements; any new nullable `Id'` FK hits the same trap). Circular FKs parameterize the record (`Camera' ptzHomePresetId`) — expected.
33. Generated IHP types need the big default-extensions set (see hnvr-web.cabal).
34. hasql-mapping 0.1.0.2 via callHackageDirect in the overlay (nixpkgs pin is stale).
35. HSX can't parse nested record patterns in `pathTo` — bind in let first.
36. IHP `Html` carries implicit params — helpers need no signature, RankNTypes, or stay in `where`.
37. Controllers need `deriving stock (Eq, Show, Data)` + `instance AutoRoute`.
38. No duplicate cabal exposed-modules (Cabal-5559).
39. `Id'` has no ConvertibleStrings — `case x |> get #id of Id t -> t` or coerce.
40. HSX can't parse lambda-piped forEach — top-level helper.
41. hasql 1.9 has no Notification module — LISTEN via a dedicated postgresql-simple connection outside the pool.
42. IHP `sqlExec`/`unsafeSqlExec` broken for DDL — use postgresql-simple one-shot connections. (Plain DELETE/INSERT DML is fine.)
43/112. HSX attribute whitelist: no `playsinline`; `data-*`/`aria-*`/`hx-*` ARE allowed (all app.js hooks are data-*).
44/61. mediamtx API is **v3**: `GET /v3/config/paths/list` ({items:[…]}), `POST …/add/<name>`, `PATCH …/patch/<name>`, `POST …/replace`, `DELETE …/delete/<name>`. /v2 is gone.
45. mediamtx SIGHUP needs polkit — use REST; `/run/hnvr/mediamtx.yml` is boot-time truth.
46/75. NoFieldSelectors everywhere in hnvr-web — only `rec.field` (OverloadedRecordDot); `[GHC-88464]` means you wrote function-style.
48. Pre-commit styles: cabal-fmt 2-space leading-comma; ormolu compact style (`Record{ field = … }`).
49. `AuthMiddleware` type from `IHP.FrameworkConfig.Types`, function from `IHP.LoginSupport.Middleware`.
50. `type instance CurrentUserRecord = User` is invisible without `import Hnvr.Web.Auth ()` in every module touching auth.
51. regen.sh doesn't touch hnvr-web.cabal — hand-add `Generated.*` modules or link fails with undefined `_closure`.
52. IHP auth surface: `HasNewSessionUrl` + `type instance CurrentUserRecord`; sessions controller from `IHP.AuthSupport.Controller.Sessions`.
53. `ensureIsUser` needs explicit `import IHP.LoginSupport.Helper.Controller`.
54. `hashPassword` from `IHP.AuthSupport.Authentication` (pwstore-fast).
55. devenv: `--no-pure-eval` mandatory; PG on :15432; stale `.devenv/state/postgres` keeps OLD config after changes → `~/bin/devenv-kill --reset-pg`; mediamtx HLS port :8888 disabled (collides on Sergey's box); `~/bin/devenv-kill` stops hung devenv.
56. Tailwind: `@apply group` rejected (marker class — put `group` in HSX); content globs resolve relative to tailwind.config.js (hnvr-static derivation copies the whole hnvr-web tree); fresh checkout without app.css = unstyled pages (rebuild manually).
57. `HNVR_DATA_KEY` must be set for any camera CRUD write (dev key baked in devenv env).
58. Never pass `String` to hasql — it encodes a PG char array; `cs` to Text first (silent login failure signature).
59. IHP `actionPrefixText` uses the controller module's FIRST dot-segment — controllers MUST live under `Web.Controller.*` (not `Hnvr.Web.Controller.*`), else every route is `/hnvr/...`. Use IHP-canonical per-resource action names (`CamerasAction`, `ShowCameraAction`…); `startPage DashboardAction` maps `/`.
60. IHP `option` is FIRST-write-wins — compose all middleware into ONE `CustomMiddleware (a . b)`; same for AuthMiddleware etc.
62. WAI `.` composition: leftmost middleware runs first.
63. HSX does NOT splice `{...}` inside `<script>`/`<style>` — build the whole element as `preEscapedTextValue` and splice at body level. app.js loads WITHOUT defer in <head> so inline scripts can use HNVR.*.
64. nixpkgs `xorg.*` attrs are renamed to top-level (`libX11`, `libxscrnsaver`…) — current flake uses old names (eval warnings only).
65. `libgbm` is its own package, not in mesa (chromium needs it; see chromiumRuntimeDeps in flake.nix).
66. `pkgs.nixosTest` → `pkgs.testers.nixosTest`.
67/82. AutoRoute maps `Delete*` actions to HTTP DELETE only; no `_method` middleware — name destructive POST actions `Purge*` (exception: DeleteCamera uses a `_method=DELETE` hidden input pattern). Playwright `page.request.delete` follows 302 with DELETE → use maxRedirects 0.
68/Headless HLS. nixpkgs chromium reports `canPlayType HLS = "maybe"` — all players try hls.js FIRST (native = Safari fallback). Assert which branch ran (data-tl-state "playing" vs "playing (native HLS)").
69. cabal test target syntax: `pkg:testsuite-name`.
71. time-1.14: `import Data.Time.Clock (UTCTime (..))` for the constructor.
72. `import IHP.ModelSupport (Id' (Id))` for the Id constructor.
73. `embedFile` (CWD-relative), never `embedFileRelative` (breaks in nix sandbox).
74. postgresql-simple-migration: `MigrationResult a` is parameterized; wrap `runMigration` in `withTransaction`; jailbreak for stale bounds.
76/113/120. hlint misparses record-dot `.id`/`coerce h.id` as composition ("Redundant id") — use `x |> get #id`.
77. IHP `paramOrNothing` is PURE — bind with let.
78. Never edit an applied migration — new file + new embed + new runMigration call.
79. Headless `devenv up` needs a pseudo-TTY (`script -qec`); `--detach` works on current devenv.
80. Playwright strict mode: scope locators to a specific form when pages carry several.
81. Timeline/recording grouping MUST partition by camera (`groupRecordingsBy spCameraId`) — concurrent captures interleave below the gap tolerance.
83. `nix build` overwrites `./result` with the LAST-built attr — app runs from `./result-web/bin/…` (build with `-o result-web`); result-precommit/result-smoke exist for the same reason.
84. Row-key S3 deletes are blind to orphan objects (and DELETE of a missing key silently succeeds) — purges also list day-prefixes and delete by key-embedded timestamp.
85. AutoRoute field names share the URL param namespace with filter params — verb-prefix action fields (`purgeCameraId`, `purgeFrom`) to avoid `?cameraId=X&cameraId=X`.
86. Leader needs `LimitNOFILE=524288` (systemd default 1024 → "Too many open files" under load; signature: page.goto timeouts while curl works).
87. IHP `deleteRecords` = N round-trips — bulk `sqlExec "DELETE FROM …"` for windows >100 rows.
88. Background destructive work: capture `?modelContext` (pool, thread-safe) into `Async.async` — NEVER capture `?context` (request-scoped).
89. ORT `CreateSession(env, path, opts, out)` — env FIRST; omitting segfaults.
90. ORT vtable indices are version-locked — regenerate from the PINNED nixpkgs `-dev` header on any onnxruntime bump (stale = silent memory corruption). `GetVersionString`/`GetApi` live on OrtApiBase.
91. hnvr-cv ORT tests gate on `HNVR_ONNXRUNTIME_LIB` (skip silently without it).
92. massiv: NCHW needs `Ix4` (`0 :> c :> y :. x`), `pattern Sz4` import, `S (S)`.
93. ORT `CastTypeInfoToTensorInfo` output is NOT caller-owned (double-free); `GetTensorTypeAndShape` output IS.
94. `cabal repl` + dlopen(libonnxruntime) = SIGABRT — probe models via compiled gated tests.
96. ORT `Run`: output_names_len BEFORE the outputs pointer; `CreateTensorWithDataAsOrtValue` p_data_len is BYTES.
97. Model export: devShell python env `[ultralytics onnx onnxslim]`; `yolo export model=yolov8n.pt format=onnx imgsz=320 opset=17 simplify=True dynamic=False`.
98. `nixpkgs#attr` (channel registry) ≠ the flake's pinned nixpkgs — parse headers from the pinned rev/store `-dev` output only.
99. Zero ORT output slots before `Run` (`poke out nullPtr`) — alloca garbage = SIGSEGV in long-lived processes only (fresh stacks read as zero; passes isolated stress tests).
100. Shell traps: `pkill -f "bin/hnvr-leader"` matches your own command line (even with `[e]` if the same command restarts it — separate tool calls); `grep -c` exits 1 on zero matches; `nix log` has ANSI codes + errors mid-log; background processes need `setsid nohup … &` (tool-call-backgrounded processes die with the call); `rm -f glob*` with no matches aborts zsh &&-chains.
101. ekg-core Distribution min/max garbage under `-N` — renderer emits only `_count`+`_sum`.
102. Metrics = own warp on HNVR_METRICS_PORT (dev 9102), not IHP middleware; ekg-core errors on duplicate registration — the metric caches in Hnvr.Web.Metrics are load-bearing.
103. cuDNN ≥9.12 dropped Maxwell/Pascal and ORT 1.27 CUDA EP hard-links cuDNN → hnvr-1 (GTX 1070) runs CPU EP; can't overrideAttrs around a `badPlatforms` dep interpolated into cmakeFlags.
104. ORT TRT EP: `-Donnxruntime_USE_TENSORRT_BUILTIN_PARSER=ON` (else FetchContent onnx-tensorrt dies under FETCHCONTENT_FULLY_DISCONNECTED); TENSORRT_HOME = symlinkJoin of tensorrt's out/include/lib/static; TRT redist is insecure → permittedInsecurePackages computed dynamically.
105. Lazy pure-state threading in a forever-loop = linear heap leak (leader OOM): force tracker state at the loop head; IntMap is spine-strict but value-lazy. Diag: `+RTS -M4G -S`, LeakProbe stage bisect, `-hT` profile.
106. Not every RSS climb is a leak — discriminate with -M4G (GHC leaks die fast), -S live-bytes, env bisect. Exes use `-A16m` (a copied `-A64m` × 32 capabilities ≈ 2 GB arenas). Gauge: `hnvr_process_resident_bytes`.
107. `catch`/`try SomeException` swallows cancellation AND defeats System.Timeout — rethrow `SomeAsyncException` first (FrameSource/Worker/SpoolDrainer fixed; ConfigBroadcaster/MediaMTXConfigSyncer/SnapshotResponder catches not yet audited).
108. minio-hs retries connection-refused forever — bound S3-failure tests with `timeout`; a drain pass won't terminate during a full outage.
109. IHP schema-compiler rejects `--` comments INSIDE CREATE TABLE column lists and inline `REFERENCES` (use table-level FOREIGN KEY). regen.sh `rm -rf gen` first — rerun to restore after fixing.
110. Presigned S3 URLs are signed for the endpoint host — browser URLs use `s3cPublicEndpoint`/ro keys, never string-rewritten internal endpoints.
111. Author CSS `display:flex` beats `[hidden]` — src.css has `[hidden] { display: none !important }`.
114. UNRESOLVED: backyard + low_ent WHEP return 400 in headless chromium (floor_2_5 works). Check `/v3/config/paths/get/<slug>` when touching live view.
115. Stale `./result` leader + new app.css = mixed broken layout — restart dev leader from `./result-web/bin/hnvr-leader`; `pgrep -af 'hnvr-lead[e]r'` must show exactly one.
116. minio-hs 1.7.0 sends `continuation_token` (underscore) → infinite page-1 listing loop (the 13→47 GB OOM) — vendored & patched; `listObjectKeys` has a strictly-increasing-key guard. Pipe exit-code trap: `cmd | tail; echo $?` measures tail.
117. Duplicate-capture guard: snapshot-claim handshake (`csbClaimed`); diag SQL `SELECT object_key, count(*) FROM segments GROUP BY 1 HAVING count(*)>1`.
118. minio-hs `executeRequest` never validated HTTP status → vendored deleteObject throws on non-2xx/404. Verify library claims against `mc stat`/curl, not your own printf.
119. cam-196: retry ONVIF Sets after ~3 s on ter:ConfigModify.
121. pg-simple can't express tuple `NOT IN ?`; Camera FK columns codegen as plain UUID (compare with unwrapped UUIDs); hnvr-ptz fixture tests must run from the package dir.
126. postgresql-simple 0.7: `PGArray` for `= ANY(?)` params lives in `Database.PostgreSQL.Simple.Types` (NOT .Arrays — that's ArrayFormat) AND renders an untyped ARRAY[...] — always cast the placeholder (`ANY(?::uuid[])`) or PG parses `uuid = text` (42883) even when the branch is ORed behind a `?::bool` guard (parse-time typing). Tuple ToRow caps at 10 → chunk wide param sets as 4-tuples joined with `:.` (Events.fetchEventRows). IHP `filterWhereIn` compiles to `= ANY(param)` — empty list is safe (no rows, no syntax error).
127. Migration scripts (postgresql-simple-migration) run via `execute` — NO result columns allowed: no `SELECT` at all; use bare `NOTIFY ch, 'msg'` (not `SELECT pg_notify(...)`). pg_advisory_lock returns void — in app code read it via `query_ "SELECT count(*) FROM (SELECT pg_advisory_lock(N)) t"`.
- **users.is_admin is GONE (0.22)** — 0017 backfills superadmin, 0018 drops the column. Role membership is the only superadmin path. e2e: management specs (cameras-crud/rules/roles.spec.ts) run against hnvr-admin (`ADMIN_URL`, `adminLoggedInPage` fixture, `loginAdmin` in tests/e2e/lib/auth.ts); leader-side specs pick cameras from dashboard cards via `firstCamera` (leader /Cameras is 404 since M4).
122. IHP hasql caps tuples at 10 params — wide rows need hand-written FromRow over a one-shot pg-simple connection (`:.` from `Database.PostgreSQL.Simple.Types`). **`hnvr-leader --version`/`--help` BOOTS the app** (stray leader!) — check versions via `strings result/bin/hnvr-leader | grep`.
124. **Dev DB ≠ prod DB.** The prod leader (192.168.0.254, NATS/S3/mediamtx there) has its own cameras table; never diagnose camera config from the devenv :15432 DB. Probe what the leader actually serves: NATS request-reply on `hnvr.commands.snapshot.<host>` (creds nats/nats; same-host re-claim is the node's own boot path, idempotent).
125. **GHC 9.12 silent nix-build death**: using an out-of-scope record selector in hnvr-web (NoFieldSelectors env) crashes the compiler's out-of-scope/suggestion machinery with NO diagnostic — `nix build` exits 1 after the last `Compiling` line, and the failing module's `.o` is simply absent from a `--keep-failed` dir. Signature: reproducible, memory flat, no error text. Fix: import the record constructor (`ProbedAudio (..)` etc.). Bisect by neutering function bodies, not by hunting logs. **Second trigger (2026-08-30): an HSX attribute outside the whitelist (`inputmode`) dies the same silent way** — `autocomplete` is whitelisted, `inputmode` is NOT; bisect view attributes when a build dies after adding one.

## Frontend/player traps

- Fullscreen: fullscreen the WRAPPER div, transform the video inside (a fullscreened `<video>` can bypass the compositor); hide `::-webkit-media-controls-fullscreen-button`; EVERY level of a fullscreen flex chain needs min-height:0; any `width:min()` on a fullscreen target shrinks it inside fullscreen — :fullscreen rules set explicit 100%.
- zoompan: wheel + dblclick intercepted in CAPTURE phase (Chrome's shadow-root handlers consume them); drag-end click dispatches on the nearest common ancestor → suppress at window-level capture with a 300 ms expiry. Headless chromium has NO UA dblclick-fullscreen.
- e2e: player card can push the canvas below the viewport fold → `scrollIntoViewIfNeeded()` before mouse drags. Never submit the purge form in e2e (window = whole timeline). `HNVR.applyTz` after any innerHTML refresh.
- TimelineData markers are NEWEST-FIRST.
- Headless verification: drawImage→canvas.toDataURL pixel hashing works; getVideoPlaybackQuality counts decodes not presents; rVFC never fires on frozen pipelines.
- SeaweedFS presign signs only the host → Range requests work; presigned URLs expire in 1 h (re-download fixtures); /PlaylistArchive presigns hundreds of URLs ≈ 8 s/request.

## Ops traps

- `pkill -f result/bin/hnvr-leader` kills SERGEY'S live leader too — scope kills by port/PID (`ss -tlnp`, `fuser -k PORT/tcp`; no lsof).
- devenv rewrites `~/.mc` config — use `curl --aws-sigv4 "aws:amz:us-east-1:s3" -u key:secret` against 192.168.0.254:8333 instead of mc aliases.
- Leader-env scripts must export the ffmpeg bin dir on PATH (posix_spawnp failures → FailedPermanent on all cameras).
- Version checks: `strings result/bin/hnvr-leader | grep` (never --version, pitfall #122).

## Open issues / known dead code (report-only per Sergey)

- `AutoTrack` empty module, `restartCamera` dead export, `Subjects.leader` unused, ConfigBroadcaster→ConfigWatcher config channel is log-only (superseded by snapshot assigns), hnvr-crypto-test exe redundant.
- `nix/secrets.nix` declares removed hnvr-s3-* keys and never declares hnvr-config (pointing configFile at it = NixOS eval failure).
- `flake check --no-build` needs devenv-tasks' pinned-nixpkgs source FOD realised (tasks/package.nix does IFD `import source`) → CI warms it via `nix build --no-link .#devShells.x86_64-linux.ci` before flake check (never build `.#devShells.default` on the runner — CUDA stack, disk).
- Tracked firmware zip at repo root (~7 MB, belongs in ~/hw-backups); untracked ext/, extro/, hnvr-leak-probe.prof, start-shell-telnetd.bin — do NOT commit.
- hnvr-cv Preprocess property "scaled dims fit the target" flaked once — watch if it recurs.
- Two-node failover nixosTest still TODO (VMs use per-VM localhost NATS).

## Sergey's working style

- Direct, concise; call him "Sergey", never "user". `~/bin/env-wrap` for project commands. GHC 9.12 + IHP bleeding edge by choice. Design for horizontal scale even when v1 doesn't need it.
