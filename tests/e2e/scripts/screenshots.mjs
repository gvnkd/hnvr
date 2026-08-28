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
 * Camera pixels are blurred before every shot (README is public):
 * CSS filter on video / frame <img> / thumbnails via addInitScript;
 * the rule-editor canvas is redrawn in-page (ctx.filter blur under the
 * geometry) because CSS blur would smear the zone outlines too.
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

const BLUR_CSS = [
  'video',
  '.cam-live img',
  '.ev-thumb img',
  'img[alt="event frame"]',
  '[data-tl-thumb]',
].join(', ') + ' { filter: blur(12px) !important; }';
// IHP's in-page refresh morphs <head> and drops foreign style tags —
// re-inject on an interval so the blur survives page refreshes.
await page.addInitScript((css) => {
  const inject = () => {
    if (!document.head || document.getElementById('hnvr-shot-blur')) return;
    const s = document.createElement('style');
    s.id = 'hnvr-shot-blur';
    s.textContent = css;
    document.head.appendChild(s);
  };
  inject();
  document.addEventListener('DOMContentLoaded', inject);
  setInterval(inject, 250);
}, BLUR_CSS);

let ruleFrameUrl = null;
page.on('request', (req) => {
  if (req.url().includes('/debug-frame/')) ruleFrameUrl = req.url();
});

// Redraws the rule-editor canvas: blurred frame + sharp geometry overlay
// (mirrors the drawing constants in Hnvr.Web.View.Rules.New).
async function blurRuleCanvas() {
  if (!ruleFrameUrl) return;
  await page.evaluate(async (frameUrl) => {
    const canvas = document.getElementById('rule-canvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const img = new Image();
    await new Promise((res, rej) => {
      img.onload = res;
      img.onerror = rej;
      img.src = new URL(frameUrl).pathname + '?t=' + Date.now();
    });
    canvas.height = Math.round((canvas.width * img.height) / img.width);
    const b = 20;
    ctx.filter = 'blur(14px)';
    ctx.drawImage(img, -b, -b, canvas.width + 2 * b, canvas.height + 2 * b);
    ctx.filter = 'none';
    const isLine = document.getElementById('rule-kind').value === 'line_cross';
    let points = [];
    try {
      const g = JSON.parse(document.getElementById('rule-geometry').value || 'null');
      if (g && g.polygon) points = g.polygon;
      if (g && g.a && g.b) points = [g.a, g.b];
    } catch (e) {}
    ctx.strokeStyle = '#ff3838';
    ctx.fillStyle = 'rgba(255,56,56,0.25)';
    ctx.lineWidth = 2;
    points.forEach((p, i) => {
      ctx.beginPath();
      ctx.arc(p[0] * canvas.width, p[1] * canvas.height, 4, 0, 7);
      ctx.fill();
      if (i === 0 && isLine) {
        ctx.fillStyle = '#fff';
        ctx.fillText('a', p[0] * canvas.width + 6, p[1] * canvas.height - 6);
        ctx.fillStyle = 'rgba(255,56,56,0.25)';
      }
      if (i === 1 && isLine) {
        ctx.fillStyle = '#fff';
        ctx.fillText('b', p[0] * canvas.width + 6, p[1] * canvas.height - 6);
        ctx.fillStyle = 'rgba(255,56,56,0.25)';
      }
    });
    if (isLine && points.length === 2) {
      ctx.beginPath();
      ctx.moveTo(points[0][0] * canvas.width, points[0][1] * canvas.height);
      ctx.lineTo(points[1][0] * canvas.width, points[1][1] * canvas.height);
      ctx.stroke();
      const mx = ((points[0][0] + points[1][0]) / 2) * canvas.width;
      const my = ((points[0][1] + points[1][1]) / 2) * canvas.height;
      const dx = points[1][0] - points[0][0];
      const dy = points[1][1] - points[0][1];
      const len = Math.sqrt(dx * dx + dy * dy) || 1;
      ctx.beginPath();
      ctx.moveTo(mx, my);
      ctx.lineTo(mx + (-dy / len) * 10 - (dx / len) * 8, my + (dx / len) * 10 - (dy / len) * 8);
      ctx.lineTo(mx - (-dy / len) * 10 - (dx / len) * 8, my - (dx / len) * 10 - (dy / len) * 8);
      ctx.stroke();
    }
    if (!isLine && points.length >= 2) {
      ctx.beginPath();
      ctx.moveTo(points[0][0] * canvas.width, points[0][1] * canvas.height);
      for (let i = 1; i < points.length; i++) ctx.lineTo(points[i][0] * canvas.width, points[i][1] * canvas.height);
      if (points.length >= 3) ctx.closePath();
      ctx.stroke();
      if (points.length >= 3) ctx.fill();
    }
  }, ruleFrameUrl);
}

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
  await blurRuleCanvas();
  await page.locator('#rule-canvas').scrollIntoViewIfNeeded();
  await settle(page, 400);
  await shot(page, 'rule-editor');
});

await step('archive player', async () => {
  await page.goto(LIVE + '/PlayerArchive?cameraId=' + FLOOR);
  // The playlist rewrite probes every fragment's moof head up-front
  // ("indexing…") — a 1 h window needs ~15 s before pixels appear.
  await settle(page, 18000);
  await shot(page, 'archive-player');
});

await step('timeline playing (live)', async () => {
  const t = new Date(Date.now() - 4 * 60 * 1000);
  const fmt = (d) => d.toISOString().slice(0, 19);
  const from = new Date(t.getTime() - 3600 * 1000);
  const to = new Date(t.getTime() + 3600 * 1000);
  await page.goto(
    LIVE + '/Timeline?from=' + fmt(from) + '&to=' + fmt(to) + '&t=' + fmt(t) + '&active=' + FLOOR
  );
  await settle(page, 9000);
  await shot(page, 'timeline-playing');
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
