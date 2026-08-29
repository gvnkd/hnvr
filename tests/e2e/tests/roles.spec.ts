import {test, expect, firstCamera, login, ADMIN_URL, loginAdmin, type Page} from '../lib/auth';

/**
 * Roles & ACL enforcement end-to-end (design_docs/13, M5).
 *
 * Runs against BOTH services: hnvr-admin (ADMIN_URL) owns role/user/camera
 * mutations; the leader (baseURL) enforces the resulting grants. Every
 * fixture (e2e-* role/user/camera) is removed in a finally block — the
 * dev DB is shared with the live leader.
 *
 * Scenarios (design rollout §5):
 *   1. hidden camera: no DOM card, /ShowLive 403, /whep 404
 *   2. PTZ markup hidden without ptz_move/ptz_preset
 *   3. purge 403 without purge_archive
 *   4. admin role edit propagates to the leader via LISTEN/NOTIFY
 *      cache invalidation
 */

const TS = Date.now();
const ROLE = `e2e-viewer-${TS}`;
const USER_EMAIL = `e2e-viewer-${TS}@hnvr.local`;
const USER_PW = 'e2e-viewer-pw';
const CAM_SLUG = `e2e-hidden-${TS}`;

/** Admin-UI helpers ------------------------------------------------ */

async function adminCreateRole(page: Page, name: string): Promise<void> {
  await page.goto(`${ADMIN_URL}/NewRole`);
  await page.locator('input[name="name"]').fill(name);
  // dashboard + live pages only; no camera grants.
  await page.locator('input[name="page_dashboard"]').check();
  await page.locator('input[name="page_live"]').check();
  await page.getByRole('button', {name: /create role/i}).click();
  await page.waitForURL(/\/Roles$/);
}

async function adminCreateUser(page: Page, email: string, password: string, roleName: string): Promise<void> {
  await page.goto(`${ADMIN_URL}/NewUser`);
  await page.locator('input[name="email"]').fill(email);
  await page.locator('input[name="password"]').fill(password);
  await page.locator('label.check', {hasText: roleName}).locator('input[type="checkbox"]').check();
  await page.getByRole('button', {name: /create user/i}).click();
  await page.waitForURL(/\/Users$/);
}

async function adminCreateCamera(page: Page, slug: string): Promise<string> {
  await page.goto(`${ADMIN_URL}/NewCamera`);
  await page.locator('input[name="slug"]').fill(slug);
  await page.locator('input[name="name"]').fill(`E2E hidden ${slug}`);
  await page.locator('input[name="rtspUrl"]').fill('rtsp://admin:secret@192.168.0.99:554/stream');
  await page.locator('input[name="host"]').fill('192.168.0.99');
  await page.locator('input[name="enabled"]').check();
  await page.getByRole('button', {name: /create camera/i}).click();
  await page.waitForURL(/\/ShowCamera\?cameraId=/);
  return new URL(page.url()).searchParams.get('cameraId')!;
}

/** Grant view_live on ONE camera via the role's override matrix. */
async function adminGrantViewLiveOn(page: Page, roleName: string, camId: string): Promise<void> {
  await page.goto(`${ADMIN_URL}/Roles`);
  await page.locator('tr', {hasText: roleName}).getByRole('link', {name: 'Edit'}).click();
  await page.waitForURL(/\/EditRole\?roleId=/);
  await page.locator(`input[name="ovr_on_${camId}"]`).check();
  await page.locator(`input[name="ovr_${camId}_view_live"]`).check();
  await page.getByRole('button', {name: /save role/i}).click();
  await page.waitForURL(/\/Roles$/);
}

async function adminDeleteRole(page: Page, name: string): Promise<void> {
  await page.goto(`${ADMIN_URL}/Roles`);
  const row = page.locator('tr', {hasText: name});
  if ((await row.count()) === 0) return;
  page.once('dialog', (d: import('@playwright/test').Dialog) => d.accept());
  await row.getByRole('button', {name: /delete/i}).click();
  await page.waitForURL(/\/Roles$/);
}

async function adminDeleteUser(page: Page, email: string): Promise<void> {
  await page.goto(`${ADMIN_URL}/Users`);
  const row = page.locator('tr', {hasText: email});
  if ((await row.count()) === 0) return;
  page.once('dialog', (d: import('@playwright/test').Dialog) => d.accept());
  await row.getByRole('button', {name: /delete/i}).click();
  await page.waitForURL(/\/Users$/);
}

async function adminDeleteCamera(page: Page, camId: string): Promise<void> {
  const origin = ADMIN_URL;
  await page.goto(`${origin}/EditCamera?cameraId=${camId}`);
  const form = page.locator('form[action^="/DeleteCamera"]');
  if ((await form.count()) === 0) return;
  page.once('dialog', (d: import('@playwright/test').Dialog) => d.accept());
  await form.getByRole('button', {name: /delete camera/i}).click();
  await page.waitForURL(/\/Cameras$/);
}

test.describe('Roles & ACL (M5)', () => {
  test.describe.configure({mode: 'serial'}); // fixtures build on each other

  let hiddenCamId = '';
  let visibleCamId = '';

  test('setup: viewer role+user, hidden camera', async ({adminLoggedInPage: page}) => {
    // An existing camera the viewer MAY watch (dashboard has one when
    // the suite runs against the dev DB).
    const cam = await firstCamera(page);
    test.skip(!cam, 'no cameras in DB — run cameras-crud.spec first');
    visibleCamId = cam!.id;

    hiddenCamId = await adminCreateCamera(page, CAM_SLUG);
    await adminCreateRole(page, ROLE);
    await adminCreateUser(page, USER_EMAIL, USER_PW, ROLE);
    // view_live on the EXISTING camera only (per-camera override) — the
    // throwaway camera stays hidden from the viewer.
    await adminGrantViewLiveOn(page, ROLE, visibleCamId);
  });

  test('hidden camera: no DOM card, ShowLive 403, WHEP 404', async ({page}) => {
    test.skip(!hiddenCamId, 'setup did not run');
    await login(page, USER_EMAIL, USER_PW);
    await page.goto('/');
    // Visible camera renders, hidden one does not.
    await expect(page.locator(`.cam-card[data-cam-id="${visibleCamId}"]`)).toBeVisible();
    await expect(page.locator(`.cam-card[data-cam-id="${hiddenCamId}"]`)).toHaveCount(0);

    // /ShowLive on the hidden camera: 403 (enforced, not just hidden).
    const get = await page.request.get(`/ShowLive?cameraId=${hiddenCamId}`, {failOnStatusCode: false});
    expect(get.status()).toBe(403);

    const whep = await page.request.post(`/whep/${CAM_SLUG}`, {
      data: 'v=0',
      headers: {'Content-Type': 'application/sdp'},
      failOnStatusCode: false,
    });
    expect(whep.status()).toBe(404);
  });

  test('PTZ markup hidden without ptz_move', async ({page}) => {
    test.skip(!hiddenCamId, 'setup did not run');
    await login(page, USER_EMAIL, USER_PW);
    await page.goto(`/ShowLive?cameraId=${visibleCamId}`);
    // The viewer has view_live but no PTZ grant: no toggle, no drawer,
    // regardless of the camera's ptz_enabled flag.
    await expect(page.locator('[data-ptz-toggle]')).toHaveCount(0);
    await expect(page.locator('#ptz-panel')).toHaveCount(0);
  });

  test('purge 403 without purge_archive', async ({page}) => {
    test.skip(!hiddenCamId, 'setup did not run');
    await login(page, USER_EMAIL, USER_PW);
    const resp = await page.request.post(
      `/PurgeRecording?purgeCameraId=${visibleCamId}&purgeFrom=2026-01-01T00:00:00Z&purgeTo=2026-01-01T01:00:00Z`,
      {failOnStatusCode: false, maxRedirects: 0}
    );
    expect(resp.status()).toBe(403);
  });

  test('admin role edit propagates (NOTIFY cache invalidation)', async ({page, adminLoggedInPage: adminPage}) => {
    test.skip(!hiddenCamId, 'setup did not run');
    // Grant the viewer view_live on the hidden camera via the admin UI…
    await adminGrantViewLiveOn(adminPage, ROLE, hiddenCamId);
    // …and the leader picks it up without restart (LISTEN roles_events
    // busts the RoleSet cache; poll a few seconds for the async beat).
    await login(page, USER_EMAIL, USER_PW);
    await expect
      .poll(
        async () => {
          await page.goto('/');
          return page.locator(`.cam-card[data-cam-id="${hiddenCamId}"]`).count();
        },
        {timeout: 10_000, message: 'granted camera should appear after role edit'}
      )
      .toBe(1);
  });

  test.afterAll(async ({browser}) => {
    // Full cleanup — the dev DB is shared with the live leader.
    const ctx = await browser.newContext({baseURL: ADMIN_URL});
    const page = await ctx.newPage();
    await loginAdmin(page);
    await adminDeleteUser(page, USER_EMAIL);
    await adminDeleteRole(page, ROLE);
    if (hiddenCamId) await adminDeleteCamera(page, hiddenCamId);
    await ctx.close();
  });
});
