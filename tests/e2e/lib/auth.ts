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
 * hnvr-admin (design_docs/13): management mutations moved off the
 * leader (M4). The admin service has its own port, bind address and
 * session cookie ("hnvr_admin" — a leader session grants nothing here).
 */
export const ADMIN_URL = process.env.ADMIN_URL ?? 'http://127.0.0.1:18010';

/**
 * Test fixture that extends Playwright's `test` with a `loggedInPage`
 * helper — logs in via the UI once per test (cheap; the form is one
 * POST + one 302). Future tests that don't care about login state can
 * still use the regular `page` fixture.
 *
 * `adminLoggedInPage` does the same against hnvr-admin (ADMIN_URL) for
 * the specs covering management mutations (cameras-crud, rules, roles).
 */
export const test = base.extend<{loggedInPage: Page; adminLoggedInPage: Page}>({
  loggedInPage: async ({page}, use) => {
    await login(page);
    await use(page);
  },
  adminLoggedInPage: async ({page}, use) => {
    await loginAdmin(page);
    await use(page);
  },
});

export {expect};
export type {Page};

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

/**
 * Same form on hnvr-admin (absolute URLs — the admin service is a
 * different origin than baseURL).
 */
export async function loginAdmin(page: Page, email = ADMIN_EMAIL, password = ADMIN_PASSWORD): Promise<void> {
  await page.goto(`${ADMIN_URL}/NewSession`);
  await page.locator('#email').fill(email);
  await page.locator('#password').fill(password);
  await page.getByRole('button', {name: /login/i}).click();
  await page.waitForURL(/\/$|\/Overview$/);
}

/**
 * Scrape the first dashboard camera card's (id, slug) — the leader's
 * read path for "pick a camera" after the M4 move (dashboard cards
 * carry data-cam-id / data-slug).
 */
export async function firstCamera(page: Page): Promise<{id: string; slug: string} | null> {
  await page.goto('/');
  const card = page.locator('.cam-card').first();
  if ((await card.count()) === 0) return null;
  const id = await card.getAttribute('data-cam-id');
  const slug = await card.getAttribute('data-slug');
  if (!id || !slug) return null;
  return {id, slug};
}
