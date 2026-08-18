/* HNVR PTZ control widget (Phase 5, design 05 §"PTZ control").
 *
 * Vanilla JS, no dependencies. All commands POST form-encoded to
 * /PtzCamera?ptzCameraId=… and are relayed over NATS to the owning
 * host; set_preset/delete go through /CreatePtzPreset//PurgePtzPreset
 * (which keep the DB rows in sync) with format=json.
 *
 * Press-and-hold semantics: pointerdown starts a ContinuousMove,
 * pointerup/pointerleave/pointercancel issues Stop.
 *
 * HNVR.ptz(cameraId, rootEl) binds one panel. rootEl defaults to
 * document (the /ShowLive inline call); the dashboard overlay passes
 * the container it cloned the panel template into. Returns a handle
 * with close() — stops the status poller (overlay teardown).
 */
window.HNVR = window.HNVR || {};

HNVR.ptz = function (cameraId, rootEl) {
  var root = rootEl || document;
  var panel = root.id === 'ptz-panel' ? root : root.querySelector('#ptz-panel');
  if (!panel) return { close: function () {} };

  var base = '/PtzCamera?ptzCameraId=' + encodeURIComponent(cameraId);

  function send(params) {
    return fetch(base + '&' + params, { method: 'POST' })
      .then(function (r) { return r.json(); })
      .catch(function () { return { ok: false, error: 'network error' }; });
  }

  function move(vx, vy, zoom) {
    send('command=continuous_move&vx=' + vx + '&vy=' + vy + '&zoom=' + zoom);
  }

  function stop() {
    send('command=stop&pan_tilt=true&zoom_stop=true');
  }

  /* 8-way pad + zoom: hold to move, release to stop. */
  panel.querySelectorAll('button[data-vx], button[data-vz]').forEach(function (btn) {
    var start = function (ev) {
      ev.preventDefault();
      var vx = parseFloat(btn.dataset.vx || '0');
      var vy = parseFloat(btn.dataset.vy || '0');
      var vz = parseFloat(btn.dataset.vz || '0');
      move(vx, vy, vz);
    };
    btn.addEventListener('pointerdown', start);
    btn.addEventListener('pointerup', stop);
    btn.addEventListener('pointerleave', stop);
    btn.addEventListener('pointercancel', stop);
  });

  var homeBtn = panel.querySelector('#ptz-home');
  if (homeBtn) homeBtn.addEventListener('click', function () { send('command=go_home'); });

  var stopBtn = panel.querySelector('#ptz-stop');
  if (stopBtn) stopBtn.addEventListener('click', stop);

  var select = panel.querySelector('#ptz-preset-select');

  var goBtn = panel.querySelector('#ptz-preset-go');
  if (goBtn) goBtn.addEventListener('click', function () {
    if (select.value) send('command=goto_preset&preset_token=' + encodeURIComponent(select.value));
  });

  var saveBtn = panel.querySelector('#ptz-preset-save');
  if (saveBtn) saveBtn.addEventListener('click', function () {
    var name = window.prompt('Preset name:');
    if (!name) return;
    fetch('/CreatePtzPreset?ptzCameraId=' + encodeURIComponent(cameraId) + '&format=json&preset_name=' + encodeURIComponent(name), { method: 'POST' })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.ok && res.token) {
          var opt = document.createElement('option');
          opt.value = res.token;
          opt.textContent = name;
          opt.dataset.presetId = res.preset_id;
          select.appendChild(opt);
          select.value = res.token;
        } else {
          window.alert('Save preset failed: ' + (res.error || 'unknown error'));
        }
      });
  });

  var delBtn = panel.querySelector('#ptz-preset-del');
  if (delBtn) delBtn.addEventListener('click', function () {
    var opt = select.options[select.selectedIndex];
    if (!opt || !opt.dataset.presetId) return;
    if (!window.confirm('Delete preset "' + opt.textContent + '"?')) return;
    fetch('/PurgePtzPreset?ptzPresetId=' + encodeURIComponent(opt.dataset.presetId) + '&format=json', { method: 'POST' })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.ok) select.removeChild(opt);
        else window.alert('Delete failed: ' + (res.error || 'unknown error'));
      });
  });

  /* Status indicator: 1 Hz poll of the latest status broadcast. */
  var statusEl = panel.querySelector('#ptz-status');
  var pollTimer = null;
  function pollStatus() {
    fetch('/PtzStatusCamera?ptzCameraId=' + encodeURIComponent(cameraId))
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.ok && res.status) {
          statusEl.textContent = res.status.state + ' · ' + res.status.last_command;
          statusEl.className = 'badge badge-info';
        } else {
          statusEl.textContent = 'no status';
          statusEl.className = 'badge badge-mute';
        }
      })
      .catch(function () { /* keep last */ });
  }
  if (statusEl) {
    pollStatus();
    pollTimer = setInterval(pollStatus, 1000);
  }

  return {
    close: function () {
      if (pollTimer) clearInterval(pollTimer);
      pollTimer = null;
    },
  };
};
