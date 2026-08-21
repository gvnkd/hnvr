import {test, expect} from '../lib/auth';

/**
 * Unified archive timeline (/Timeline, design_docs/12-timeline-archive.md).
 *
 * The canvas internals are pixel-level and the snapshot store needs a
 * running node, so assertions target the DOM/contracts: shell, window
 * math, toggle persistence, purge form wiring. Segment/event data in
 * the dev DB comes from the live capture pipeline, so data-dependent
 * assertions are conditional (same convention as the events specs).
 */
test.describe('Archive timeline', () => {
  test('unauthenticated access redirects to login', async ({page}) => {
    await page.goto('/Timeline');
    await page.waitForURL(/\/NewSession/);
  });

  test('shell renders with a 24h default window', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const root = page.locator('[data-timeline]');
    await expect(root).toBeVisible();
    const from = Date.parse((await root.getAttribute('data-from'))!);
    const to = Date.parse((await root.getAttribute('data-to'))!);
    expect(to - from).toBe(24 * 3600 * 1000);
    // 24h preset is the active one.
    await expect(page.locator('.tl-rangebar a', {hasText: '24h'})).toHaveClass(/btn-primary/);
  });

  test('range preset narrows the window', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    await page.locator('.tl-rangebar a', {hasText: '1h'}).click();
    await page.waitForURL(/\/Timeline\?from=/);
    const root = page.locator('[data-timeline]');
    const from = Date.parse((await root.getAttribute('data-from'))!);
    const to = Date.parse((await root.getAttribute('data-to'))!);
    expect(to - from).toBe(3600 * 1000);
  });

  test('tiles fetch timeline data and leave thumbnail mode', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const resp = await page.waitForResponse(/\/TimelineData\?from=/);
    expect(resp.status()).toBe(200);
    const data = await resp.json();
    expect(data.cameras.length).toBeGreaterThan(0);
    // Tiles settle out of "idle" once data lands (snapshot 404s are
    // expected until a node produces camera_snapshots rows — the tile
    // shows its gap/no-frame placeholder then).
    await expect
      .poll(async () => page.locator('[data-tl-state]').first().textContent())
      .not.toBe('idle');
  });

  test('cursor drag updates the cursor label', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const canvas = page.locator('[data-tl-canvas]');
    const box = (await canvas.boundingBox())!;
    const before = await page.locator('[data-tl-cursor-label]').textContent();
    await page.mouse.move(box.x + box.width * 0.8, box.y + 20);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width * 0.2, box.y + 20, {steps: 5});
    await page.mouse.up();
    const after = await page.locator('[data-tl-cursor-label]').textContent();
    expect(after).not.toBe(before);
  });

  test('only the active camera plays; clicking a tile switches active', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    await page.waitForResponse(/\/TimelineData\?from=/);
    // First tile is the default active camera.
    await expect(page.locator('[data-tl-tile]').first()).toHaveClass(/tl-active/);
    // Drag-release seeks; at most ONE video element may exist (N
    // concurrent hls.js instances was the lag Sergey reported).
    const canvas = page.locator('[data-tl-canvas]');
    const box = (await canvas.boundingBox())!;
    await page.mouse.move(box.x + box.width * 0.9, box.y + 20);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width * 0.85, box.y + 20, {steps: 3});
    await page.mouse.up();
    await page.waitForTimeout(500);
    expect(await page.locator('.tl-tile-video').count()).toBeLessThanOrEqual(1);
    // Click the second tile: active class moves over.
    const second = page.locator('[data-tl-tile]').nth(1);
    await second.locator('.tl-tile-head').click();
    await expect(second).toHaveClass(/tl-active/);
    await expect(page.locator('[data-tl-tile]').first()).not.toHaveClass(/tl-active/);
    // Persisted across reload.
    await page.reload();
    await expect(page.locator('[data-tl-tile]').nth(1)).toHaveClass(/tl-active/);
    // Restore default for the shared browser profile.
    await page.locator('[data-tl-tile]').first().locator('.tl-tile-head').click();
  });

  test('disable toggle persists across reload', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const first = page.locator('[data-tl-toggle]').first();
    await first.uncheck();
    await page.reload();
    await expect(page.locator('[data-tl-toggle]').first()).not.toBeChecked();
    await expect(page.locator('[data-tl-state]').first()).toContainText('disabled');
    // Restore default for other tests/users of the shared browser profile.
    await page.locator('[data-tl-toggle]').first().check();
  });

  test('deep link with t= clamps cursor into the window', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const root = page.locator('[data-timeline]');
    const from = (await root.getAttribute('data-from'))!;
    const to = (await root.getAttribute('data-to'))!;
    const mid = new Date((Date.parse(from) + Date.parse(to)) / 2).toISOString();
    await page.goto(`/Timeline?from=${from}&to=${to}&t=${mid}`);
    const cursor = Date.parse((await page.locator('[data-timeline]').getAttribute('data-cursor'))!);
    expect(Math.abs(cursor - Date.parse(mid))).toBeLessThan(1000);
  });

  test('admin purge forms post prefixed window params', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const forms = page.locator('form.tl-purge-form');
    test.skip((await forms.count()) === 0, 'not an admin user');
    const first = forms.first();
    const action = await first.getAttribute('action');
    expect(action).toMatch(/\/PurgeRecording\?purgeCameraId=/);
    // purgeFrom/purgeTo are hidden INPUTS, never URL params.
    expect(action).not.toMatch(/purgeFrom/);
    expect(action).not.toMatch(/purgeTo/);
    await expect(first.locator('input[name="purgeFrom"]')).toHaveCount(1);
    await expect(first.locator('input[name="purgeTo"]')).toHaveCount(1);
    // Never submitted here: the purge window is the whole timeline
    // window — clicking it on the shared dev DB would tombstone a full
    // day of recordings.
  });
});
