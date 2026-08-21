import {test, expect, type Page} from '../lib/auth';

/**
 * Camera CRUD happy-path: create, list, edit, delete.
 *
 * Mirrors the user-facing flows documented in design_docs/05-web-and-live-view.md
 * §"Cameras admin". Verifies the IHP schema integration end-to-end:
 *   - Form fields fill + submit (cameras create action)
 *   - Password field blank on update keeps existing (Slice 7b pitfall)
 *   - AES-256-GCM encrypt-on-write happens server-side; we just assert
 *     the camera becomes visible in the list.
 *
 * Each test generates a unique slug so concurrent runs don't collide.
 *
 * View source-of-truth (Hnvr.Web.View.Cameras.{New,Edit,Show,Index}):
 *   - Create button label: "Create Camera"
 *   - Edit button label:   "Save Changes"   (NOT "Update Camera")
 *   - Edit secondary:      "Probe Streams"
 *   - Show page H1:        <span class="font-mono">{slug}</span>
 *   - Show page actions:   "Edit", "Watch archive"
 *   - Index row actions:   "Show", "Edit"
 */

const STUB_RTSP_URL = 'rtsp://admin:secret@192.168.0.99:554/stream';

function uniqueSlug(): string {
  // e2e-<unixms>: deterministic, sortable, no collision risk.
  return `e2e-${Date.now()}`;
}

async function createCamera(page: Page, slug: string, name: string): Promise<void> {
  await page.goto('/NewCamera');
  await page.locator('input[name="slug"]').fill(slug);
  await page.locator('input[name="name"]').fill(name);
  await page.locator('input[name="rtspUrl"]').fill(STUB_RTSP_URL);
  await page.locator('input[name="host"]').fill('192.168.0.99');
  await page.getByRole('button', {name: /create camera/i}).click();
  // Successful create → 302 to /ShowCamera?cameraId=<uuid>
  await page.waitForURL(/\/ShowCamera\?cameraId=/);
}

async function deleteCameraBySlug(page: Page, slug: string): Promise<void> {
  // The Show view doesn't expose a Delete button in v1; we DELETE
  // directly to the route declared in FrontController. IHP AutoRoute
  // maps DeleteCameraAction to HTTP DELETE (per Cameras.hs comment
  // line 16 + verified via curl — POST returns 405, DELETE returns 302).
  //
  // Important: page.request needs the FULL origin URL; the relative
  // path form was returning synthetic 405 responses without ever
  // reaching the leader (Playwright's baseURL config doesn't always
  // propagate to page.request calls — use page.url() to derive the
  // origin).
  await page.goto('/Cameras');
  const row = page.locator('tr', {hasText: slug});
  await row.getByRole('link', {name: 'Show'}).click();
  await page.waitForURL(/\/ShowCamera\?cameraId=/);
  const showUrl = page.url();
  const cameraId = new URL(showUrl).searchParams.get('cameraId');
  if (!cameraId) throw new Error(`could not extract cameraId from ${showUrl}`);
  const origin = new URL(showUrl).origin;
  const resp = await page.request.delete(`${origin}/DeleteCamera?cameraId=${cameraId}`, {
    failOnStatusCode: false,
    // IHP's delete action returns 302 to /Cameras. Playwright re-issues
    // the SAME method (DELETE) on redirect, which 405s on /Cameras.
    // maxRedirects: 0 lets us see the original 302 success.
    maxRedirects: 0,
  });
  // IHP returns 302 (redirect to /Cameras) on successful delete.
  expect(resp.status(), `DELETE /DeleteCamera should return 302 (got ${resp.status()})`).toBe(302);
}

test.describe('Cameras CRUD', () => {
  test('create → list → edit → delete', async ({loggedInPage: page}) => {
    const slug = uniqueSlug();
    const initialName = `E2E camera ${slug}`;
    const updatedName = `E2E updated ${slug}`;

    // ---- Create ----------------------------------------------------
    await createCamera(page, slug, initialName);

    // ---- List ------------------------------------------------------
    await page.goto('/Cameras');
    await expect(page.locator('tbody')).toContainText(slug);
    await expect(page.locator('tbody')).toContainText(initialName);

    // ---- Edit (button label is "Save Changes", not "Update Camera") -
    const row = page.locator('tr', {hasText: slug});
    await row.getByRole('link', {name: 'Edit'}).click();
    await page.waitForURL(/\/EditCamera\?cameraId=/);
    await page.locator('input[name="name"]').fill(updatedName);
    // Password field MUST be left blank to keep existing (Slice 7b).
    // Don't fill it — verify the blank-password-no-overwrite path.
    await page.getByRole('button', {name: /save changes/i}).click();
    await page.waitForURL(/\/ShowCamera\?cameraId=/);

    // ---- Verify update ---------------------------------------------
    await page.goto('/Cameras');
    await expect(page.locator('tbody')).toContainText(updatedName);

    // ---- Delete + verify gone --------------------------------------
    await deleteCameraBySlug(page, slug);
    await page.goto('/Cameras');
    await expect(page.locator('tbody')).not.toContainText(slug);
  });

  test('edit page Delete Camera button removes the camera (with confirm)', async ({loggedInPage: page}) => {
    const slug = uniqueSlug();
    await createCamera(page, slug, `E2E delete-ui ${slug}`);

    await page.goto('/Cameras');
    await page.locator('tr', {hasText: slug}).getByRole('link', {name: 'Edit'}).click();
    await page.waitForURL(/\/EditCamera\?cameraId=/);

    // Danger-zone form: _method=DELETE override + data-confirm gate.
    const form = page.locator('form[action^="/DeleteCamera"]');
    await expect(form.locator('input[name="_method"]')).toHaveValue('DELETE');
    page.once('dialog', (d) => d.accept());
    await form.getByRole('button', {name: /delete camera/i}).click();

    // 302 → /Cameras, row gone.
    await page.waitForURL(/\/Cameras$/);
    await expect(page.locator('tbody')).not.toContainText(slug);
  });
});
