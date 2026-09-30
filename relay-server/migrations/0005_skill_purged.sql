-- Skill history needs to tell a purged version (its files were erased) from a
-- delete marker (never had files): both are stored as deleted = true,
-- files = {}, content_hash = ''. `purge` now sets this flag. Versions purged
-- before this migration can't be told apart and stay false (shown as deleted).
ALTER TABLE skill_versions ADD COLUMN purged BOOLEAN NOT NULL DEFAULT false;
