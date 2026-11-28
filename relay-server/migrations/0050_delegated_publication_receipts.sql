ALTER TABLE station_delegated_recovery
    DROP CONSTRAINT station_delegated_recovery_reason_check,
    ADD CONSTRAINT station_delegated_recovery_reason_check CHECK (
        reason IN ('initialized', 'history_missing', 'generation_changed', 'operator_fenced', 'published')
    );

ALTER TABLE station_delegated_recovery_plans
    ADD COLUMN published_cut_hash TEXT,
    ADD COLUMN published_feed_hash TEXT,
    ADD CONSTRAINT delegated_publication_pair CHECK (
        (published_cut_hash IS NULL AND published_feed_hash IS NULL)
        OR (published_cut_hash IS NOT NULL AND published_feed_hash IS NOT NULL
            AND published_cut_hash ~ '^[0-9a-f]{64}$' AND published_feed_hash ~ '^[0-9a-f]{64}$'
            AND NOT abandoned)
    );
