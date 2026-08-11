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

### Headless-shell library loading under nix-shell

The playwright-downloaded `chrome-headless-shell` is a typical Linux
binary that expects `libglib-2.0.so.0`, `libnss3`, `libgbm`, etc. on
`LD_LIBRARY_PATH`. Pure `nix develop` shells don't expose these by
default — chromium fails to launch with
`error while loading shared libraries: libglib-2.0.so.0`.

Two known workarounds:

1. **Run from outside the nix shell.** Exit `nix develop` before
   `npm test`; system chrome libs are visible there.
2. **Add `pkgs.nix-ld` to devenv packages** and set
   `NIX_LD_LIBRARY_PATH` to include `pkgs.glib`, `pkgs.nss`, `pkgs.gbm`,
   etc. The full list is what `pkgs.chromium` would pull in as
   `buildInputs`. (TODO: wire this in flake.nix — not in S4's scope.)

The CI nightly job sidesteps this by running Playwright from a regular
ubuntu-24.04 runner (not `nix develop`).

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
