import { test, expect } from "../lib/auth";

test("timeline range inputs render in the profile locale", async ({ loggedInPage: page }) => {
  // Set ru-RU locale.
  await page.goto("/ShowProfile");
  await page.locator("#locale").fill("ru-RU");
  await page.getByRole("button", { name: /^save$/i }).click();
  await page.waitForURL(/\/ShowProfile$/);

  await page.goto("/Timeline");
  const disp = page.locator(".tz-dt-display").first();
  await expect(disp).toBeVisible();
  // ru-RU short date = DD.MM.YYYY — must NOT match US MM/DD/YYYY.
  await expect(disp).toHaveValue(/\d{2}\.\d{2}\.\d{4}/);
  // Native input hidden but keeps the ISO value for submit.
  const native = page.locator("input[data-tz-dt]").first();
  await expect(native).toHaveValue(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/);

  // Reset locale.
  await page.goto("/ShowProfile");
  await page.locator("#locale").fill("");
  await page.getByRole("button", { name: /^save$/i }).click();
  await page.waitForURL(/\/ShowProfile$/);
});
