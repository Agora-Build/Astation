-- Only the active credential's authenticated binding can supply the owner.
-- Other credentials and previously applied releases can veto a stale binding.
WITH candidates AS (
    SELECT DISTINCT ON (r.account_id,r.genesis) r.*, b AS binding
    FROM station_integration_policy current_policy
    CROSS JOIN LATERAL jsonb_array_elements(current_policy.checkpoint::jsonb->'portal_snapshot'->'bindings') b
    JOIN station_binding_release_requests r
      ON (r.account_id,r.genesis,r.account,r.binding_id,r.version) =
         (b->>'accountId',b->>'genesisHash',b->>'account',b->>'bindingId',(b->>'version')::bigint)
    WHERE current_policy.binding=$4 AND (r.issuer,r.portal_origin,r.station_origin)=($1,$2,$3)
      AND b->>'bindingState'='bound' AND r.version < 9007199254740991
    ORDER BY r.account_id,r.genesis,r.release_id
), releases AS (
    SELECT r.* FROM candidates r
    WHERE NOT EXISTS (
        SELECT 1 FROM station_integration_policy p
        CROSS JOIN LATERAL jsonb_array_elements(p.checkpoint::jsonb->'portal_snapshot'->'bindings') other
        WHERE p.binding <> $4 AND p.binding::jsonb - 'report_client_id' = $4::text::jsonb - 'report_client_id'
          AND (other->>'accountId',other->>'genesisHash')=(r.account_id,r.genesis)
          AND ((other->>'version')::bigint > r.version
            OR ((other->>'version')::bigint=r.version AND other <> r.binding))
    ) AND NOT EXISTS (
        SELECT 1 FROM station_native_binding_transitions n
        WHERE (n.issuer,n.portal_origin,n.station_origin,n.account_id,n.genesis)=
              (r.issuer,r.portal_origin,r.station_origin,r.account_id,r.genesis)
          AND (n.version > r.version OR
              (n.version=r.version AND (n.report - 'state' - 'reportId') <> r.binding))
    ) AND NOT EXISTS (
        SELECT 1 FROM station_applied_binding_releases a
        WHERE (a.issuer,a.portal_origin,a.station_origin,a.account_id,a.genesis)=
              (r.issuer,r.portal_origin,r.station_origin,r.account_id,r.genesis)
          AND a.version >= r.version
    ) AND NOT EXISTS (
        SELECT 1 FROM station_binding_release_requests later
        WHERE (later.issuer,later.portal_origin,later.station_origin,later.account_id,later.genesis)=
              (r.issuer,r.portal_origin,r.station_origin,r.account_id,r.genesis)
          AND later.version > r.version
    )
    ORDER BY r.account_id,r.genesis LIMIT 64
)
INSERT INTO station_applied_binding_releases
    (issuer,portal_origin,station_origin,release_id,account_id,genesis,version,report)
SELECT issuer,portal_origin,station_origin,release_id,account_id,genesis,version+1,
       jsonb_build_object('state','binding_changed','account',account,'accountId',account_id,
           'genesisHash',genesis,'bindingId',binding_id,'version',version+1,'bindingState','released',
           'reportId','binding_changed:' || encode(sha256(convert_to(
               jsonb_build_array(account_id,genesis,version+1)::text,'UTF8')),'hex'))
FROM releases
