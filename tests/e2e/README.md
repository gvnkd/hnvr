# Playwright E2E tests for HNVR

End-to-end UI tests (S4 deliverable per `design_docs/10-test-plan.md`).
Playwright was chosen over Cypress / hs-webdriver for native WebRTC +
multi-browser support — see `design_docs/09-testing.md` §"Web UI".

## Run locally

```bash
# 1. devenv services up (postgres :15432, nats :4222, minio :9100, mediamtx :9997)
devenv up

# 2. Build + run the leader (in another terminal)
nix build .#hnvr-web
./result/bin/hnvr-leader      # serves on PORT=18001

# 3. Install playwright + chromium browser (one-time)
cd tests/e2e
npm install
npx playwright install chromium

# 4. Run the suite
npm test
```

The base URL defaults to `http://127.0.0.1:18001`. Override with
`BASE_URL=http://other:port npm test`.

Bootstrap admin credentials come from the devenv env block
(`admin@hnvr.local` / `hnvr-dev`). Override with `HNVR_ADMIN_EMAIL` /
`HNVR_ADMIN_PASSWORD` for non-devenv environments.

### Chromium launches cleanly inside `nix develop`

The flake.nix `enterShell` hook extends `NIX_LD_LIBRARY_PATH` with the
chromium runtime deps (glib, nss, atk, libxcb, libgbm, xorg libs,
pango, cairo, alsa-lib, expat — full list in the `chromiumRuntimeDeps`
binding). With Sergey's system `programs.nix-ld.enable = true` config,
this is enough for the Playwright-downloaded `chrome-headless-shell`
to find every lib it needs via the nix-ld loader.

Verified Aug 11 2026: `npx playwright test` runs cleanly inside
`nix develop` against a `./result/bin/hnvr-leader` started in another
terminal. No need to exit the nix shell.

If you change the chromium runtime dep set (e.g. after a Playwright
version bump surfaces a new missing lib), edit `chromiumRuntimeDeps`
in flake.nix. The full list is what `pkgs.chromium` itself declares as
`runtimeDependencies` in nixpkgs.

## Layout

```
tests/e2e/
├── package.json            # @playwright/test + typescript dev deps
├── tsconfig.json
├── playwright.config.ts    # baseURL, single-worker (shared dev DB)
├── lib/
│   └── auth.ts             # login() helper + loggedInPage fixture
└── tests/
    ├── login.spec.ts       # /NewSession + /CreateSession + auth gate
    └── cameras-crud.spec.ts # create → list → edit → delete cycle
```

## CI

Nightly job defined in `.github/workflows/ci.yml` (`playwright-e2e`).
The job:
1. Boots postgres + nats via `devenv up` (background)
2. Builds + runs `hnvr-leader` (background)
3. Runs `npm install && npx playwright install chromium && npm test`
4. Uploads the JUnit report + traces as artifacts

Disabled on regular PRs (slow; needs full stack up).

## Why node + npm?

Sergey's project is otherwise npm-free (Tailwind CLI for CSS, no node
runtime in production). E2E UI tests are the one exception — Playwright
is the only mature framework that handles WebRTC + WHEP session
lifecycle and multi-browser (Chromium/Firefox/WebKit). The dependency
is dev-only; production builds are unaffected.

See `design_docs/09-testing.md` §"Web UI" for the rejected alternatives
(Cypress, hs-webdriver, Selenium IDE).
