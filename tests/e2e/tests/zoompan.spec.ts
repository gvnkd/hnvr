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
});
