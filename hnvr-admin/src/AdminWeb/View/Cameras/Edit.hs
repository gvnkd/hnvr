{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module AdminWeb.View.Cameras.Edit (EditView (..)) where

import AdminWeb.View.Layout (renderAdminLayout)
import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), cameraAllowed)
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Onvif
import Hnvr.Web.Authz (currentRoleSet)
import Hnvr.Web.OnvifSync (FormOptions (..), skipReasonFor)
import IHP.ModelSupport (Id' (Id))
import IHP.ViewPrelude

data EditView = EditView
  { camera :: Camera,
    -- | Live ONVIF capabilities per stream (Nothing = camera
    -- unreachable/unmanaged → free-text fallback inputs).
    formOptions :: Maybe FormOptions
  }

instance View EditView where
  html EditView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Edit · <span class="font-mono t-accent">{camera.slug}</span></h1>
          <div class="subtitle">RTSP source configuration</div>
        </div>
        <div class="actions">
          <a class="btn btn-ghost" href={showUrl}>← Back</a>
        </div>
      </div>

      <div class="card">
        <div class="card-header">Camera definition</div>
        <div class="card-body">{renderForm camera formOptions}</div>
      </div>

      <div class="card mt-4">
        <div class="card-header">Stream probe</div>
        <div class="card-body">
          <p class="text-sm muted mb-4">
            Probe the main RTSP URL (and the sub URL when present) with
            <span class="mono">ffprobe</span> to fill codec + sub-stream
            fields automatically.
          </p>
          <form method="POST" action={probeUrl}>
            <button class="btn" type="submit">Probe Streams</button>
          </form>
        </div>
      </div>

      <div class="card mt-4">
        <div class="card-header">PTZ probe</div>
        <div class="card-body">
          <p class="text-sm muted mb-4">
            Discover the camera's ONVIF PTZ service and media profile
            token; enables PTZ when found.
          </p>
          <form method="POST" action={probePtzUrl}>
            <button class="btn" type="submit">Probe PTZ</button>
          </form>
        </div>
      </div>
    |]
    where
      cid = tshow (camera |> get #id)
      showUrl = "/ShowCamera?cameraId=" <> cid
      probeUrl = "/ProbeCamera?cameraId=" <> cid
      probePtzUrl = "/ProbePtzCamera?cameraId=" <> cid
      presetsUrl = "/PtzPresets?ptzCameraId=" <> cid

      renderForm camera mOpts =
        [hsx|
          <form class="form" method="POST" action={updateUrl camera}>
            {textFieldFor "slug" "Slug" camera.slug ""}
            {textFieldFor "name" "Name" camera.name ""}
            {textFieldFor "rtspUrl" "RTSP URL (main)" camera.rtspUrl ""}
            <div class="field">
              <label>RTSP transport</label>
              <select name="rtspTransport">
                <option value="tcp" selected={camera.rtspTransport == "tcp"}>tcp (default; recommended for LAN)</option>
                <option value="udp" selected={camera.rtspTransport == "udp"}>udp (use if camera rejects TCP SETUP)</option>
              </select>
            </div>
            {textFieldFor "rtspSubUrl" "RTSP URL (sub, optional)" (fromMaybe "" camera.rtspSubUrl) ""}
            {textFieldFor "username" "Username" (fromMaybe "" camera.username) ""}
            {textFieldFor "password" "Password (blank = keep current)" ("" :: Text) "Stored encrypted; leave blank to retain existing value."}
            {textFieldFor "host" "Host IP" (fromMaybe "" camera.host) ""}
            {textFieldFor "retentionHours" "Full-record retention (hours)" (tshow camera.retentionHours) "Event clips have their own per-rule retention"}

            <div class="field">
              <label>Capture &amp; analysis</label>
              <label><input type="checkbox" name="enabled" checked={camera.enabled} /> enabled (record + analyze)</label>
              <label><input type="checkbox" name="recordAudio" checked={camera.recordAudio} /> record audio track (band-passed 60 Hz–14 kHz, AAC, muxed into video segments)</label>
              <label><input type="checkbox" name="useSubstreamForAnalysis" checked={camera.useSubstreamForAnalysis} /> use sub-stream for CV analysis</label>
            </div>
            {intFieldFor "analysisFps" "Analysis FPS" (Just camera.analysisFps) "Frames per second through the detector (1–15)"}
            <div class="field">
              <label>Snapshot interval (seconds)</label>
              <input class="input" type="number" name="snapshotIntervalSec" value={tshow camera.snapshotIntervalSec} min="0" max="3600" />
              <div class="hint">Periodic JPEG for the archive timeline thumbnails — 0 disables</div>
            </div>

            <div class="field">
              <label>Analysis model</label>
              <select name="modelName">
                <option value="yolov8n-320" selected={camera.modelName == "yolov8n-320"}>yolov8n-320 (default)</option>
                <option value="yolov8s-640" selected={camera.modelName == "yolov8s-640"}>yolov8s-640 (hnvr-2 only)</option>
              </select>
              <div class="hint">Resolved to &lt;model-dir&gt;/&lt;name&gt;.onnx on the assigned host</div>
            </div>

            <div class="card mt-4">
              <div class="card-header">ONVIF encoder settings (desired)</div>
              <div class="card-body">
                {pushInactiveWarning}
                <p class="text-sm muted mb-4">
                  Pushed to the camera on Save Changes and drift-checked periodically.
                  Empty fields are unmanaged — left alone on the camera.
                  {optsNote}
                </p>
                {intFieldFor "onvifPort" "Management port" camera.onvifPort "REQUIRED for any push or drift check: the camera's ONVIF device-service HTTP port (80 for Hikvision-OEM, 8899 for XM) or the DVRIP port (34567) when mgmt_proto=dvrip. Empty = no management at all — saving shows a warning and nothing is ever pushed"}
                <div class="field">
                  <label>Management protocol</label>
                  <select name="mgmtProto">
                    <option value="onvif" selected={camera.mgmtProto == "onvif"}>onvif (default)</option>
                    <option value="dvrip" selected={camera.mgmtProto == "dvrip"}>dvrip (XM native — ONVIF decorative)</option>
                  </select>
                  <div class="hint">dvrip manages encoding/fps/bitrate/GOP via Simplify.Encode; audio codec is not configurable on XM</div>
                </div>

                <div class="subtitle mt-4">Main stream video</div>
                {videoSection "mainVideo" (camera.mainVideoEncoding, camera.mainVideoWidth, camera.mainVideoHeight, camera.mainVideoFps, camera.mainVideoBitrateKbps, camera.mainVideoGovLength) (mOpts >>= \o -> o.foMain)}

                <div class="subtitle mt-4">Sub-stream video</div>
                {videoSection "subVideo" (camera.subVideoEncoding, camera.subVideoWidth, camera.subVideoHeight, camera.subVideoFps, camera.subVideoBitrateKbps, camera.subVideoGovLength) (mOpts >>= \o -> o.foSub)}

                <div class="subtitle mt-4">Audio</div>
                {audioSection camera.audioEncoding camera.audioBitrateKbps camera.audioSampleRateKhz (mOpts >>= \o -> o.foAudio)}
              </div>
            </div>

            <div class="card mt-4">
              <div class="card-header">PTZ (manual control + presets)</div>
              <div class="card-body">
                <p class="text-sm muted mb-4">
                  Requires an ONVIF PTZ service on the camera (mgmt_proto=onvif,
                  management port set, credentials working). Use Probe PTZ to
                  verify and fill the profile token.
                  <a href={presetsUrl}>Manage presets →</a>
                </p>
                <div class="field">
                  <label><input type="checkbox" name="ptzEnabled" checked={camera.ptzEnabled} /> PTZ enabled (joystick on live view, preset return-home)</label>
                  <label><input type="checkbox" name="ptzViewerControl" checked={camera.ptzViewerControl} /> allow non-admin viewers to control PTZ</label>
                </div>
                {textFieldFor "ptzProfileToken" "Media profile token" (fromMaybe "" camera.ptzProfileToken) "ONVIF profile the PTZ ops address (filled by Probe PTZ)"}
                {intFieldFor "ptzIdleTimeoutS" "Idle timeout (s)" (Just camera.ptzIdleTimeoutS) "Return to home preset after this many seconds without PTZ input; 0 disables"}
              </div>
            </div>

            <div class="flex items-center gap-2 mt-6">
              <button class="btn btn-primary" type="submit">Save Changes</button>
              <a class="btn btn-ghost" href={showUrl}>Cancel</a>
            </div>
          </form>

          {dangerZone}

          <script>
            document.querySelectorAll("select[data-res-select]").forEach(function (sel) {
              sel.addEventListener("change", function () {
                var w = document.querySelector("input[name='" + sel.dataset.widthTarget + "']");
                var h = document.querySelector("input[name='" + sel.dataset.heightTarget + "']");
                var parts = sel.value.split("x");
                if (parts.length === 2) { w.value = parts[0]; h.value = parts[1]; }
                else { w.value = ""; h.value = ""; }
              });
            });
          </script>
        |]
        where
          optsNote = case mOpts of
            Just _ -> [hsx| <span>Dropdowns list values reported by the camera.</span>|]
            Nothing -> [hsx| <span class="t-warn">Camera unreachable or unmanaged — free-text inputs shown; values are validated on push only.</span>|]
          -- Delete is its own ACL action (design_docs/13): the danger
          -- zone renders only with the per-camera delete_camera grant.
          dangerZone =
            if not (cameraAllowed rs DeleteCamera camId)
              then [hsx||]
              else
                [hsx|
                  <div class="card mt-4">
                    <div class="card-header">Danger zone</div>
                    <div class="card-body">
                      <p class="text-sm muted mb-4">
                        Deleting the camera stops its worker immediately, removes ALL its database history
                        (segments, events, snapshots, rules, presets — FK cascade), and purges every stored
                        object under its S3 prefix in the background.
                      </p>
                      <form method="POST" action={deleteUrl camera} data-confirm={"Delete camera " <> camera.slug <> "? All recordings and history are permanently removed."}>
                        <input type="hidden" name="_method" value="DELETE" />
                        <button class="btn btn-danger" type="submit">Delete Camera</button>
                      </form>
                    </div>
                  </div>
                |]
          rs = currentRoleSet
          camId = case camera |> get #id of Id u -> CameraId u
          -- Same predicate the save path uses: a camera whose push is
          -- skipped (port NULL etc.) says so here, not just after a
          -- save that quietly did nothing (2026-08-29 prod incident:
          -- both cameras sat unmanaged with no visible hint).
          pushInactiveWarning = case skipReasonFor camera of
            Just reason ->
              [hsx|
                <div class="alert alert-warn">
                  <strong>Encoder management is INACTIVE for this camera.</strong><br />
                  {reason}
                </div>
              |]
            Nothing -> [hsx||]

      updateUrl cam = "/UpdateCamera?cameraId=" <> tshow (cam |> get #id)

      -- \| AutoRoute maps Delete* to HTTP DELETE; plain forms use the
      -- _method override (same pattern as the layout's logout form).
      deleteUrl cam = "/DeleteCamera?cameraId=" <> tshow (cam |> get #id)

      -- \| One video stream section. With live options: dropdowns for
      -- encoding + resolution (a select feeding hidden width/height
      -- inputs, split by the inline script above) + ranged inputs for
      -- fps/bitrate/gov. Without: plain number inputs.
      videoSection prefix (enc, w, h, fps, br, gov) mOpts =
        [hsx|
          {encSelect (prefix <> "Encoding") enc (voEncodings <$> mOpts)}
          {resField prefix w h mOpts}
          {intRanged (prefix <> "Fps") "FPS" fps (mOpts >>= \o -> o.voFpsRange)}
          {intRanged (prefix <> "BitrateKbps") "Bitrate (kbps)" br (mOpts >>= \o -> o.voBitrateRangeKbps)}
          {intRanged (prefix <> "GovLength") "GOP length (frames)" gov (mOpts >>= \o -> o.voGovRange)}
        |]

      resField prefix w h mOpts = case mOpts of
        Just opts
          | not (null opts.voResolutions) ->
              let currentRes = (,) <$> w <*> h
                  resChoices = case currentRes of
                    Just cur | cur `notElem` opts.voResolutions -> cur : opts.voResolutions
                    _ -> opts.voResolutions
               in [hsx|
                    <div class="field">
                      <label>Resolution</label>
                      <select class="input" data-res-select="1" data-width-target={prefix <> "Width"} data-height-target={prefix <> "Height"}>
                        <option value="" selected={isNothing w}>unmanaged</option>
                        {forEach resChoices (resOption currentRes)}
                      </select>
                      <input type="hidden" name={prefix <> "Width"} value={maybe "" tshow w} />
                      <input type="hidden" name={prefix <> "Height"} value={maybe "" tshow h} />
                      <div class="hint">Resolutions reported by the camera for this stream</div>
                    </div>
                  |]
        _ ->
          [hsx|
            {intFieldFor (prefix <> "Width") "Width (px)" w ""}
            {intFieldFor (prefix <> "Height") "Height (px)" h ""}
          |]

      resOption current (rw, rh) =
        [hsx|<option value={tshow rw <> "x" <> tshow rh} selected={current == Just (rw, rh)}>{tshow rw}×{tshow rh}</option>|]

      encSelect name' current mEncs =
        [hsx|
          <div class="field">
            <label>Encoding</label>
            <select name={name'}>
              <option value="" selected={isNothing current}>unmanaged</option>
              {forEach encChoices (encOption current)}
            </select>
          </div>
        |]
        where
          encChoices = case mEncs of
            Just encs
              | filtered@(_ : _) <- filter (/= VEncJpeg) encs -> map videoEncodingText filtered
            _ -> ["H264", "H265"]

      encOption current e =
        [hsx|<option value={e} selected={current == Just e}>{e}</option>|]

      audioSection enc br sr mOpts =
        [hsx|
          {audioEncSelect enc (aoEncodings <$> mOpts)}
          {audioListSelect "audioBitrateKbps" "Bitrate (kbps)" br (aoBitratesKbps <$> mOpts)}
          {audioListSelect "audioSampleRateKhz" "Sample rate (kHz)" sr (aoSampleRatesKhz <$> mOpts)}
        |]

      audioEncSelect current mEncs =
        [hsx|
          <div class="field">
            <label>Encoding</label>
            <select name="audioEncoding">
              <option value="" selected={isNothing current}>unmanaged</option>
              {forEach encChoices (encOption current)}
            </select>
          </div>
        |]
        where
          encChoices = case mEncs of
            Just encs | not (null encs) -> map audioEncodingText encs
            _ -> ["G711", "G726", "AAC"]

      audioListSelect name' label' current mItems = case mItems of
        Just items
          | not (null items) ->
              [hsx|
                <div class="field">
                  <label>{label'}</label>
                  <select name={name'}>
                    <option value="" selected={isNothing current}>unmanaged</option>
                    {forEach (withCurrent current items) (audioItemOption current)}
                  </select>
                </div>
              |]
        _ -> intFieldFor name' label' current ""
        where
          withCurrent (Just cur) items
            | cur `notElem` items = cur : items
          withCurrent _ items = items

      audioItemOption current i =
        [hsx|<option value={tshow i} selected={current == Just i}>{tshow i}</option>|]

      -- \| Number input; when the camera reports an allowed range, show
      -- it as the hint and clamp via min/max attributes.
      intRanged name' label' value' mRange =
        [hsx|
          <div class="field">
            <label>{label'}</label>
            <input class="input" type="number" name={name'} value={maybe "" tshow value'} min={rangeMin} max={rangeMax} />
            <div class="hint">{hint}</div>
          </div>
        |]
        where
          (rangeMin, rangeMax, hint) = case mRange of
            Just (lo, hi) -> (tshow lo, tshow hi, "allowed " <> tshow lo <> "–" <> tshow hi)
            Nothing -> ("" :: Text, "" :: Text, "" :: Text)

      intFieldFor name' label' value' hint' =
        [hsx|
          <div class="field">
            <label>{label'}</label>
            <input class="input" type="number" name={name'} value={maybe "" tshow value'} />
            <div class="hint">{hint'}</div>
          </div>
        |]

      textFieldFor name' label' value' hint' =
        [hsx|
          <div class="field">
            <label>{label'}</label>
            <input class="input" type="text" name={name'} value={value'} />
            <div class="hint">{hint'}</div>
          </div>
        |]
