-- 0015-camera-model-name: cameras.model_name — per-camera CV model file
-- (resolved against HNVR_MODEL_DIR). The column shipped in
-- Application/Schema.sql but no runtime migration accompanied it, so
-- already-deployed DBs (14 applied migrations) lack it and every
-- cameras SELECT from Generated.Types fails with 42703. ADD COLUMN IF
-- NOT EXISTS keeps fresh DBs (0001-initial + this script) a no-op.
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS model_name TEXT NOT NULL DEFAULT 'yolov8n-320';
