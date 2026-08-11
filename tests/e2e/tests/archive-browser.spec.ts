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
});
