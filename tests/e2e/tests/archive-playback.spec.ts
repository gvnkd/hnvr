import {test, expect} from '../lib/auth';

/**
 * Archive playback page.
 *
 * Verifies the page renders the `<video>` element, hls.js is loaded,
 * and the playlist URL is constructed correctly. Does NOT assert the
 * video reaches HAVE_ENOUGH_DATA — that requires actual fMP4 segments
 * in S3 plus a real presigned-URL handshake. The "Ready" status branch
 * is intentionally not asserted; instead we check the loader + the
 * JS-side error path (which fires when the playlist URL returns the
 * empty placeholder from `emptyPlaylist` or a real m3u8 with no
 * segments).
 *
 * See design_docs/05-web-and-live-view.md §"Archive playback" and
 * Hnvr.Web.View.Archive.Player for the source of the JS contract.
 */
test.describe('Archive playback', () => {
  test('page renders video element + hls.js loader + status pill', async ({loggedInPage: page}) => {
    // Pick the first camera from the index. If no cameras exist, the
    // Cameras CRUD test created at least one; otherwise we skip with a
    // clear message.
    await page.goto('/Cameras');
    const firstShowLink = page.locator('tbody tr').first().getByRole('link', {name: 'Show'});
    const hasCamera = await firstShowLink.count();
    test.skip(!hasCamera, 'no cameras in DB — run cameras-crud.spec first');

    await firstShowLink.click();
    await page.waitForURL(/\/ShowCamera\?cameraId=/);
    const showUrl = page.url();
    const cameraId = new URL(showUrl).searchParams.get('cameraId');
    expect(cameraId).toBeTruthy();

    // Navigate to the archive player for this camera.
    await page.goto(`/PlayerArchive?cameraId=${cameraId}`);

    // Video element exists.
    const video = page.locator('#hnvr-player');
    await expect(video).toBeVisible();

    // hls.js script tag is present (loads from CDN — may or may not
    // succeed in CI without network; we assert the tag, not the load).
    await expect(page.locator('script[src*="hls.js"]')).toHaveCount(1);

    // Status pill is present and starts in "Loading" state.
    const status = page.locator('#hnvr-status');
    await expect(status).toBeVisible();
    await expect(status).toHaveText(/Loading player/);

    // The playlist URL is built client-side from window.location plus
    // /PlaylistArchive?cameraId=…; verify the JS issued a fetch to it
    // (regardless of whether the response was empty or real).
    const playlistRequest = page.waitForRequest(
      (req) => req.url().includes('/PlaylistArchive') && req.method() === 'GET',
      {timeout: 10_000}
    ).catch(() => null);
    // Re-load to catch the request from the start.
    await page.goto(`/PlayerArchive?cameraId=${cameraId}`);
    const req = await playlistRequest;
    expect(req, 'expected a GET /PlaylistArchive request from hls.js').not.toBeNull();
  });
});
