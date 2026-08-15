-- 0006-pending-delete.sql — tombstone-based recording deletion.
-- Rows are marked pending_delete_at = NOW() instead of being deleted
-- outright; the async purge worker (Hnvr.Web.PendingPurge) deletes the
-- S3 objects, verifies the window is empty, and only then removes the
-- rows. A 60 s sweeper resumes batches whose worker died mid-purge
-- (leader restart, SIGKILL) — closes the "DB rows gone, S3 objects
-- orphaned" hole Sergey hit on 2026-08-15.

ALTER TABLE segments
    ADD COLUMN IF NOT EXISTS pending_delete_at TIMESTAMP WITH TIME ZONE;

-- Partial index: only tombstoned rows (a handful at any time) are
-- indexed; the sweeper's pending-batch lookup stays O(tombstones).
CREATE INDEX IF NOT EXISTS segments_pending_delete_idx
    ON segments (pending_delete_at)
    WHERE pending_delete_at IS NOT NULL;
