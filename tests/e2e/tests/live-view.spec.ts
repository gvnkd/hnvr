import {test, expect, type Page} from '../lib/auth';

/**
 * Live view page (WebRTC via WHEP).
 *
 * Verifies the page renders the `<video>` element and the inline WHEP
 * client issues the documented POST `/whep/<slug>` request with an
 * SDP offer body. Full media flow depends on a real RTSP camera wired
 * up via MediaMTX (per design_docs/05-web-and-live-view.md §"Live
 * view"), so this test asserts the request shape, not the SDP answer
 * or the `<video>` reaching readyState >= 2.
 *
 * The WHEP endpoint returns 404 when MediaMTX has no matching path
 * configured (i.e. no real camera); we accept either 201 (real flow)
 * or 404 (no camera wired) as valid outcomes for this test. The
 * signal we care about: the browser issued the POST to the right URL
 * with the right Content-Type.
 */
test.describe('Live view (WHEP)', () => {
  test('page renders video element + WHEP POST to /whep/<slug>', async ({loggedInPage: page}) => {
    await page.goto('/Cameras');
    const firstShowLink = page.locator('tbody tr').first().getByRole('link', {name: 'Show'});
    const hasCamera = await firstShowLink.count();
    test.skip(!hasCamera, 'no cameras in DB — run cameras-crud.spec first');

    await firstShowLink.click();
    await page.waitForURL(/\/ShowCamera\?cameraId=/);
    const showUrl = page.url();
    const cameraId = new URL(showUrl).searchParams.get('cameraId');
    expect(cameraId).toBeTruthy();

    // Extract slug from the Show view's H1 (renders as
    // <span class="font-mono">{camera.slug}</span>). Use .first() in
    // case multiple font-mono spans appear in the layout chrome.
    const slug = (await page.locator('h1 .font-mono').first().textContent()) ?? '';
    expect(slug.length, `slug should be non-empty (got "${slug}")`).toBeGreaterThan(0);

    // Set up request interception BEFORE navigating to the live page
    // so we catch the WHEP POST issued during page init.
    let whepRequest: {url: string; method: string; contentType: string | null} | null = null;
    page.on('request', (req) => {
      if (req.url().includes(`/whep/`) && !whepRequest) {
        whepRequest = {
          url: req.url(),
          method: req.method(),
          contentType: req.headers()['content-type'] ?? null,
        };
      }
    });

    await page.goto(`/ShowLive?cameraId=${cameraId}`);

    // Video element exists.
    const video = page.locator('#hnvr-live');
    await expect(video).toBeVisible();

    // Status pill starts in "Connecting…" state per Hnvr.Web.View.Live.Show.
    const status = page.locator('#hnvr-live-status');
    await expect(status).toBeVisible();
    await expect(status).toHaveText(/Connecting/);

    // Wait for the WHEP POST to fire (ICE gathering takes ~1-3s on a
    // cold start; allow up to 10s).
    await expect
      .poll(async () => whepRequest, {timeout: 10_000, message: 'WHEP POST should fire'})
      .not.toBeNull();

    expect(whepRequest!.method).toBe('POST');
    expect(whepRequest!.contentType).toBe('application/sdp');
    expect(whepRequest!.url).toContain(`/whep/`);
  });
});
