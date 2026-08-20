import {test, expect} from '../lib/auth';

/**
 * Profile timezone (web UI local timezones):
 *  - /ShowProfile renders a dropdown populated from
 *    Intl.supportedValuesOf('timeZone') plus a "use browser" button.
 *  - Saving a zone persists it (body[data-user-tz]) and the topbar
 *    clock switches from UTC to that zone's abbreviation.
 *  - Reset to "Browser default" at the end so other specs (and the
 *    shared dev DB) stay unaffected.
 */
test.describe('Profile / timezone', () => {
  test('timezone dropdown is populated and saveable', async ({loggedInPage}) => {
    await loggedInPage.goto('/ShowProfile');

    const select = loggedInPage.locator('select[data-tz-select]');
    await expect(select).toBeVisible();
    // Client-side populated from Intl.supportedValuesOf — hundreds of zones.
    await expect(select.locator('option')).not.toHaveCount(0);
    await expect(select.locator('option[value="Europe/Berlin"]')).toHaveCount(1);

    await select.selectOption('Europe/Berlin');
    await loggedInPage.getByRole('button', {name: /^save$/i}).click();
    await loggedInPage.waitForURL(/\/ShowProfile$/);
    await expect(loggedInPage.locator('.alert-success')).toContainText(/profile saved/i);

    // Layout now carries the profile zone and the clock follows it.
    await expect(loggedInPage.locator('body')).toHaveAttribute('data-user-tz', 'Europe/Berlin');
    await expect(loggedInPage.locator('.topbar .clock')).toContainText(/CES?T|Europe\/Berlin/);
  });

  test('use-browser button picks the detected zone', async ({loggedInPage}) => {
    await loggedInPage.goto('/ShowProfile');
    const select = loggedInPage.locator('select[data-tz-select]');
    const browserTz = await loggedInPage.evaluate(() =>
      Intl.DateTimeFormat().resolvedOptions().timeZone,
    );
    await loggedInPage.getByRole('button', {name: /use browser timezone/i}).click();
    await expect(select).toHaveValue(browserTz);
  });

  test('reset to browser default clears the saved zone', async ({loggedInPage}) => {
    const browserTz = await loggedInPage.evaluate(() =>
      Intl.DateTimeFormat().resolvedOptions().timeZone,
    );
    await loggedInPage.goto('/ShowProfile');
    await loggedInPage.locator('select[data-tz-select]').selectOption('');
    await loggedInPage.getByRole('button', {name: /^save$/i}).click();
    await loggedInPage.waitForURL(/\/ShowProfile$/);
    await expect(loggedInPage.locator('body')).toHaveAttribute('data-user-tz', '');
    // Clock now follows the browser zone (named abbreviation or IANA
    // name depending on the chromium build's ICU data).
    const clockText = await loggedInPage.locator('.topbar .clock').textContent();
    expect(clockText).toMatch(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \S+/);
    expect(clockText).toContain(browserTz === 'UTC' ? 'UTC' : browserTz);
  });
});
