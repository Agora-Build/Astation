-- A second reporting credential can observe a disable before the signer catches
-- up. Only a complete, later account view can supersede that observation.
CREATE TABLE station_delegated_availability_fences (
    issuer TEXT NOT NULL,
    portal_origin TEXT NOT NULL,
    station_origin TEXT NOT NULL,
    account TEXT NOT NULL,
    minimum_cursor BIGINT NOT NULL CHECK (minimum_cursor BETWEEN 0 AND 9007199254740992),
    PRIMARY KEY (issuer, portal_origin, station_origin, account)
);

-- The empty account denotes a Portal cut with incomplete account coverage.
-- Include exact snapshots retained after the credential or live feed was reset.
WITH saved AS (
    SELECT binding::jsonb AS scope, checkpoint::jsonb AS policy FROM station_integration_policy
), sources AS (
    SELECT scope, policy->'availability' AS accounts,
           (policy->'availability'->>'cursor')::bigint AS cut FROM saved
    UNION ALL
    SELECT scope, policy->'portal_snapshot'->'accounts',
           (policy->'portal_snapshot'->>'cursor')::bigint FROM saved
), denials AS (
    SELECT scope, cut+1 AS floor, account FROM sources
    CROSS JOIN LATERAL jsonb_array_elements_text(accounts->'disabled') AS d(account)
    UNION ALL
    SELECT scope, cut + CASE WHEN accounts->>'complete'='false' THEN 1 ELSE 0 END, ''
    FROM sources WHERE jsonb_typeof(accounts)='object'
    UNION ALL
    SELECT scope, (policy->>'cursor')::bigint, '' FROM saved
    WHERE scope->>'station_origin' IN ('https://station.agora.build', 'https://station-dev.agora.build')
      AND (policy->>'cursor')::bigint > 0
)
INSERT INTO station_delegated_availability_fences
SELECT scope->>'issuer', scope->>'portal_origin', scope->>'station_origin', account, max(floor)
FROM denials GROUP BY 1,2,3,4;
