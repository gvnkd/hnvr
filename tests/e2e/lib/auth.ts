import {test as base, expect, type Page } from '@playwright/test';

/**
 * Bootstrap admin credentials. Match the devenv env block in flake.nix:
 *   INITIAL_ADMIN_EMAIL = "admin@hnvr.local";
 *   INITIAL_ADMIN_PASSWORD = "hnvr-dev";
 * Override at runtime with HNVR_ADMIN_EMAIL / HNVR_ADMIN_PASSWORD for
 * non-devenv environments (e.g. staging).
 */
const ADMIN_EMAIL = process.env.HNVR_ADMIN_EMAIL ?? 'admin@hnvr.local';
const ADMIN_PASSWORD = process.env.HNVR_ADMIN_PASSWORD ?? 'hnvr-dev';

/**
 * Test fixture that extends Playwright's `test` with a `loggedInPage`
 * helper — logs in via the UI once per test (cheap; the form is one
 * POST + one 302). Future tests that don't care about login state can
 * still use the regular `page` fixture.
 */
export const test = base.extend<{loggedInPage: Page}>({
  loggedInPage: async ({page}, use) => {
    await login(page);
    await use(page);
  },
});

export {expect};

/**
 * Drive the IHP login form. After this returns, `page` carries the
 * session cookie and subsequent navigations are authenticated.
 *
 * Verified against the form in Hnvr.Web.View.Sessions.New (id="email",
 * id="password", POST /CreateSession, 302 to / on success per pitfall
 * #58 — String→Text coercion fix).
 */
export async function login(page: Page, email = ADMIN_EMAIL, password = ADMIN_PASSWORD): Promise<void> {
  await page.goto('/NewSession');
  await page.locator('#email').fill(email);
  await page.locator('#password').fill(password);
  await page.getByRole('button', {name: /login/i}).click();
  // Successful login redirects to the dashboard. Use waitForURL to
  // catch the case where the form action resolves before the redirect.
  await page.waitForURL(/\/$|\/Dashboard$/);
}
