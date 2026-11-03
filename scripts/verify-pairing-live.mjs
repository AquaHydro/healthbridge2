import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import {
  Client,
  StreamableHTTPClientTransport,
} from '@modelcontextprotocol/client';
const base = process.env.HEALTHBRIDGE_URL;
if (!base?.startsWith('https://') || !process.env.HEALTHBRIDGE_DEPLOY_CONFIG)
  throw new Error('Set dedicated test deployment URL and configuration.');
const password = execFileSync(
  'security',
  [
    'find-generic-password',
    '-s',
    'HealthBridge deployment',
    '-a',
    'CONNECT_PASSWORD_TEST',
    '-w',
  ],
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
).trim();
const post = (path, data) =>
  fetch(base + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
    redirect: 'error',
  });
const created = await post('/v1/pairing/create', { password });
assert.equal(created.status, 200);
const invitation = await created.json();
assert.ok(invitation.qr.startsWith('<svg'));
const payload = JSON.parse(
  Buffer.from(invitation.link.split('#')[1], 'base64url').toString(),
);
const claimant = randomBytes(32).toString('hex');
const response = await post('/v1/pairing/redeem', {
  code: payload.code,
  claimant,
});
assert.equal(response.status, 200);
const credentials = await response.json();
assert.notEqual(credentials.ingest_token, credentials.mcp_token);
assert.equal(
  (await post('/v1/pairing/redeem', { code: payload.code, claimant })).status,
  200,
);
assert.equal(
  (
    await post('/v1/pairing/redeem', {
      code: payload.code,
      claimant: randomBytes(32).toString('hex'),
    })
  ).status,
  410,
);
assert.equal((await post('/v1/pairing/create', { password })).status, 409);
const environment = {
  ...process.env,
  INGEST_TOKEN: credentials.ingest_token,
  MCP_TOKEN: credentials.mcp_token,
};
const verify = spawnSync(process.execPath, ['scripts/verify-live.mjs'], {
  env: environment,
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'pipe'],
});
assert.equal(verify.status, 0);
process.stdout.write(verify.stdout);
const again = spawnSync(process.execPath, ['scripts/deploy.mjs'], {
  env: process.env,
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'pipe'],
});
assert.equal(again.status, 0);
const client = new Client({
  name: 'HealthBridge deployment stability verification',
  version: '1.0.0',
});
await client.connect(
  new StreamableHTTPClientTransport(new URL(base + '/mcp'), {
    requestInit: {
      headers: { Authorization: `Bearer ${credentials.mcp_token}` },
    },
  }),
);
assert.equal((await client.listTools()).tools.length, 4);
await client.close();
console.log(
  'PASS: live pairing, same-device retry, other-device replay rejection, bootstrap closure and credential-preserving redeploy.',
);
