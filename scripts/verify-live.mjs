import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  Client,
  StreamableHTTPClientTransport,
} from '@modelcontextprotocol/client';
const base = process.env.HEALTHBRIDGE_URL;
if (!base || !base.startsWith('https://'))
  throw new Error('Set HEALTHBRIDGE_URL to your deployed HTTPS origin');
const readToken = (name) =>
  process.env[name] ||
  execFileSync(
    'security',
    [
      'find-generic-password',
      '-s',
      'HealthBridge deployment',
      '-a',
      name,
      '-w',
    ],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
  ).trim();
const writer = readToken('INGEST_TOKEN'),
  reader = readToken('MCP_TOKEN');
const req = (path, token, method = 'GET', payload) =>
  fetch(base + path, {
    method,
    redirect: 'error',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    ...(payload ? { body: JSON.stringify(payload) } : {}),
  });
const decode = (result) =>
  JSON.parse(result.content.find((c) => c.type === 'text').text);
const c = new Client({
  name: 'HealthBridge live acceptance',
  version: '1.0.0',
});
const id = crypto.randomUUID(),
  time = Date.parse('2001-01-03T01:00:00Z');
const sample = {
  uuid: id,
  type: 'heart_rate',
  start_ms: time,
  end_ms: time,
  tz_min: 480,
  value: 61,
  unit: 'bpm',
  source: 'HealthBridge synthetic acceptance',
  device: 'Synthetic',
};
let wrote = false;
try {
  assert.equal((await req('/v1/ping', 'invalid')).status, 401);
  assert.equal((await req('/v1/ping', reader)).status, 401);
  assert.equal((await req('/mcp', writer, 'POST', {})).status, 401);
  assert.equal((await req('/v1/data', reader, 'DELETE')).status, 401);
  const baseline = await (await req('/v1/ping', writer)).json();
  assert.equal(baseline.schema_version, 1);
  for (let i = 0; i < 2; i++) {
    assert.equal(
      (
        await req('/v1/ingest', writer, 'POST', {
          schema_version: 1,
          added: [sample],
          deleted: [],
        })
      ).status,
      200,
    );
    wrote = true;
  }
  const after = await (await req('/v1/ping', writer)).json();
  assert.ok(after.counts.heart_rate >= 1);
  await c.connect(
    new StreamableHTTPClientTransport(new URL(base + '/mcp'), {
      requestInit: { headers: { Authorization: `Bearer ${reader}` } },
    }),
  );
  const list = await c.listTools();
  assert.deepEqual(list.tools.map((t) => t.name).sort(), [
    'aggregate',
    'get_sync_status',
    'query_samples',
    'sleep_summary',
  ]);
  const args = {
    type: 'heart_rate',
    from: '2001-01-03',
    to: '2001-01-04',
    tz: 0,
  };
  const raw = decode(
    await c.callTool({ name: 'query_samples', arguments: args }),
  );
  // A live iPhone may upload concurrently; verify this UUID, not global count equality.
  assert.equal(raw.samples.filter((s) => s.uuid === id).length, 1);
  const aggregate = decode(
    await c.callTool({
      name: 'aggregate',
      arguments: { ...args, bucket: 'day' },
    }),
  );
  assert.ok(aggregate.buckets.some((b) => b.count >= 1));
  assert.ok(
    'nights' in
      decode(
        await c.callTool({
          name: 'sleep_summary',
          arguments: { from_date: '2001-01-03', to_date: '2001-01-04' },
        }),
      ),
  );
  const status = decode(
    await c.callTool({ name: 'get_sync_status', arguments: {} }),
  );
  assert.ok(status.counts.heart_rate >= 1);
  console.log(
    'PASS: HTTPS authentication, token isolation, idempotent D1 upload, MCP initialization, four read-only tools.',
  );
} finally {
  if (wrote) {
    assert.equal(
      (
        await req('/v1/ingest', writer, 'POST', {
          schema_version: 1,
          added: [],
          deleted: [id],
        })
      ).status,
      200,
    );
    console.log('PASS: synthetic sample cleanup.');
  }
  await c.close();
}
