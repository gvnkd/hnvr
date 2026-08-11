# HNVR — Testing Strategy

Companion to `08-roadmap.md`. Defines the test pyramid, framework choices,
per-package layout, CI wiring, and the Web UI test approach. Implementation
schedule with priorities lives in `10-test-plan.md`.

## Goals

| # | Goal | Verification |
|---|------|--------------|
| T1 | Refactors and dependency bumps can land without a full manual exercise | Pure + property suites green on every push |
| T2 | Each NATS / S3 / PG touchpoint has at least one contract test | Integration suite green against ephemeral services |
| T3 | IHP routes + auth gates behave as documented | WAI in-process request tests for every controller action |
| T4 | Full stack (leader + node + NATS + S3 + PG + mediamtx) boots and serves the documented flows | devenv-driven end-to-end scenarios in CI nightly |
| T5 | Failover claim (15 s reassign on host loss) is reproducible | NixOS VM test exercising the AssignmentCoordinator under host-down |
| T6 | UI flows (login, camera CRUD, live view, archive playback) work in a real browser | Playwright suite covering happy paths |

## Non-goals

- 100 % line coverage. Targeted coverage of pure, risky, and contract-sensitive code only.
- Performance / load benchmarks as part of CI (separate doc if/when needed).
- Visual regression for the UI (no Chromatic / Percy in v1).
- Mutation testing in CI (occasional local use of `mutant` is fine).

## Test pyramid

```
                     ▲
                     │  NixOS VM tests (Phase 2 failover demo)           ← T5
                     │  devenv end-to-end scenarios                      ← T4
                     ├────────────────────────────────────
                     │  Integration (NATS, S3 MinIO, PG, ffmpeg)         ← T2
                     │  WAI in-process controller tests                  ← T3
                     ├────────────────────────────────────
                     │  Property tests (Fmp4, Crypto, Geometry, Time,
                     │                   SORT, Decode, Rules)
                     │  Unit tests (pure helpers, codecs, formats)
                     └────────────────────────────────────  ← bulk, T1
```

The base is cheap, deterministic, runs in seconds; the apex is expensive,
runs in minutes on CI or nightly. A push that breaks a base-layer test
should never reach CI — it should break in `cabal test` locally.

## Frameworks

### Haskell

| Layer | Library | Why |
|-------|---------|-----|
| Runner | **`tasty`** | Composes HUnit + QuickCheck + hedgehog in one tree; golden tests via `tasty-golden`; resource bracketing via `withResource`. |
| Unit assertions | **`tasty-hunit`** | Standard, no surprises. |
| Property tests | **`tasty-quickcheck`** + `QuickCheck` | QuickCheck is already alluded to in `Hnvr.Capture.Fmp4`'s Haddock; smallest delta. |
| Golden tests | **`tasty-golden`** | For ffprobe JSON samples, mediamtx YAML diff, sample fMP4 fragment fixtures. |
| HTTP-in-process | **`wai-extra` (`Network.Wai.Test`)** | Drive IHP's `Application` without a TCP socket — fast, deterministic controller tests. |
| HTTP-over-wire | **`wreq`** or `http-client` | For tests that must hit a real port (devenv E2E). |
| PG ephemeral | **`tmp-postgres`** (or devenv PG at `:15432`) | `tmp-postgres` for hermetic per-test DBs; devenv PG for E2E. |
| S3 ephemeral | **MinIO** via devenv service or `testcontainers-hs` if it builds | MinIO is already wired in devenv; CI just needs to start it. |
| NATS ephemeral | **`nats-server`** via devenv service or `process` spawn | Single binary, ~5 MB, starts in <100 ms; no testcontainer needed. |
| Testcontainers | **`testcontainers-hs`** *if it builds on GHC 9.12* | Preferred for hermetic per-suite services; fallback is devenv-managed ports. |
| Coverage | **`hpc`** + `tasty-hunit`'s `--coverage`-friendly output | Built into GHC; no `hpc-coveralls` unless we want a badge. |

**Rejected alternatives:**
- `hspec` — fine, but overlaps with `tasty`; pick one. `tasty` integrates better with property tests.
- `hedgehog` — also fine, but QuickCheck's type-class-driven `Arbitrary` is faster to retrofit on existing types. Re-evaluate if shrinking becomes painful (SORT tracker may push us there).
- `yesod-test` — pulls in yesod-core; we're IHP, not Yesod. `wai-extra` is enough.

### GHC 9.12 caveat

Several test libs may need `allow-newer` or jailbreaks under 9.12.3 (same as
the production deps). The plan: pin via `flake.nix` `hnvrHaskellOverlay`
just like the runtime libs, and mirror the bounds in `cabal.project`. If
`testcontainers-hs` doesn't build, we fall back to devenv-managed services
(PG, MinIO, NATS already wired — see MEMORIES.md §55).

### Web UI

| Tool | Role | Why |
|------|------|-----|
| **Playwright** (TypeScript) | Primary E2E UI test framework | WebRTC-aware (`<video>` playing assertions, `page.waitForFunction("video.readyState >= 2")`); multi-browser (Chromium / Firefox / WebKit); handles HLS.js + WHEP flows; mature locator strategy; one binary install. Lives in `tests/e2e/` with its own `package.json`. |
| `wai-extra` `Network.Wai.Test` | Controller-level HTTP tests (no browser) | Keeps UI-adjacent logic (redirects, CSRF, auth gates) tested in Haskell, fast. |
| `tasty-webdriver` / `hs-webdriver` *(optional)* | If we want a Haskell-only UI smoke test | Lower feature ceiling than Playwright (no WebRTC waits); only worth it if Sergey wants everything in one `cabal test` run. |

**Recommendation: Playwright for UI, `wai-extra` for controllers.** The WebRTC
+ HLS surface is exactly where Playwright shines; hs-webdriver would force
us to poll `<video>` state manually and skip live-view tests entirely.

Rejected alternatives:
- **Cypress** — popular and developer-friendly, but WebRTC and multi-tab
  flows are second-class; the WHEP session lifecycle (POST → PATCH → DELETE
  on different URLs) hits Cypress's single-tab model awkwardly.
- **Selenium IDE** — record-and-playback is brittle; not for CI.
- **Puppeteer** — Chromium-only; Playwright is its successor and supports
  Firefox/WebKit which matters for HLS.js codec fallback tests.

## Per-package layout

Every package gets a `test-suite` stanza in its `.cabal`. Tests live under
`<pkg>/test/`. Naming: `Hnvr.<Module>Spec` (mirrors the module under test).

### Cabal stanza template

```cabal
test-suite hnvr-<pkg>-test
  import:           haskell-imports   -- if we factor one out
  type:             exitcode-stdio-1.0
  main-is:          Main.hs
  hs-source-dirs:   test
  other-modules:    Hnvr.<Pkg>.Fmp4Spec
                    ...
  build-depends:
    , base
    , hnvr-<pkg>
    , tasty
    , tasty-hunit
    , tasty-quickcheck
    , QuickCheck
    , bytestring
    , text
    , time

  default-language: Haskell2010
  ghc-options:      -threaded -rtsopts "-with-rtsopts=-N"
```

### `Main.hs` template

```haskell
module Main (main) where

import qualified Hnvr.Capture.Fmp4Spec      as Fmp4Spec
import qualified Hnvr.Capture.WorkerSpec    as WorkerSpec
import           Test.Tasty                 (defaultMain, testGroup)

main :: IO ()
main = defaultMain $
  testGroup "hnvr-capture"
    [ Fmp4Spec.tests
    , WorkerSpec.tests
    ]
```

One `Main.hs` per package, one `cabal test hnvr-<pkg>` invocation, one
Tasty tree. Keep it flat — don't nest test groups deeper than two levels.

## CI integration

### Existing CI (`.github/workflows/ci.yml`)

- `nix-flake-check` job — runs `nix flake check`, builds `hnvr-web` and `hnvr-nats`.
- `cabal-non-web` job — `cabal build` of the six non-web packages.

### Additions

| Job | Runs on | Purpose |
|-----|---------|---------|
| `cabal-test-non-web` | `ubuntu-24.04`, `nix develop` | `cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv hnvr-ptz` — pure + property tests. **Fast lane: every push.** |
| `cabal-test-web` | `ubuntu-24.04`, `nix develop` + PG service | `cabal test hnvr-web` — WAI controller tests + Auth + Schema migration tests against an ephemeral PG. **Fast lane: every push.** |
| `devenv-integration` | `ubuntu-24.04`, `devenv up` background | Spin devenv services (PG, MinIO, NATS, mediamtx); run `tests/integration/` Tasty suite via `cabal test` or `nix run .#hnvr-integration-tests`. **Slow lane: nightly + on `master`.** |
| `playwright-e2e` | `ubuntu-24.04`, `nix develop` + devenv + Playwright | Boot leader + node against devenv services; run `cd tests/e2e && npx playwright test`. **Nightly + on master.** |
| `nixos-vm-test` | `ubuntu-24.04` | `nix build .#nixosTests.hnvr-failover` — the AssignmentCoordinator under host-down. **Nightly.** Tracks the open Phase 2 demo item. |

Every test job uploads its Tasty XML / JUnit report (`-- tasty-trpc-fd` or
`tasty-ant-xml`) as a GitHub Actions artifact for 14 days.

### Pre-commit hooks

The existing `pre-commit-hooks.nix` runs `ormolu`, `hlint`, `cabal-fmt`,
`nixpkgs-fmt`. Add:
- `cabal-test` quick hook **NOT** added (too slow for pre-commit).
- Instead: a `ghcid`-on-save workflow for the dev shell (`ghcid -c 'cabal repl hnvr-core'`).

## Property test patterns to encode

These are the invariants the design already promises — write them down as
QuickCheck properties from day one.

| Module | Property | Statement |
|--------|----------|-----------|
| `Hnvr.Capture.Fmp4` | chunk-boundary invariance | For any chunking of the same byte stream, `feed` produces the same `Fragment` sequence. (`forAllShrink_ (chunkBytes raw) ...`) |
| `Hnvr.Capture.Fmp4` | tfdt extraction | The `baseMediaDecodeTime` returned matches the first `tfdt` box in the moof. |
| `Hnvr.Core.Crypto` | roundtrip | `decryptText k <$> encryptText k t  ==  pure t` for any `t`, any key. |
| `Hnvr.Core.Crypto` | auth-failure | Mutating any byte in the ciphertext makes `decryptText` throw. |
| `Hnvr.Core.Time` | ms precision monotonic | Two distinct `UTCTime`s ≥ 1 ms apart produce distinct `formatSegmentObjectKeyMs` keys. |
| `Hnvr.Core.Geometry` | functor laws | `fmap f . fmap g == fmap (f . g)` on `Box a`. |
| `Hnvr.Cv.Tracker.Sort` | determinism | Same input detections → same output tracks, regardless of `Data.Map` traversal order. (Lands with Phase 3.) |
| `Hnvr.Cv.Decode` | NMS idempotence | `nms . nms == nms`. (Lands with Phase 3.) |
| `Hnvr.Cv.Rules` | cooldown | After an event, the same rule doesn't fire again within `cooldown_ms`. (Lands with Phase 4.) |
| `Hnvr.Nats.Subjects` | no overlap | No two subject constructors produce the same literal prefix on the same domain. |

## Test data & fixtures

```
tests/
├── fixtures/
│   ├── fmp4/
│   │   ├── cam-197-init.mp4         # real init segment captured Aug 9 2026
│   │   ├── cam-197-frag-0001.mp4    # one moof+mdat pair, ~80 KB
│   │   ├── cam-196-frag-0001.mp4    # HEVC variant (2 frags/sec)
│   │   └── broken-truncated.mp4     # negative case
│   ├── ffprobe/
│   │   ├── cam-197-main.json        # ffprobe -print json -show_streams
│   │   ├── cam-197-sub.json
│   │   ├── cam-196-main.json
│   │   └── cam-198-main.json
│   ├── whep/
│   │   ├── sdp-offer.json
│   │   └── sdp-answer-mediamtx.json
│   └── schema/
│       └── Schema.bootstrap.sql     # IHP Schema.sql with seed rows for tests
├── integration/                     # Haskell Tasty suite, run against devenv
│   └── ...
└── e2e/                             # Playwright (Node)
    ├── package.json
    ├── playwright.config.ts
    ├── tests/
    │   ├── login.spec.ts
    │   ├── cameras-crud.spec.ts
    │   ├── archive-playback.spec.ts
    │   ├── live-view.spec.ts
    │   └── failover.spec.ts
    └── fixtures/
        └── ...
```

**Policy:**
- Real captured fMP4 fragments are the gold standard fixtures — checked in
  under `tests/fixtures/fmp4/`. The Aug 9 2026 capture run on Sergey's three
  cameras produced representative samples for H.264 and HEVC variants.
- ffprobe JSON fixtures are committed to test the `Probe` parser without
  shelling out to ffprobe.
- Camera credentials **never** in fixtures — only the URL template form
  with placeholder passwords.
- Schema bootstrap for tests lives separately from `Application/Schema.sql`
  so production migrations aren't constrained by test ergonomics.

## External-dependency strategies

| Dependency | In unit tests | In integration tests | In E2E / NixOS tests |
|------------|---------------|----------------------|----------------------|
| PostgreSQL | Mocked / avoided (use pure funcs) | `tmp-postgres` per-suite OR devenv PG at `:15432` | devenv PG / NixOS VM PG |
| MinIO / S3 | Avoided | MinIO via devenv (port `:9100`) | devenv MinIO / SaaS SeaweedFS in staging |
| NATS | Avoided (test pure subject construction) | `nats-server -c /tmp/test.conf` spawned per-suite, port randomised | devenv NATS `:4222` |
| ffmpeg / ffprobe | Use sample files instead of shelling | Real ffmpeg against sample MP4 | Real RTSP pull (only in Sergey's manual E2E) |
| MediaMTX | Avoided | Skipped — mediamtx config is generated; test the YAML, not the binary | devenv mediamtx `:9997` |
| WebRTC | n/a | n/a | Playwright against leader's WHEP endpoint |

**Rule of thumb:** if a test would need to spawn an external process, it
belongs in the integration layer or above — never in the unit layer.

## What does NOT get a unit test

- IHP-generated modules under `gen/Generated.*` — they're codegen output;
  test via the controller-level WAI tests instead.
- `Hnvr.Capture.Ffmpeg.recordingArgs` — the only assertion that matters is
  the produced argument list, and it changes with ffmpeg versions. A golden
  test against `ffmpeg -version 7.x` is acceptable; deeper testing is the
  job of the integration suite.
- Pure stubs (`Hnvr.Cv.OnnxRuntime`, `Hnvr.Ptz.Onvif`, etc.) — no behavior
  to test until Phase 3+ fills them in.

## Coverage target

No formal percentage target. Instead, the rule is:

- Every pure module above 50 LOC has at least one QuickCheck property.
- Every `IO`-returning function with a non-trivial branch has at least one
  integration test exercising each branch.
- Bug fixes ship with a regression test.
- Public API exports listed in the module's export list each appear in at
  least one test name.

`hpc` markup is generated in CI as an artifact but not gated.

## Open questions (resolve in `10-test-plan.md`)

1. `testcontainers-hs` buildability on GHC 9.12.3 — fallback is devenv.
2. Whether to gate merges on the `cabal-test-non-web` job or run it as
   informational only for the first sprint.
3. Where the Playwright Node project lives (`tests/e2e/` vs separate repo).
   Recommendation: in-repo `tests/e2e/`, Nix-managed via `pkgs.nodePackages`
   + `playwright-driver`.
4. Whether to invest in a single `nix flake check`-compatible
   `nixosTests.hnvr-failover` now (Phase 2 demo pending) or defer to Phase 6.
