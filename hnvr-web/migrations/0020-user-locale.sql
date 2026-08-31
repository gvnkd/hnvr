-- 0020-user-locale: per-user display locale (BCP 47 tag, e.g. en-GB,
-- ru-RU). NULL = browser locale. Consumed client-side by
-- HNVR.formatTs (body[data-user-locale]).
ALTER TABLE users ADD COLUMN IF NOT EXISTS locale TEXT;
