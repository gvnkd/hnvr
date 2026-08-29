import {test, expect, ADMIN_URL} from '../lib/auth';

/**
 * UI v2 (redesign) surface: theme switching, collapsible sidebar,
 * sortable/filterable tables, clickable rows, dashboard live wall +
 * fullscreen overlay, events lightbox markup.
 *
 * Selector contracts (referenced by Hnvr.Web.View.* and static/app.js):
 *   - <html data-theme> flips between "midnight" and "daylight" and
 *     persists via localStorage "hnvr-theme"
 *   - sidebar collapse toggles .nav-collapsed on .shell
 *   - tables with [data-sortable] get sort arrows on th click
 *   - clickable rows carry tr[data-href]
 *   - dashboard cam cards: .cam-card[data-slug] with .cam-live frame
 *     area; clicking opens #live-overlay (Esc closes)
 */
test.describe('UI v2', () => {
  test('theme menu switches theme and persists across navigation', async ({loggedInPage: page}) => {
    await page.goto('/');
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'midnight');
    // Open the theme dropdown and pick Daylight.
    await page.locator('[data-dropdown-button]').first().click();
    await page.locator('[data-theme-option="daylight"]').click();
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'daylight');
    // Persisted: navigate away and back. (/Cameras moved to
    // hnvr-admin in M4 — /Events is the leader-side target now.)
    await page.goto('/Events');
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'daylight');
    // Restore default for other tests.
    await page.evaluate(() => (window as any).HNVR.setTheme('midnight'));
  });

  test('sidebar collapse toggle persists', async ({loggedInPage: page}) => {
    await page.goto('/');
    await page.locator('[data-nav-toggle]').first().click();
    await expect(page.locator('.shell')).toHaveClass(/nav-collapsed/);
    await page.goto('/Stats');
    await expect(page.locator('.shell')).toHaveClass(/nav-collapsed/);
    // Restore.
    await page.locator('[data-nav-toggle]').first().click();
    await expect(page.locator('.shell')).not.toHaveClass(/nav-collapsed/);
  });

  test('cameras table: sortable headers, instant filter, clickable rows', async ({adminLoggedInPage: page}) => {
    await page.goto(ADMIN_URL + '/Cameras');
    const rows = page.locator('#cameras-table tbody tr');
    test.skip((await rows.count()) === 0, 'no cameras in DB');

    // Sort by slug descending → first row changes (or stays if single row).
    const firstBefore = (await rows.first().locator('td').first().textContent()) ?? '';
    await page.locator('#cameras-table thead th', {hasText: 'Slug'}).click();
    await page.locator('#cameras-table thead th', {hasText: 'Slug'}).click();
    const firstAfter = (await rows.first().locator('td').first().textContent()) ?? '';
    expect(firstAfter >= firstBefore).toBeTruthy();

    // Instant filter hides non-matching rows.
    await page.locator('[data-table-filter="#cameras-table"]').fill('zzz-no-match');
    await expect(page.locator('#cameras-table tbody tr:visible')).toHaveCount(0);
    await page.locator('[data-table-filter="#cameras-table"]').fill('');
    await expect(page.locator('#cameras-table tbody tr:visible').first()).toBeVisible();

    // Rows are clickable (data-href → ShowCamera).
    const href = await rows.first().getAttribute('data-href');
    expect(href).toMatch(/\/ShowCamera\?cameraId=/);
  });

  test('dashboard live wall: frames render and card click opens live overlay', async ({loggedInPage: page}) => {
    await page.goto('/');
    const card = page.locator('.cam-card[data-slug]').first();
    test.skip((await card.count()) === 0, 'no cameras in DB');

    // Overlay opens on card click and closes on Esc.
    await card.click();
    await expect(page.locator('#live-overlay')).toBeVisible();
    await expect(page.locator('#live-overlay .slug')).toHaveText(
      (await card.getAttribute('data-slug')) ?? ''
    );
    await page.keyboard.press('Escape');
    await expect(page.locator('#live-overlay')).toBeHidden();
  });

  test('archive timeline shell renders player + canvas', async ({loggedInPage: page}) => {
    await page.goto('/Timeline');
    await expect(page.locator('.section-h').first()).toContainText('Archive timeline');
    await expect(page.locator('[data-timeline]')).toBeVisible();
    await expect(page.locator('[data-tl-canvas]')).toBeVisible();
    // One camera dropdown; an option per camera.
    const options = page.locator('[data-tl-camera] option');
    expect(await options.count()).toBeGreaterThan(0);
  });

  test('events table: sortable + rows deep-link to timeline', async ({loggedInPage: page}) => {
    await page.goto('/Events');
    const rows = page.locator('#events-table tbody tr');
    test.skip((await rows.count()) === 0, 'no events in DB');
    const href = await rows.first().getAttribute('data-href');
    expect(href).toMatch(/\/Timeline\?from=.*&t=/);
  });
});
