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

  test('player fetches timeline data and settles out of idle', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const resp = await page.waitForResponse(/\/TimelineData\?from=/);
    expect(resp.status()).toBe(200);
    const data = await resp.json();
    expect(data.cameras.length).toBeGreaterThan(0);
    // The player settles out of "idle" once data lands (snapshot 404s
    // are expected until a node produces camera_snapshots rows — the
    // player shows its gap/no-frame placeholder then).
    await expect
      .poll(async () => page.locator('[data-tl-state]').textContent())
      .not.toBe('idle');
  });

  test('cursor drag updates the cursor label', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const canvas = page.locator('[data-tl-canvas]');
    await canvas.scrollIntoViewIfNeeded();
    const box = (await canvas.boundingBox())!;
    const before = await page.locator('[data-tl-cursor-label]').textContent();
    await page.mouse.move(box.x + box.width * 0.8, box.y + 20);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width * 0.2, box.y + 20, {steps: 5});
    await page.mouse.up();
    const after = await page.locator('[data-tl-cursor-label]').textContent();
    expect(after).not.toBe(before);
  });

  test('single player; the dropdown switches the active camera', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    await page.waitForResponse(/\/TimelineData\?from=/);
    const sel = page.locator('[data-tl-camera]');
    const options = sel.locator('option');
    test.skip((await options.count()) < 2, 'need 2+ cameras');
    const firstId = (await options.nth(0).getAttribute('value'))!;
    const secondId = (await options.nth(1).getAttribute('value'))!;
    // First camera is the default active one.
    await expect(sel).toHaveValue(firstId);
    // Drag-release seeks; at most ONE video element may exist (N
    // concurrent hls.js instances was the lag Sergey reported).
    const canvas = page.locator('[data-tl-canvas]');
    await canvas.scrollIntoViewIfNeeded();
    const box = (await canvas.boundingBox())!;
    await page.mouse.move(box.x + box.width * 0.9, box.y + 20);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width * 0.85, box.y + 20, {steps: 3});
    await page.mouse.up();
    await page.waitForTimeout(500);
    expect(await page.locator('.tl-player-video').count()).toBeLessThanOrEqual(1);
    // Switch via the dropdown: value changes and persists across reload.
    await sel.selectOption(secondId);
    await expect(sel).toHaveValue(secondId);
    await page.reload();
    await expect(page.locator('[data-tl-camera]')).toHaveValue(secondId);
    // Restore default for the shared browser profile.
    await page.locator('[data-tl-camera]').selectOption(firstId);
  });

  test('hovering the timeline shows a scrub preview bubble', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    await page.waitForResponse(/\/TimelineData\?from=/);
    const canvas = page.locator('[data-tl-canvas]');
    await canvas.scrollIntoViewIfNeeded();
    const box = (await canvas.boundingBox())!;
    await page.mouse.move(box.x + box.width * 0.5, box.y + 20);
    const bubble = page.locator('.tl-hover-preview');
    await expect(bubble).toBeVisible();
    await expect(bubble.locator('.tl-hover-time')).not.toBeEmpty();
    // Moving the pointer moves the bubble (clamped inside the wrap).
    await page.mouse.move(box.x + box.width * 0.2, box.y + 20);
    await expect(bubble).toBeVisible();
    // Leaving the canvas hides it.
    await page.mouse.move(box.x + box.width * 0.5, box.y - 60);
    await expect(bubble).toBeHidden();
  });

  test('fullscreen button expands the whole panel', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    await page.locator('[data-tl-fs]').click();
    await expect
      .poll(async () =>
        page.evaluate(() => document.fullscreenElement?.classList.contains('tl-shell') ?? false)
      )
      .toBe(true);
    // The timeline strip must stay on screen in fullscreen (the player
    // grows to fill, the canvas keeps its own height).
    const canvasBox = await page.locator('[data-tl-canvas]').boundingBox();
    const viewport = page.viewportSize()!;
    expect(canvasBox).not.toBeNull();
    expect(canvasBox!.y).toBeGreaterThanOrEqual(0);
    expect(canvasBox!.y + canvasBox!.height).toBeLessThanOrEqual(viewport.height + 1);
    await page.locator('[data-tl-fs]').click();
    await expect
      .poll(async () => page.evaluate(() => document.fullscreenElement === null))
      .toBe(true);
  });

  test('prev/next event buttons jump the cursor between markers', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const resp = await page.waitForResponse(/\/TimelineData\?from=/);
    const data = await resp.json();
    const activeId = await page.locator('[data-tl-camera]').inputValue();
    const cam = data.cameras.find((c: any) => c.id === activeId);
    test.skip(!cam || cam.events.length === 0, 'no events for the active camera');
    // TimelineData markers are newest-first.
    const latest = cam.events.reduce((a: any, b: any) => (Date.parse(a.ts) > Date.parse(b.ts) ? a : b));
    const expected = await page.evaluate(
      (ts) => (window as any).HNVR.formatTs(ts),
      latest.ts
    );
    // Cursor starts at the window end (now) → "◀ event" lands on the
    // latest marker.
    await page.locator('[data-tl-prev-event]').click();
    await expect(page.locator('[data-tl-cursor-label]')).toHaveText(expected);
    // "event ▶" from the latest marker has nowhere to go.
    await page.locator('[data-tl-next-event]').click();
    await expect(page.locator('[data-tl-state]')).toContainText('no later event');
    await expect(page.locator('[data-tl-cursor-label]')).toHaveText(expected);
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

  test('admin purge form posts prefixed window params for the selected camera', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    const form = page.locator('form.tl-purge-form');
    test.skip((await form.count()) === 0, 'not an admin user');
    const action = await form.getAttribute('action');
    expect(action).toMatch(/\/PurgeRecording\?purgeCameraId=/);
    // purgeFrom/purgeTo are hidden INPUTS, never URL params.
    expect(action).not.toMatch(/purgeFrom/);
    expect(action).not.toMatch(/purgeTo/);
    await expect(form.locator('input[name="purgeFrom"]')).toHaveCount(1);
    await expect(form.locator('input[name="purgeTo"]')).toHaveCount(1);
    // The form follows the dropdown-selected camera.
    const sel = page.locator('[data-tl-camera]');
    const options = sel.locator('option');
    if ((await options.count()) > 1) {
      const secondId = (await options.nth(1).getAttribute('value'))!;
      await sel.selectOption(secondId);
      expect(await form.getAttribute('action')).toContain(`purgeCameraId=${secondId}`);
      await sel.selectOption((await options.nth(0).getAttribute('value'))!);
    }
    // Never submitted here: the purge window is the whole timeline
    // window — clicking it on the shared dev DB would tombstone a full
    // day of recordings.
  });
});
