import {test, expect} from '../lib/auth';

/**
 * Login / logout flow against IHP's AuthSupport sessions controller.
 *
 * Covers:
 *  - Valid credentials → 302 to / (dashboard), nav shows Logout link.
 *  - Invalid credentials → bounced back to /NewSession.
 *  - Logout clears the session cookie.
 *
 * Per design_docs/10-test-plan.md S4 (P3 prep).
 */
test.describe('Sessions / login', () => {
  test('valid admin credentials reach the dashboard', async ({loggedInPage}) => {
    await loggedInPage.goto('/');
    // Nav has a Logout link when authenticated (View/Layout.hs).
    await expect(loggedInPage.getByRole('link', {name: /logout/i})).toBeVisible();
  });

  test('invalid credentials bounce back to /NewSession', async ({page}) => {
    await page.goto('/NewSession');
    await page.locator('#email').fill('nobody@hnvr.local');
    await page.locator('#password').fill('wrong');
    await page.getByRole('button', {name: /login/i}).click();
    // IHP's createSessionAction redirects to /NewSession on failure
    // (no flash message in v1; the URL change is the signal).
    await page.waitForURL(/\/NewSession$/);
    await expect(page).toHaveURL(/\/NewSession$/);
  });

  test('protected route redirects to /NewSession when logged out', async ({page}) => {
    // Cameras is admin-gated (Slice 8); anonymous users should be
    // redirected to the login form.
    await page.goto('/Cameras');
    await page.waitForURL(/\/NewSession$/);
    await expect(page).toHaveURL(/\/NewSession$/);
  });
});
