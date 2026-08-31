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

test("range preset after scrubbing centers on the scrubbed cursor", async ({ loggedInPage: page }) => {
  await page.goto("/Timeline");
  const canvas = page.locator("[data-tl-canvas]");
  await canvas.scrollIntoViewIfNeeded();
  const box = (await canvas.boundingBox())!;
  // Scrub to ~20% from the left (cursor leaves "now").
  await page.mouse.move(box.x + box.width * 0.8, box.y + 20);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.2, box.y + 20, { steps: 5 });
  await page.mouse.up();
  const curLabel = await page.locator("[data-tl-cursor-label]").textContent();

  await page.locator(".tl-rangebar [data-dropdown-button]").click();
  await page.locator(".tl-rangebar .dropdown-item", { hasText: "1 hour" }).click();
  await page.waitForURL(/\/Timeline\?from=/);
  const root = page.locator("[data-timeline]");
  const from = Date.parse((await root.getAttribute("data-from"))!);
  const to = Date.parse((await root.getAttribute("data-to"))!);
  const cur = Date.parse((await root.getAttribute("data-cursor"))!);
  expect(to - from).toBe(3600 * 1000);
  // Centered on the scrubbed cursor, NOT reset to now.
  expect(Math.abs(cur - (from + to) / 2)).toBeLessThan(60 * 1000);
  expect(to).toBeLessThan(Date.now() - 60 * 1000);
  await expect(page.locator("[data-tl-cursor-label]")).toHaveText(curLabel!);
});

test("range preset from a now-cursor centers too (window may reach into the future)", async ({ loggedInPage: page }) => {
  await page.goto("/Timeline");
  await page.locator(".tl-rangebar [data-dropdown-button]").click();
  await page.locator(".tl-rangebar .dropdown-item", { hasText: "1 hour" }).click();
  await page.waitForURL(/\/Timeline\?from=/);
  const root = page.locator("[data-timeline]");
  const from = Date.parse((await root.getAttribute("data-from"))!);
  const to = Date.parse((await root.getAttribute("data-to"))!);
  const cur = Date.parse((await root.getAttribute("data-cursor"))!);
  expect(to - from).toBe(3600 * 1000);
  // Cursor centered; the window legitimately extends ~30m past now.
  expect(Math.abs(cur - (from + to) / 2)).toBeLessThan(60 * 1000);
  expect(to).toBeGreaterThan(Date.now() - 60 * 1000);
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
