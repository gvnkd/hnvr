import { test, expect } from "../lib/auth";

test("range preset centers the window on the cursor", async ({ loggedInPage: page }) => {
  // Deep-link a cursor 12h ago, then switch to 1h → cursor centered (±30m).
  await page.goto("/Timeline");
  const root = page.locator("[data-timeline]");
  const to = Date.parse((await root.getAttribute("data-to"))!);
  const cursorTs = new Date(to - 12 * 3600 * 1000).toISOString();
  await page.goto(`/Timeline?t=${cursorTs}`);
  const cur = Date.parse((await root.getAttribute("data-cursor"))!);
  expect(Math.abs(cur - Date.parse(cursorTs))).toBeLessThan(1000);

  await page.locator(".tl-rangebar [data-dropdown-button]").click();
  await page.locator(".tl-rangebar .dropdown-item", { hasText: "1 hour" }).click();
  await page.waitForURL(/\/Timeline\?from=/);
  const from = Date.parse((await root.getAttribute("data-from"))!);
  const to2 = Date.parse((await root.getAttribute("data-to"))!);
  const cur2 = Date.parse((await root.getAttribute("data-cursor"))!);
  expect(to2 - from).toBe(3600 * 1000);
  // Cursor preserved and centered.
  expect(Math.abs(cur2 - cur)).toBeLessThan(1000);
  expect(Math.abs(cur2 - (from + to2) / 2)).toBeLessThan(60 * 1000);
});

test("range preset from a now-cursor keeps full width ending at now", async ({ loggedInPage: page }) => {
  await page.goto("/Timeline");
  await page.locator(".tl-rangebar [data-dropdown-button]").click();
  await page.locator(".tl-rangebar .dropdown-item", { hasText: "1 hour" }).click();
  await page.waitForURL(/\/Timeline\?from=/);
  const root = page.locator("[data-timeline]");
  const from = Date.parse((await root.getAttribute("data-from"))!);
  const to = Date.parse((await root.getAttribute("data-to"))!);
  expect(to - from).toBe(3600 * 1000);
  expect(Math.abs(to - Date.now())).toBeLessThan(60 * 1000);
});

test("hover preview sits above the canvas, not over it", async ({ loggedInPage: page }) => {
  await page.goto("/Timeline");
  const canvas = page.locator("[data-tl-canvas]");
  await canvas.scrollIntoViewIfNeeded();
  const box = (await canvas.boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + 15);
  const preview = page.locator(".tl-hover-preview");
  await expect(preview).toBeVisible();
  const pb = (await preview.boundingBox())!;
  // Preview bottom edge must not overlap the canvas top.
  expect(pb.y + pb.height).toBeLessThanOrEqual(box.y + 1);
});
