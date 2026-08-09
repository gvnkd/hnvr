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

## Verified commands (Aug 8 2026)

```bash
# Build everything (IHP overlay applied; first build ~30 min, then cached)
nix build .#hnvr-web

# Enter dev shell (ormolu, hlint, cabal, ffmpeg, onnxruntime, nats-server)
nix develop

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
│   ├── nats-server.nix  NixOS module: NATS + JetStream
│   └── secrets-template.yaml  sops-nix template (HNVR_DATA_KEY + S3 + DB)
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
│                        ├── src/Hnvr/Web/FrontController.hs RootApplication + parseRoute @CamerasController
│                        ├── src/Hnvr/Web/Controller/Cameras.hs      CRUD + Probe action
│                        ├── src/Hnvr/Web/Controller/Cameras/Probe.hs ffprobe JSON parser
│                        ├── src/Hnvr/Web/Controller/Archive.hs       PlayerAction + m3u8 PlaylistAction
│                        ├── src/Hnvr/Web/View/Layout.hs             default HTML layout
│                        ├── src/Hnvr/Web/View/Cameras/{Index,New,Edit,Show}.hs
│                        ├── src/Hnvr/Web/View/Archive/Player.hs      @\<video\>@ + hls.js
│                        ├── app/LeaderMain.hs        IHP.Server.run + NATS via addInitializer
│                        └── app/NodeMain.hs          withBus + subscribe hnvr.commands.>
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
- [~] **Phase 1** — Recording MVP. **Slice 1+2+3+4a+4b+4c+5+6+7a done (Aug 9 2026)**:
      - ✅ Cameras probed; core types; Fmp4; Ffmpeg; record-frames;
            minio-hs S3 wrapper; CaptureWorker + capture-loop binary
      - ✅ Schema.sql + IHP v1.6.0 Generated types + Cameras CRUD +
            ffprobe button
      - ✅ Slice 5: EventWriter (NATS → PG drain loop)
      - ✅ Slice 6: Archive playback (m3u8 + hls.js)
      - ✅ Slice 7a: `Hnvr.Core.Crypto` AES-256-GCM (cryptonite via
            lower-level aeadAppendHeader/aeadEncrypt/aeadFinalize API —
            `aeadSimpleEncrypt`/`aeadSimpleDecrypt` have a tag-format
            bug in cryptonite-0.30 that fails auth). Round-trip
            verified via `hnvr-crypto-test` binary against both
            generated and explicit keys. sops-nix template at
            `nix/secrets-template.yaml` (Sergey fills in production).
      - ⏳ Slice 7b: Schema migration (`password TEXT` →
            `password_enc BYTEA` + `password_nonce BYTEA`) + Cameras
            CRUD wiring to encrypt on Create/Update, decrypt on Probe
- [ ] Phase 1 — Recording MVP (functionally complete; Slice 7b is the
      operational security gate)
- [ ] Phase 2 — Live view + multi-host
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
