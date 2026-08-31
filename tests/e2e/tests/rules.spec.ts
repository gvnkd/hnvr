import {test, expect, firstCamera, ADMIN_URL} from '../lib/auth';

/**
 * Rules CRUD with the drawing canvas (Phase 4). Drives the real UI:
 * canvas clicks produce the geometry JSON, the form POSTs it, and the
 * rule round-trips through the DB into the list + edit views.
 *
 * M4 (design_docs/13): rules management moved to hnvr-admin — these
 * specs run against ADMIN_URL with the admin session cookie. Requires:
 * devenv services up + hnvr-admin on :18010 with at least one camera.
 */

async function firstCameraUuid(page: import('@playwright/test').Page): Promise<string> {
  await page.goto(`${ADMIN_URL}/Cameras`);
  const href = await page.locator('a[href*="ShowCamera?cameraId="]').first().getAttribute('href');
  expect(href).toBeTruthy();
  return href!.split('cameraId=')[1];
}

/**
 * Click the rule canvas at normalized (nx, ny). The canvas resizes
 * when the background still loads, so positions are computed from the
 * live bounding box at click time.
 */
async function canvasClick(page: import('@playwright/test').Page, nx: number, ny: number): Promise<void> {
  const canvas = page.locator('#rule-canvas');
  await canvas.scrollIntoViewIfNeeded();
  const box = (await canvas.boundingBox())!;
  await page.mouse.click(box.x + box.width * nx, box.y + box.height * ny);
}

/** Wait until the background still has loaded (canvas aspect follows the image). */
async function waitForCanvasReady(page: import('@playwright/test').Page): Promise<void> {
  // img.onload recomputes canvas.height from the still's aspect ratio
  // and redraws; give it a moment (local fetch, ~100ms) plus slack.
  await page.waitForTimeout(1500);
}

test('rules: create via canvas, edit prefill, purge', async ({adminLoggedInPage: page}) => {
  const camUuid = await firstCameraUuid(page);

  // --- Create with a canvas-drawn line --------------------------------
  await page.goto(`${ADMIN_URL}/NewRule?ruleCameraId=${camUuid}`);
  await page.locator('#name').fill('playwright line');
  await page.locator('#rule-kind').selectOption('line_cross');

  const canvas = page.locator('#rule-canvas');
  await waitForCanvasReady(page);
  await canvasClick(page, 0.2, 0.5);
  await canvasClick(page, 0.7, 0.5);

  // The hidden geometry input must carry the 2-click line (normalized).
  await expect(page.locator('#rule-geometry')).toHaveValue(/"a":\s*\[/);
  await expect(page.locator('#rule-geometry')).toHaveValue(/"b":\s*\[/);

  await page.getByRole('button', {name: /save rule/i}).click();

  // Lands on the Edit page (prefilled).
  await page.waitForURL(/\/EditRule\?ruleId=/);
  await expect(page.locator('#name')).toHaveValue('playwright line');
  await expect(page.locator('#rule-geometry')).toHaveValue(/"a":\s*\[/);

  // --- List shows it ---------------------------------------------------
  await page.goto(`${ADMIN_URL}/Rules`);
  await expect(page.locator('td', {hasText: 'playwright line'})).toBeVisible();

  // --- Purge -----------------------------------------------------------
  await page.goto(`${ADMIN_URL}/Rules`);
  const row = page.locator('tr', {hasText: 'playwright line'});
  page.once('dialog', (d) => d.accept()); // data-confirm gate on the delete form
  await row.getByRole('button', {name: /delete/i}).click();
  await expect(page.locator('td', {hasText: 'playwright line'})).toHaveCount(0);
});

test('rules: zone polygon via canvas (3+ clicks, finish)', async ({adminLoggedInPage: page}) => {
  const camUuid = await firstCameraUuid(page);

  await page.goto(`${ADMIN_URL}/NewRule?ruleCameraId=${camUuid}`);
  await page.locator('#name').fill('playwright zone');
  await page.locator('#rule-kind').selectOption('zone_enter');

  const canvas = page.locator('#rule-canvas');
  await waitForCanvasReady(page);
  await canvasClick(page, 0.2, 0.2);
  await canvasClick(page, 0.7, 0.2);
  await canvasClick(page, 0.45, 0.8);
  await page.locator('#rule-finish').click();

  await expect(page.locator('#rule-geometry')).toHaveValue(/"polygon":\s*\[\s*\[/);
  await page.getByRole('button', {name: /save rule/i}).click();
  await page.waitForURL(/\/EditRule\?ruleId=/);
  await expect(page.locator('#name')).toHaveValue('playwright zone');

  await page.goto(`${ADMIN_URL}/Rules`);
  const row = page.locator('tr', {hasText: 'playwright zone'});
  page.once('dialog', (d) => d.accept()); // data-confirm gate on the delete form
  await row.getByRole('button', {name: /delete/i}).click();
  await expect(page.locator('td', {hasText: 'playwright zone'})).toHaveCount(0);
});

test('events page: table renders with kind badges and play links', async ({loggedInPage: page}) => {
  await page.goto('/Events');
  await expect(page.locator('h1')).toHaveText('Events');
  await expect(page.locator('th', {hasText: 'Kind'})).toBeVisible();
  // Deep-links into the archive player exist when events are present.
  const playLinks = page.locator('a[href*="PlayerArchive?cameraId="]');
  if ((await playLinks.count()) > 0) {
    await expect(playLinks.first()).toHaveAttribute('href', /&t=/);
  }
});

test('live view: event feed panel populates via the fragment poller', async ({loggedInPage: page}) => {
  // Leader read path (M4): camera id from the dashboard card.
  const cam = await firstCamera(page);
  test.skip(!cam, 'no cameras in DB');
  await page.goto(`/ShowLive?cameraId=${cam!.id}`);
  // The feed panel refreshes from /EventsFeedLive every 5s; first
  // fetch happens on load. The fragment's .event-feed wrapper always
  // renders (with rows or the empty state inside).
  await expect(page.locator('#hnvr-live-feed .event-feed')).toBeVisible({timeout: 10_000});
});
