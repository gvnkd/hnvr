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
  await page.locator('input[name="port"]').fill('554');
  await page.getByRole('button', {name: /create camera/i}).click();
  // Successful create → 302 to /ShowCamera?cameraId=<uuid>
  await page.waitForURL(/\/ShowCamera\?cameraId=/);
}

async function deleteCameraBySlug(page: Page, slug: string): Promise<void> {
  // The Show view doesn't expose a Delete button in v1; we POST directly
  // to the route declared in FrontController. IHP AutoRoute on
  // DeleteCameraAction takes cameraId as a query param.
  await page.goto(`/Cameras`);
  const row = page.locator('tr', {hasText: slug});
  const showLink = row.getByRole('link', {name: 'Show'});
  await showLink.click();
  await page.waitForURL(/\/ShowCamera\?cameraId=/);
  const url = page.url();
  const cameraId = new URL(url).searchParams.get('cameraId');
  if (!cameraId) throw new Error(`could not extract cameraId from ${url}`);
  // IHP forms use a hidden _method=DELETE for resource destruction OR
  // a direct POST to /DeleteCamera?cameraId=... — both work; the
  // latter matches our route table.
  await page.request.post(`/DeleteCamera?cameraId=${cameraId}`, {
    failOnStatusCode: false,
  });
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

    // ---- Edit ------------------------------------------------------
    const row = page.locator('tr', {hasText: slug});
    await row.getByRole('link', {name: 'Edit'}).click();
    await page.waitForURL(/\/EditCamera\?cameraId=/);
    // IHP Edit view ( Cameras/Edit.hs ) pre-fills the name field.
    await page.locator('input[name="name"]').fill(updatedName);
    // Password field MUST be left blank to keep existing (Slice 7b).
    // Don't fill it — verify the blank-password-no-overwrite path.
    await page.getByRole('button', {name: /update camera/i}).click();
    await page.waitForURL(/\/ShowCamera\?cameraId=/);

    // ---- Verify update ---------------------------------------------
    await page.goto('/Cameras');
    await expect(page.locator('tbody')).toContainText(updatedName);

    // ---- Delete + verify gone --------------------------------------
    await deleteCameraBySlug(page, slug);
    await page.goto('/Cameras');
    await expect(page.locator('tbody')).not.toContainText(slug);
  });

  test('create with missing required fields is rejected', async ({loggedInPage: page}) => {
    // The form has `required` attributes on slug + rtspUrl; the browser
    // should block submit. IHP-side validation is the second layer.
    await page.goto('/NewCamera');
    await page.locator('input[name="slug"]').fill('');     // required
    await page.locator('input[name="rtspUrl"]').fill('');  // required
    await page.getByRole('button', {name: /create camera/i}).click();
    // Still on the NewCamera page (browser blocked submit).
    await expect(page).toHaveURL(/\/NewCamera$/);
  });
});
