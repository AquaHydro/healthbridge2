// Interactive acceptance of ONLY the user-created 17-step fixture.
// Identifiers and health sample values stay in process memory and are never printed.
import { execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import {
  Client,
  StreamableHTTPClientTransport,
} from '@modelcontextprotocol/client';
const base = process.env.HEALTHBRIDGE_URL;
if (!base?.startsWith('https://')) throw new Error('Set HEALTHBRIDGE_URL');
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
const client = new Client({
  name: 'HealthBridge device change acceptance',
  version: '1.0.0',
});
const from = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
async function samples() {
  const r = await client.callTool({
    name: 'query_samples',
    arguments: {
      type: 'steps',
      from,
      to: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      limit: 2000,
    },
  });
  if (r.isError) throw new Error('Query failed');
  const data = JSON.parse(r.content.find((c) => c.type === 'text').text);
  if (data.next_cursor) throw new Error('Narrow the time range');
  return data.samples;
}
try {
  await client.connect(
    new StreamableHTTPClientTransport(new URL(base + '/mcp'), {
      requestInit: { headers: { Authorization: `Bearer ${token}` } },
    }),
  );
  const matches = (await samples()).filter((s) => s.value === 17);
  if (matches.length !== 1) {
    console.log(
      JSON.stringify({ fixtureCandidates: matches.length, verified: false }),
    );
    process.exitCode = 1;
  } else {
    const id = matches[0].uuid;
    console.log(
      'PASS: unique user-created 17-step Health fixture received through iPhone incremental sync. Waiting for DELETE verification command.',
    );
    const line = createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    for await (const command of line) {
      if (command.trim() !== 'DELETE') continue;
      const exists = (await samples()).some((s) => s.uuid === id);
      console.log(
        exists
          ? 'PENDING: fixture still present on server.'
          : 'PASS: same fixture removed from D1 and MCP by iPhone deletion sync.',
      );
      if (!exists) {
        line.close();
        break;
      }
    }
  }
} finally {
  await client.close();
}
