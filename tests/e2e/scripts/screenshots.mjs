#!/usr/bin/env node
/**
 * README screenshot capture. Not part of the test suite — run manually:
 *   node scripts/screenshots.mjs
 *
 * Two targets:
 *   LIVE  (:18001) — dev leader with running capture/analysis: dashboard
 *          wall, live overlay, rule editor (canvas bg = live frame).
 *   FRESH (:18002) — current build with background roles disabled:
 *          everything else (identical DB, safe read-only pages).
 *
 * Output: ../../docs/screenshots/*.png (1440x900 @2x).
 */
import {chromium} from 'playwright';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const LIVE = process.env.LIVE_URL ?? 'http://127.0.0.1:18001';
const FRESH = process.env.FRESH_URL ?? 'http://127.0.0.1:18002';
const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'docs', 'screenshots');

const EMAIL = process.env.HNVR_ADMIN_EMAIL ?? 'admin@hnvr.local';
const PASSWORD = process.env.HNVR_ADMIN_PASSWORD ?? 'hnvr-dev';

const BACKYARD = '0e730f9f-2ee2-4ea1-8680-1a264368d17a';
const FLOOR = '793e3bc3-8b14-473b-a2f8-9e6c01299448';
const RULE_ZONE_MOTION = '093ec86d-fb6a-4854-b0a0-2d558c6c4c71';

async function login(page, base) {
  await page.goto(base + '/NewSession');
  await page.locator('#email').fill(EMAIL);
  await page.locator('#password').fill(PASSWORD);
  await page.getByRole('button', {name: /login/i}).click();
  await page.waitForURL(/\/$|\/Dashboard$/);
}

async function shot(page, name) {
  await page.screenshot({path: path.join(OUT, name + '.png')});
  console.log('shot:', name);
}

async function settle(page, ms = 2500) {
  await page.waitForTimeout(ms);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: {width: 1440, height: 900},
  deviceScaleFactor: 2,
});
const page = await ctx.newPage();
page.setDefaultTimeout(10000);

await mkdir(OUT, {recursive: true});

async function step(name, fn) {
  try {
    await fn();
  } catch (e) {
    console.error('FAILED:', name, '-', String(e).split('\n')[0]);
  }
}

// ---- anonymous surfaces ------------------------------------------------
await step('login page', async () => {
  await page.goto(FRESH + '/NewSession');
  await settle(page, 800);
  await shot(page, 'login');
});

await step('dashboard (anon live wall)', async () => {
  await page.goto(LIVE + '/');
  await settle(page, 4000);
  await shot(page, 'dashboard');
});

// ---- authenticated, fresh build ----------------------------------------
await login(page, FRESH);

await step('cameras', async () => {
  await page.goto(FRESH + '/Cameras');
  await settle(page, 1200);
  await shot(page, 'cameras');
});

await step('camera detail (backyard, PTZ)', async () => {
  await page.goto(FRESH + '/ShowCamera?cameraId=' + BACKYARD);
  await settle(page, 1200);
  await shot(page, 'camera-detail');
});

await step('rules', async () => {
  await page.goto(FRESH + '/Rules');
  await settle(page, 1200);
  await shot(page, 'rules');
});

await step('events', async () => {
  await page.goto(FRESH + '/Events');
  await settle(page, 3500);
  await shot(page, 'events');
});

await step('archive', async () => {
  await page.goto(FRESH + '/Archive');
  await settle(page, 1500);
  await shot(page, 'archive');
});

await step('stats', async () => {
  await page.goto(FRESH + '/Stats');
  await settle(page, 1200);
  await shot(page, 'stats');
});

await step('hosts', async () => {
  await page.goto(FRESH + '/Hosts');
  await settle(page, 1200);
  await shot(page, 'hosts');
});

await step('audit log', async () => {
  await page.goto(FRESH + '/AuditLog');
  await settle(page, 1200);
  await shot(page, 'audit');
});

await step('live view + PTZ drawer', async () => {
  await page.goto(FRESH + '/ShowLive?cameraId=' + FLOOR);
  await settle(page, 3500);
  await page.locator('[data-ptz-toggle]').first().click();
  await settle(page, 1200);
  await shot(page, 'live-ptz-drawer');
});

// ---- authenticated, live leader (real frames) ---------------------------
await login(page, LIVE);

await step('live overlay', async () => {
  await page.goto(LIVE + '/');
  await settle(page, 3000);
  await page.locator('.cam-card[data-cam-id="' + FLOOR + '"]').first().click();
  await settle(page, 5000);
  await shot(page, 'live-overlay');
  await page.keyboard.press('Escape');
  await settle(page, 600);
});

await step('rule editor (zone canvas)', async () => {
  await page.goto(LIVE + '/EditRule?ruleId=' + RULE_ZONE_MOTION);
  await settle(page, 3000);
  await shot(page, 'rule-editor');
});

await step('archive player', async () => {
  await page.goto(LIVE + '/PlayerArchive?cameraId=' + FLOOR);
  await settle(page, 6000);
  await shot(page, 'archive-player');
});

await step('dashboard daylight', async () => {
  await page.goto(LIVE + '/');
  await page.evaluate(() => localStorage.setItem('hnvr-theme', 'daylight'));
  await page.reload();
  await settle(page, 3500);
  await shot(page, 'dashboard-daylight');
  await page.evaluate(() => localStorage.setItem('hnvr-theme', 'midnight'));
});

await browser.close();
console.log('done ->', OUT);
