-- 0004-audit-log.sql — Phase 4: admin action audit log.
-- Design: design_docs/06-data-model.md ("Audit log").

CREATE TABLE IF NOT EXISTS audit_log (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID REFERENCES users(id),
    action          TEXT NOT NULL,                               -- 'camera.create', 'rule.delete', ...
    target_type     TEXT NOT NULL,
    target_id       UUID,
    payload         JSONB,
    ts              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS audit_ts_idx ON audit_log (ts DESC);
