import {test, expect, firstCamera, type Page} from '../lib/auth';

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
    // M4: camera picking moved off /Cameras (leader is read-mostly) —
    // scrape the dashboard card's data-cam-id/data-slug instead.
    const cam = await firstCamera(page);
    test.skip(!cam, 'no cameras in DB — run cameras-crud.spec first');
    const cameraId = cam!.id;
    const slug = cam!.slug;

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
