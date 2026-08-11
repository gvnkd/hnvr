import {test, expect} from '../lib/auth';

/**
 * Archive playback page.
 *
 * Verifies the page renders the `<video>` element, the hls.js script tag
 * is loaded, and the playlist URL is fetched client-side. Does NOT
 * assert the video reaches HAVE_ENOUGH_DATA — that requires actual
 * fMP4 segments in SeaweedFS plus a presigned-URL handshake; future
 * slice once a real RTSP camera is wired.
 *
 * The status pill has three possible initial render paths
 * (Hnvr.Web.View.Archive.Player):
 *   - "Loading player…"  (HTML literal; shown for one frame)
 *   - "Native HLS (Safari)"  (chromium headless-shell reports
 *     video.canPlayType('application/vnd.apple.mpegurl') as 'maybe',
 *     which is truthy — the Safari branch fires)
 *   - "Ready" / "Error: …" / "HLS not supported …"
 *     (hls.js loadSource outcome; depends on real segments)
 *
 * We assert just the elements that are stable across these branches.
 */
test.describe('Archive playback', () => {
  test('page renders video element + hls.js loader + issues playlist GET', async ({loggedInPage: page}) => {
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

    // Catch the playlist GET the JS will issue on page load. Set up
    // the listener BEFORE navigating so we don't miss it.
    const playlistRequest = page.waitForRequest(
      (req) => req.url().includes('/PlaylistArchive') && req.method() === 'GET',
      {timeout: 10_000}
    );

    // Navigate to the archive player for this camera.
    await page.goto(`/PlayerArchive?cameraId=${cameraId}`);

    // Video element exists.
    const video = page.locator('#hnvr-player');
    await expect(video).toBeVisible();

    // hls.js script tag is present (loads from CDN — may or may not
    // succeed in CI without network; we assert the tag, not the load).
    await expect(page.locator('script[src*="hls.js"]')).toHaveCount(1);

    // Status pill is present (text varies by branch — see test docblock).
    const status = page.locator('#hnvr-status');
    await expect(status).toBeVisible();

    // hls.js (or the native-HLS branch) issues a playlist GET regardless
    // of which status path fired.
    const req = await playlistRequest;
    expect(req, 'expected a GET /PlaylistArchive request').not.toBeNull();
    expect(req!.method()).toBe('GET');
  });
});
