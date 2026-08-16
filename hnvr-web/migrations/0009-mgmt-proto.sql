-- Management protocol selector for encoder config sync: 'onvif'
-- (default) or 'dvrip' (XM "Sofia" native protocol on :34567 — for
-- cameras whose ONVIF layer is decorative, e.g. low_ent/cam-198).
-- For dvrip rows, onvif_port holds the DVRIP port.

ALTER TABLE cameras ADD COLUMN mgmt_proto TEXT NOT NULL DEFAULT 'onvif';
