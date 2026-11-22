import assert from 'node:assert/strict';

// Change discovery only; retain production paths, headers, timeouts and retries.
export function withSharedPeers(source, peers, options = '') {
  const configured = source.replace(/^    set \$station_relay [^;]+;$/m,
    '    set $station_relay station_relay_fixture;');
  assert.notEqual(configured, source, 'the fixture must replace peer discovery');
  return `upstream station_relay_fixture {\n${options}\n${peers}\n}\n${configured}`;
}
