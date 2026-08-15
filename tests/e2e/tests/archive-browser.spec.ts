import {test, expect} from '../lib/auth';

/**
 * Archive browser (/Archive).
 *
 * Covers the list/filter/search surface added in the archive-browser
 * slice. Segment rows in Postgres depend on a running capture pipeline,
 * so row-level assertions are conditional on data existing; the stable
 * surface (filter form, grouping caption, auth gate, pagination chrome)
 * is asserted unconditionally.
 */
test.describe('Archive browser', () => {
  test('unauthenticated access redirects to login', async ({page}) => {
    await page.goto('/Archive');
    await page.waitForURL(/\/NewSession/);
  });

  test('index renders filter form with all controls', async ({loggedInPage: page}) => {
    await page.goto('/Archive');
    const form = page.locator('form[action="/Archive"]');
    await expect(page.locator('h1')).toContainText('Archive');
    await expect(form.locator('select[name="cameraId"]')).toBeVisible();
    // name="from"/"to" also match hidden inputs in per-row delete
    // forms — scope everything to the filter form.
    await expect(form.locator('input[name="from"]')).toBeVisible();
    await expect(form.locator('input[name="to"]')).toBeVisible();
    await expect(form.locator('input[name="minDuration"]')).toBeVisible();
    await expect(form.locator('input[name="q"]')).toBeVisible();
    await expect(form.getByRole('button', {name: 'Filter'})).toBeVisible();
    await expect(page.locator('.page-header .subtitle')).toContainText('recording(s)');
  });

  test('slug search round-trips through the URL and echoes into the form', async ({loggedInPage: page}) => {
    await page.goto('/Archive');
    const form = page.locator('form[action="/Archive"]');
    await form.locator('input[name="q"]').fill('floor');
    await form.getByRole('button', {name: 'Filter'}).click();
    await page.waitForURL(/[?&]q=floor/);
    await expect(form.locator('input[name="q"]')).toHaveValue('floor');
  });

  test('min-duration filter round-trips', async ({loggedInPage: page}) => {
    await page.goto('/Archive?minDuration=120');
    await expect(page.locator('form[action="/Archive"] input[name="minDuration"]')).toHaveValue('120');
  });

  test('recording rows link to a windowed player URL when data exists', async ({loggedInPage: page}) => {
    await page.goto('/Archive');
    const playLinks = page.getByRole('link', {name: 'Play'});
    const n = await playLinks.count();
    if (n === 0) {
      // No segments indexed yet — assert the empty state instead.
      await expect(page.locator('.empty')).toContainText('No recordings');
      return;
    }
    const href = await playLinks.first().getAttribute('href');
    expect(href).toMatch(/\/PlayerArchive\?cameraId=[^&]+&from=[^&]+&to=/);
  });

  test('player page shows the requested window label', async ({loggedInPage: page}) => {
    await page.goto('/Archive');
    const playLinks = page.getByRole('link', {name: 'Play'});
    test.skip((await playLinks.count()) === 0, 'no recordings in DB');
    const href = (await playLinks.first().getAttribute('href'))!;
    await page.goto(href);
    await expect(page.locator('.page-header .subtitle')).toContainText('Window');
    await expect(page.locator('#hnvr-player')).toBeVisible();
  });

  test('admin sees Delete buttons on recording rows', async ({loggedInPage: page}) => {
    await page.goto('/Archive');
    const playLinks = page.getByRole('link', {name: 'Play'});
    test.skip((await playLinks.count()) === 0, 'no recordings in DB');
    await expect(page.getByRole('button', {name: 'Delete'}).first()).toBeVisible();
  });

  // ---- Pagination + page size (regression: pageSize was 25 → 10) ----

  test('index shows at most 10 recording rows per page', async ({loggedInPage: page}) => {
    // Sergey's 2026-08-12 report: 12 recordings visible + "1/1"
    // pagination looked broken because pageSize=25 meant any single
    // 24h window fit on one page. With pageSize=10 the same dataset
    // should now split into 2 pages and the "Next →" link should appear.
    await page.goto('/Archive');
    const playLinks = page.getByRole('link', {name: 'Play'});
    const count = await playLinks.count();
    // Assert hard cap; the empty state already has its own test.
    expect(count).toBeLessThanOrEqual(10);
  });

  test('pagination chrome renders "Next →" when more than 10 recordings exist', async ({loggedInPage: page}) => {
    // Don't conflate "rows on page" (capped at pageSize) with "total
    // recording count" (drives pagination). With pageSize=10 the
    // visible Play-link count is ALWAYS ≤ 10, so the right signal for
    // "is there a next page" is the "Next →" link itself.
    await page.goto('/Archive');
    const nextLink = page.getByRole('link', {name: /Next/});
    const hasNext = (await nextLink.count()) > 0;
    if (!hasNext) {
      // Single-page dataset — badge reads "Page 1 / 1".
      await expect(page.locator('.card', {hasText: /Page/})).toContainText('Page 1 / 1');
      return;
    }
    await expect(nextLink.first()).toBeVisible();
    await expect(page.locator('.card', {hasText: /Page/})).toContainText(/Page 1 \/ \d+/);
  });

  test('pagination "Next →" carries the current filter params', async ({loggedInPage: page}) => {
    // Pre-seed a filter via URL so we can assert on the href directly
    // even when the DB row count is below the page threshold.
    await page.goto('/Archive?q=floor');
    const nextLink = page.getByRole('link', {name: /Next/});
    test.skip((await nextLink.count()) === 0, 'not enough recordings to page');
    const href = await nextLink.first().getAttribute('href');
    expect(href).toMatch(/page=2/);
    expect(href).toMatch(/q=floor/);
  });

  // ---- Filter preservation on delete (regression: redirectTo ArchiveAction
  //      dropped query string → user saw default-window view that read as
  //      "deleted row still there") ----

  test('delete form action URL carries current filter params', async ({loggedInPage: page}) => {
    // Cheap, deterministic: we never submit, just inspect the form
    // action. The form action is built server-side from `queryString`
    // so this exercises the round-trip contract directly.
    await page.goto('/Archive?q=floor&minDuration=0');
    const deleteForms = page.locator('form[action^="/PurgeRecording"]');
    test.skip((await deleteForms.count()) === 0, 'no recordings in DB');
    const action = await deleteForms.first().getAttribute('action');
    expect(action).toMatch(/q=floor/);
    expect(action).toMatch(/minDuration=0/);
    // purgeFrom/purgeTo are hidden INPUTS (not URL params) — they
    // shouldn't leak into the action URL.
    expect(action).not.toMatch(/purgeFrom/);
    expect(action).not.toMatch(/purgeTo/);
  });

  test('delete form hidden inputs use prefixed names (purgeFrom/purgeTo)', async ({loggedInPage: page}) => {
    // Regression guard: the original form posted `from`/`to` for the
    // purge window, which clashed with the filter's from/to and meant
    // the redirect couldn't carry the filter window back. The form
    // now posts purgeFrom/purgeTo so the URL's from/to are free for
    // the filter.
    await page.goto('/Archive');
    const deleteForms = page.locator('form[action^="/PurgeRecording"]');
    test.skip((await deleteForms.count()) === 0, 'no recordings in DB');
    const firstForm = deleteForms.first();
    await expect(firstForm.locator('input[name="purgeFrom"]')).toHaveCount(1);
    await expect(firstForm.locator('input[name="purgeTo"]')).toHaveCount(1);
    // Old names must NOT appear — otherwise the controller's purgeFrom
    // read would silently fall back to Nothing and fail to delete.
    await expect(firstForm.locator('input[name="from"]')).toHaveCount(0);
    await expect(firstForm.locator('input[name="to"]')).toHaveCount(0);
  });

  test('submitting delete redirects back to the same filtered view', async ({loggedInPage: page}) => {
    await page.goto('/Archive?q=floor');
    const deleteButtons = page.getByRole('button', {name: 'Delete'});
    test.skip((await deleteButtons.count()) === 0, 'no recordings in DB');

    // Clicking triggers a form POST + 302; waitForURL catches the
    // redirected /Archive?q=floor landing page.
    await deleteButtons.first().click();
    await page.waitForURL(/\/Archive\?.*q=floor/);

    // The redirect MUST carry the filter — Sergey's bug was that it
    // didn't, so the user landed on default-window /Archive. We don't
    // assert row counts post-delete because (a) the recording loop
    // keeps producing new rows so the count drifts during the test,
    // and (b) Playwright's auto-wait on a stale locator adds flake.
    // The URL alone is the contract.
    expect(page.url()).toMatch(/q=floor/);
    // Sanity: the filter form is still rendered with the round-tripped
    // value (i.e. we're looking at a real /Archive render, not a 500).
    await expect(page.locator('form[action="/Archive"] input[name="q"]')).toHaveValue('floor');
  });

  test('delete preserves page param when on page > 1', async ({loggedInPage: page}) => {
    // This test only runs when there's enough data to page; in an
    // empty dev DB it skips.
    await page.goto('/Archive?page=2');
    // After clamping (the controller clamps page to the valid range),
    // we may still be on page 1 if there's not enough data.
    const deleteButtons = page.getByRole('button', {name: 'Delete'});
    test.skip((await deleteButtons.count()) === 0, 'no recordings on page 2');
    // The controller clamps out-of-range pages; if we landed on page 1
    // the purge actions rightly carry no &page= param — nothing to
    // assert.
    const badge = await page.locator('text=/Page \\d+ \\/ \\d+/').first().textContent();
    test.skip(!badge || !badge.includes('Page 2 /'), 'clamped to page 1 (not enough recordings to page)');

    // Inspect the form action — when page > 1, the delete URL should
    // include &page=N so the redirect lands back on the same page.
    const action = await page.locator('form[action^="/PurgeRecording"]').first().getAttribute('action');
    expect(action).toMatch(/page=/);
  });
});
