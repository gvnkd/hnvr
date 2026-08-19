import {test, expect} from '../lib/auth';

/**
 * Video zoom/pan (HNVR.zoompan in app.js).
 *
 * Exercised on the archive player page (no media needed — the feature
 * is a CSS transform on the <video> element):
 *   - wheel up over the video zooms in (transform gains scale, element
 *     gains .is-zoomed)
 *   - LMB drag pans (translate components change)
 *   - wheeling back out to 1x clears the transform
 */
test.describe('Video zoom/pan', () => {
  test('wheel zooms, drag pans, wheel-out resets (archive player)', async ({loggedInPage: page}) => {
    await page.goto('/Cameras');
    const firstShowLink = page.locator('tbody tr').first().getByRole('link', {name: 'Show'});
    const hasCamera = await firstShowLink.count();
    test.skip(!hasCamera, 'no cameras in DB — run cameras-crud.spec first');

    await firstShowLink.click();
    await page.waitForURL(/\/ShowCamera\?cameraId=/);
    const cameraId = new URL(page.url()).searchParams.get('cameraId');
    expect(cameraId).toBeTruthy();

    await page.goto(`/PlayerArchive?cameraId=${cameraId}`);
    const video = page.locator('#hnvr-player');
    await expect(video).toBeVisible();

    // Wheel up over the video center → zoom in.
    await video.hover();
    await page.mouse.wheel(0, -240);
    await expect(video).toHaveClass(/is-zoomed/);
    const transformAfterZoom = await video.evaluate((el) => (el as HTMLElement).style.transform);
    expect(transformAfterZoom).toContain('scale(');

    // LMB drag → pan (translate components move).
    const box = await video.boundingBox();
    expect(box).toBeTruthy();
    const cx = box!.x + box!.width / 2;
    const cy = box!.y + box!.height / 2 - 60; // stay off the native control strip
    await page.mouse.move(cx, cy);
    await page.mouse.down();
    await page.mouse.move(cx + 60, cy + 40, {steps: 4});
    await page.mouse.up();
    const transformAfterPan = await video.evaluate((el) => (el as HTMLElement).style.transform);
    expect(transformAfterPan).not.toBe(transformAfterZoom);
    expect(transformAfterPan).toContain('scale(');

    // Wheel back out to 1x → transform cleared.
    for (let i = 0; i < 6; i++) await page.mouse.wheel(0, 240);
    await expect(video).not.toHaveClass(/is-zoomed/);
    const transformAfterReset = await video.evaluate((el) => (el as HTMLElement).style.transform);
    expect(transformAfterReset).toBe('');
  });

  test('wheel zooms in fullscreen (capture-phase listener)', async ({loggedInPage: page}) => {
    // Chrome's native fullscreen media controls consume wheel events
    // (volume scroll) inside the video's shadow root; the zoom listener
    // must run in capture phase to see them.
    await page.goto('/Cameras');
    const firstShowLink = page.locator('tbody tr').first().getByRole('link', {name: 'Show'});
    const hasCamera = await firstShowLink.count();
    test.skip(!hasCamera, 'no cameras in DB — run cameras-crud.spec first');

    await firstShowLink.click();
    await page.waitForURL(/\/ShowCamera\?cameraId=/);
    const cameraId = new URL(page.url()).searchParams.get('cameraId');

    await page.goto(`/PlayerArchive?cameraId=${cameraId}`);
    const video = page.locator('#hnvr-player');
    await expect(video).toBeVisible();

    await video.evaluate((el) => (el as HTMLVideoElement).requestFullscreen());
    await page.waitForFunction(() => !!document.fullscreenElement);
    await page.mouse.move(400, 300);
    await page.mouse.wheel(0, -240);
    await expect(video).toHaveClass(/is-zoomed/);
    const t = await video.evaluate((el) => (el as HTMLElement).style.transform);
    expect(t).toContain('scale(');

    await page.evaluate(() => document.exitFullscreen());
  });

  test('pan drag ending on the overlay backdrop does NOT close the overlay', async ({loggedInPage: page}) => {
    // Chrome dispatches the click after a drag on the nearest common
    // ancestor of the press/release points — a pan released over the
    // backdrop used to hit the overlay's click-to-close handler.
    await page.goto('/Dashboard');
    const card = page.locator('.cam-card[data-slug]').first();
    test.skip((await card.count()) === 0, 'no cameras in DB');

    await card.click();
    const overlay = page.locator('#live-overlay');
    await expect(overlay).toBeVisible();
    const video = overlay.locator('video');

    // Zoom in via wheel over the overlay video.
    await video.hover();
    await page.mouse.wheel(0, -240);
    await expect(video).toHaveClass(/is-zoomed/);

    // Pan drag that ends OUTSIDE the panel, on the overlay backdrop.
    const vbox = await video.boundingBox();
    expect(vbox).toBeTruthy();
    await page.mouse.move(vbox!.x + vbox!.width / 2, vbox!.y + vbox!.height / 2);
    await page.mouse.down();
    await page.mouse.move(10, 10, {steps: 6});
    await page.mouse.up();

    // The trailing click must be swallowed: overlay stays open.
    // closeLive hides the overlay after a 260 ms CSS transition —
    // assert AFTER that window, otherwise the check races the timeout.
    await page.waitForTimeout(500);
    await expect(overlay).toBeVisible();
  });
});
