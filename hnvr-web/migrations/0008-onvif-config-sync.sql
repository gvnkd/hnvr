-- ONVIF config sync: sparse desired encoder settings on cameras (NULL =
-- unmanaged) + persistent drift report populated by the OnvifSyncer poller.
-- onvif_port: ONVIF device-service port (80 Hikvision-OEM, 8899 XM);
-- NULL = camera is ONVIF-unmanaged (no push, no drift check).

ALTER TABLE cameras
    ADD COLUMN onvif_port              INT,
    ADD COLUMN main_video_encoding     TEXT,
    ADD COLUMN main_video_width        INT,
    ADD COLUMN main_video_height       INT,
    ADD COLUMN main_video_fps          INT,
    ADD COLUMN main_video_bitrate_kbps INT,
    ADD COLUMN main_video_gov_length   INT,
    ADD COLUMN sub_video_encoding      TEXT,
    ADD COLUMN sub_video_width         INT,
    ADD COLUMN sub_video_height        INT,
    ADD COLUMN sub_video_fps           INT,
    ADD COLUMN sub_video_bitrate_kbps  INT,
    ADD COLUMN sub_video_gov_length    INT,
    ADD COLUMN audio_encoding          TEXT,
    ADD COLUMN audio_bitrate_kbps      INT,
    ADD COLUMN audio_sample_rate_khz   INT;

CREATE TABLE camera_drift (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id     UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    config_name   TEXT NOT NULL,
    field_name    TEXT NOT NULL,
    desired       TEXT NOT NULL,
    observed      TEXT NOT NULL,
    first_seen_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    last_seen_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (camera_id, config_name, field_name)
);

CREATE INDEX camera_drift_camera_idx ON camera_drift (camera_id);
