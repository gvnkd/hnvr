import {defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for HNVR end-to-end UI tests.
 *
 * Run locally:
 *   cd tests/e2e && npm install && npx playwright install chromium
 *   # Start devenv services + leader in another terminal:
 *   devenv up                 # postgres :15432, nats :4222, minio :9100, mediamtx :9997
 *   nix build .#hnvr-web && ./result/bin/hnvr-leader
 *   # Run tests:
 *   npm test
 *
 * The base URL matches the devenv `PORT=18001` env (see flake.nix).
 * Override at runtime with `BASE_URL=http://other:port npm test`.
 *
 * See design_docs/09-testing.md §"Web UI" for the framework choice
 * rationale (Playwright over Cypress / hs-webdriver — WebRTC + WHEP
 * session lifecycle, multi-browser).
 */
export default defineConfig({
  testDir: './tests',
  fullyParallel: false,          // IHP schema + shared dev DB; avoid concurrent writes
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: 1,                    // single-worker — the test DB is shared
  reporter: process.env.CI
    ? [['github'], ['junit', { outputFile: 'results.xml' }], ['list']]
    : 'list',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  use: {
    baseURL: process.env.BASE_URL ?? 'http://127.0.0.1:18001',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: {...devices['Desktop Chrome']},
    },
    // Firefox + WebKit can be enabled once the WHEP/HLS.js surface
    // needs cross-browser coverage. design_docs/09-testing.md §"Web UI".
  ],
});
