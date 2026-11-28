-- Earlier receipts remain historical evidence. A new batch also keeps the
-- pre-reservation clock evidence needed to verify its fresh signatures later.
ALTER TABLE station_delegated_service_components
    ADD COLUMN signing_cut JSONB CHECK (
        jsonb_typeof(signing_cut) = 'object' AND octet_length(signing_cut::text) <= 16777216
    );
