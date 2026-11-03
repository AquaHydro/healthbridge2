import { execFileSync } from 'node:child_process';
import {
  Client,
  StreamableHTTPClientTransport,
} from '@modelcontextprotocol/client';
const token =
  process.env.MCP_TOKEN ||
  execFileSync(
    'security',
    [
      'find-generic-password',
      '-s',
      'HealthBridge deployment',
      '-a',
      'MCP_TOKEN',
      '-w',
    ],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
  ).trim();
const base = process.env.HEALTHBRIDGE_URL;
if (!base?.startsWith('https://')) throw new Error('Set HEALTHBRIDGE_URL');
const client = new Client({
  name: 'HealthBridge private device verification',
  version: '1.0.0',
});
const decoded = (r) =>
  JSON.parse(r.content.find((c) => c.type === 'text').text);
try {
  await client.connect(
    new StreamableHTTPClientTransport(new URL(base + '/mcp'), {
      requestInit: { headers: { Authorization: `Bearer ${token}` } },
    }),
  );
  const status = decoded(
    await client.callTool({ name: 'get_sync_status', arguments: {} }),
  );
  console.log(
    JSON.stringify({
      counts: status.counts,
      hasSuccessfulUpload: !!status.last_ingest_at,
    }),
  );
  const now = new Date(),
    from = new Date(now.getTime() - 366 * 86400000).toISOString(),
    to = now.toISOString();
  for (const type of ['sleep', 'heart_rate', 'resting_hr', 'hrv', 'steps']) {
    const result = await client.callTool({
      name: 'query_samples',
      arguments: { type, from, to, limit: 1 },
    });
    if (result.isError) throw new Error('Read tool failed');
    console.log(
      `${type}: query succeeded; sample available=${decoded(result).samples.length > 0}`,
    );
  }
  const aggregation = await client.callTool({
    name: 'aggregate',
    arguments: { type: 'heart_rate', from, to, bucket: 'day' },
  });
  if (aggregation.isError) throw new Error('Aggregate failed');
  const sleep = await client.callTool({
    name: 'sleep_summary',
    arguments: {
      from_date: new Date(now.getTime() - 30 * 86400000)
        .toISOString()
        .slice(0, 10),
      to_date: new Date(now.getTime() + 86400000).toISOString().slice(0, 10),
    },
  });
  // Keep sample values, dates, identifiers and source names in memory only.
  if (sleep.isError) throw new Error('Sleep query failed');
  console.log(
    'MCP raw, aggregate and sleep queries verified; values suppressed.',
  );
} finally {
  await client.close();
}
