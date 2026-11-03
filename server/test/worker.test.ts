import { env, exports } from 'cloudflare:workers';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  Client,
  StreamableHTTPClientTransport,
} from '@modelcontextprotocol/client';
import migration from '../migrations/0001_init.sql?raw';
import hourlyMigration from '../migrations/0003_hourly.sql?raw';
import pairingMigration from '../migrations/0002_pairing.sql?raw';
import { time, range } from '../src/schema';
import { status } from '../src/data';
type Status = Awaited<ReturnType<typeof status>>;
import { summarizeSleep } from '../src/sleep';

const writer = 'synthetic-ingest-test-only',
  reader = 'synthetic-mcp-test-only';
const sample = (overrides = {}) => ({
  uuid: crypto.randomUUID(),
  type: 'heart_rate',
  start_ms: Date.parse('2026-11-02T16:30:00Z'),
  end_ms: Date.parse('2026-11-02T16:30:00Z'),
  tz_min: 480,
  value: 60,
  unit: 'bpm',
  source: 'Synthetic Watch',
  device: 'Synthetic1',
  ...overrides,
});
const fetcher = (
  path: string,
  method = 'GET',
  token = writer,
  payload?: unknown,
) =>
  exports.default.fetch(`https://example.test${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    ...(payload !== undefined ? { body: JSON.stringify(payload) } : {}),
  });
const upload = (added: unknown[], deleted: string[] = []) =>
  fetcher('/v1/ingest', 'POST', writer, { schema_version: 1, added, deleted });
async function client() {
  const c = new Client({ name: 'healthbridge-tests', version: '1.0.0' });
  await c.connect(
    new StreamableHTTPClientTransport(new URL('https://example.test/mcp'), {
      requestInit: { headers: { Authorization: `Bearer ${reader}` } },
      fetch: async (input, init) =>
        exports.default.fetch(new Request(input, init)),
    }),
  );
  return c;
}
function textResult(r: Awaited<ReturnType<Client['callTool']>>) {
  const content = r.content as { type: string; text?: string }[];
  return JSON.parse(content[0]!.text!);
}
beforeAll(async () => {
  const sql = migration + '\n' + pairingMigration + '\n' + hourlyMigration;
  await env.DB.batch(
    sql
      .split(';')
      .filter((s) => s.trim())
      .map((s) => env.DB.prepare(s)),
  );
});
beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM samples'),
    env.DB.prepare('DELETE FROM hourly'),
    env.DB.prepare('DELETE FROM hourly_ranges'),
    env.DB.prepare('DELETE FROM meta'),
    env.DB.prepare('DELETE FROM pairing_tickets'),
    env.DB.prepare('DELETE FROM pairing_owners'),
    env.DB.prepare('DELETE FROM pairing_attempts'),
  ]);
});
describe('HTTP and D1 contract', () => {
  it.each(['/healthz', '/v1/ping', '/v1/ingest', '/v1/data', '/mcp'])(
    'requires auth on %s',
    async (path) =>
      expect((await fetcher(path, 'GET', 'wrong')).status).toBe(401),
  );
  it('isolates writer and reader', async () => {
    expect((await fetcher('/v1/ping', 'GET', reader)).status).toBe(401);
    expect((await fetcher('/v1/data', 'DELETE', reader)).status).toBe(401);
    expect((await fetcher('/v1/ingest', 'POST', reader, {})).status).toBe(401);
    expect((await fetcher('/mcp', 'POST', writer, {})).status).toBe(401);
  });
  it('rejects foreign browser origins', async () => {
    const r = await exports.default.fetch('https://example.test/mcp', {
      headers: {
        Authorization: `Bearer ${reader}`,
        Origin: 'https://evil.test',
      },
    });
    expect(r.status).toBe(403);
  });
  it('writes idempotently and deletes before status', async () => {
    const s = sample();
    expect((await upload([s])).status).toBe(200);
    expect((await upload([s, s])).status).toBe(200);
    expect(
      (await (await fetcher('/v1/ping')).json<Status>()).counts.heart_rate,
    ).toBe(1);
    expect((await upload([s], [s.uuid])).status).toBe(200);
    const state = await (await fetcher('/v1/status')).json<Status>();
    expect(state.counts.heart_rate).toBe(0);
    expect(
      state.types.find((r: { type: string }) => r.type === 'heart_rate')!
        .last_sample,
    ).toBeNull();
  });
  it.each([
    { type: 'unknown' },
    { unit: 'ms' },
    { value: -1 },
    { end_ms: 1 },
    { uuid: 'invalid' },
    { type: 'sleep', unit: null, value: 6 },
    { type: 'steps', unit: 'count', value: 1.5 },
  ])('rejects entire invalid batch %j', async (patch) => {
    expect((await upload([sample(), sample(patch)])).status).toBe(400);
    expect(
      await env.DB.prepare('SELECT COUNT(*) n FROM samples').first('n'),
    ).toBe(0);
  });
  it('bounds batches and streamed body', async () => {
    expect(
      (await upload(Array.from({ length: 1001 }, () => sample()))).status,
    ).toBe(413);
    expect(
      (await upload([], Array(5001).fill(crypto.randomUUID()))).status,
    ).toBe(413);
    const r = await exports.default.fetch('https://example.test/v1/ingest', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${writer}`,
        'Content-Type': 'application/json',
      },
      body: ' '.repeat(10 * 1024 * 1024 + 1),
    });
    expect(r.status).toBe(413);
  });
  it('accepts maximum added batch within query budget', async () => {
    expect(
      (await upload(Array.from({ length: 1000 }, () => sample()))).status,
    ).toBe(200);
    expect(
      await env.DB.prepare('SELECT COUNT(*) n FROM samples').first('n'),
    ).toBe(1000);
  });
  it('clears type or all data and metadata', async () => {
    await upload([sample(), sample({ type: 'steps', unit: 'count' })]);
    expect((await fetcher('/v1/data?type=unknown', 'DELETE')).status).toBe(400);
    await fetcher('/v1/data?type=heart_rate', 'DELETE');
    expect(
      (await (await fetcher('/v1/ping')).json<Status>()).counts.steps,
    ).toBe(1);
    await fetcher('/v1/data', 'DELETE');
    expect(
      await env.DB.prepare('SELECT COUNT(*) n FROM samples').first('n'),
    ).toBe(0);
    expect(await env.DB.prepare('SELECT COUNT(*) n FROM meta').first('n')).toBe(
      0,
    );
  });
  it('rolls back the whole transaction on database failure', async () => {
    await env.DB.exec(
      "CREATE TRIGGER fail_write BEFORE INSERT ON samples WHEN NEW.value = 999 BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;",
    );
    try {
      expect((await upload([sample(), sample({ value: 999 })])).status).toBe(
        503,
      );
      expect(
        await env.DB.prepare('SELECT COUNT(*) n FROM samples').first('n'),
      ).toBe(0);
    } finally {
      await env.DB.exec('DROP TRIGGER fail_write');
    }
  });
});
describe('MCP client over Streamable HTTP', () => {
  it('initializes, exposes only four read tools and calls all', async () => {
    await upload([sample(), sample({ value: 80 })]);
    const c = await client();
    try {
      const listed = await c.listTools();
      expect(listed.tools.map((t) => t.name).sort()).toEqual([
        'aggregate',
        'get_sync_status',
        'query_samples',
        'sleep_summary',
      ]);
      expect(listed.tools.every((t) => t.annotations?.readOnlyHint)).toBe(true);
      const st = textResult(
        await c.callTool({ name: 'get_sync_status', arguments: {} }),
      );
      expect(st.counts.heart_rate).toBe(2);
      const args = {
        type: 'heart_rate',
        from: '2026-11-03',
        to: '2026-11-04',
        tz: 480,
      };
      const raw = textResult(
        await c.callTool({
          name: 'query_samples',
          arguments: { ...args, limit: 1 },
        }),
      );
      expect(raw.samples).toHaveLength(1);
      expect(raw.samples[0].start.local).toContain('+08:00');
      expect(raw.next_cursor).not.toBeNull();
      const second = textResult(
        await c.callTool({
          name: 'query_samples',
          arguments: { ...args, limit: 1, cursor: raw.next_cursor },
        }),
      );
      expect(second.samples).toHaveLength(1);
      expect(second.next_cursor).toBeNull();
      const aggregate = textResult(
        await c.callTool({
          name: 'aggregate',
          arguments: { ...args, bucket: 'day' },
        }),
      );
      expect(aggregate.buckets[0].avg).toBe(70);
      expect(aggregate.buckets[0].count).toBe(2);
      expect(
        textResult(
          await c.callTool({
            name: 'sleep_summary',
            arguments: { from_date: '2026-11-01', to_date: '2026-11-04' },
          }),
        ).nights,
      ).toEqual([]);
      expect(
        (
          await c.callTool({
            name: 'query_samples',
            arguments: { ...args, to: '2026-11-01' },
          })
        ).isError,
      ).toBe(true);
      expect(
        (
          await c.callTool({
            name: 'query_samples',
            arguments: { ...args, limit: 2001 },
          })
        ).isError,
      ).toBe(true);
    } finally {
      await c.close();
    }
  });
});
describe('time and sleep boundaries', () => {
  it('uses exclusive end and rejects invalid dates', () => {
    expect(time('2026-11-03', 480)).toBe(Date.parse('2026-11-02T16:00:00Z'));
    for (const s of ['2026-02-30', '2026-01-01T12:00:00', 'nonsense'])
      expect(() => time(s, 0)).toThrow();
    expect(() => range('2026-11-03', '2026-11-03', 0)).toThrow();
  });
  it('selects staged source and unions overlapping duplicates', () => {
    const start = Date.parse('2026-11-02T22:00:00Z');
    const rows = [
      sample({
        type: 'sleep',
        unit: null,
        tz_min: 0,
        start_ms: start,
        end_ms: start + 8 * 3600000,
        value: 1,
        source: 'Phone',
      }),
      ...Array.from({ length: 2 }, () =>
        sample({
          type: 'sleep',
          unit: null,
          tz_min: 0,
          start_ms: start,
          end_ms: start + 3600000,
          value: 3,
          source: 'Watch',
        }),
      ),
    ];
    const r = summarizeSleep(rows as never, '2026-11-03', '2026-11-04');
    expect(r[0]?.source).toBe('Watch');
    expect(r[0]?.total_sleep_minutes).toBe(60);
  });
});

describe('timezone and transport edge cases', () => {
  it('uses each type latest sample timezone and inclusive start/exclusive end', async () => {
    const t = Date.parse('2026-11-03T00:00:00Z');
    await upload([
      sample({ start_ms: t, end_ms: t, tz_min: -300 }),
      sample({
        type: 'steps',
        unit: 'count',
        start_ms: t + 1,
        end_ms: t + 1,
        tz_min: 480,
      }),
    ]);
    const state = await (await fetcher('/v1/status')).json<Status>();
    expect(
      state.types.find((t) => t.type === 'heart_rate')?.last_sample?.tz_min,
    ).toBe(-300);
    expect(
      state.types.find((t) => t.type === 'steps')?.last_sample?.tz_min,
    ).toBe(480);
    const c = await client();
    try {
      const r = textResult(
        await c.callTool({
          name: 'query_samples',
          arguments: {
            type: 'heart_rate',
            from: '2026-11-02T00:00:00Z',
            to: '2026-11-03T00:00:00Z',
          },
        }),
      );
      expect(r.samples).toHaveLength(0);
      const b = textResult(
        await c.callTool({
          name: 'aggregate',
          arguments: {
            type: 'heart_rate',
            from: '2026-11-03T00:00:00Z',
            to: '2026-11-04T00:00:00Z',
            bucket: 'day',
          },
        }),
      );
      expect(b.buckets[0].local_bucket).toBe('2026-11-02T00:00:00');
    } finally {
      await c.close();
    }
  });
  it('rejects malformed JSON and wrong content type without writing', async () => {
    const r = await exports.default.fetch('https://example.test/v1/ingest', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${writer}`,
        'Content-Type': 'application/json',
      },
      body: '{broken',
    });
    expect(r.status).toBe(400);
    const text = await exports.default.fetch('https://example.test/v1/ingest', {
      method: 'POST',
      headers: { Authorization: `Bearer ${writer}` },
      body: '{}',
    });
    expect(text.status).toBe(415);
  });
  it('handles sleep at the 18:00 boundary and unstaged source selection', () => {
    const start = Date.parse('2026-11-03T16:00:00Z');
    const data = [
      sample({
        type: 'sleep',
        unit: null,
        tz_min: 0,
        start_ms: start,
        end_ms: start + 2 * 3600000,
        value: 1,
        source: 'Long',
      }),
      sample({
        type: 'sleep',
        unit: null,
        tz_min: 0,
        start_ms: start + 3600000,
        end_ms: start + 2 * 3600000,
        value: 1,
        source: 'Short',
      }),
    ];
    expect(summarizeSleep(data as never, '2026-11-03', '2026-11-04')).toEqual(
      [],
    );
    const next = summarizeSleep(data as never, '2026-11-04', '2026-11-05');
    expect(next[0]?.source).toBe('Long');
    expect(next[0]?.total_sleep_minutes).toBe(120);
  });
});

describe('first-install pairing', () => {
  const password = 'synthetic-connection-password-test-only';
  async function create() {
    return fetcher('/v1/pairing/create', 'POST', '', { password });
  }
  async function ticket() {
    const r = await create();
    expect(r.status).toBe(200);
    const data = await r.json<{ link: string; qr: string }>();
    const payload = JSON.parse(
      atob(data.link.split('#')[1]!.replaceAll('-', '+').replaceAll('_', '/')),
    );
    return { data, code: payload.code as string };
  }
  const claimant = 'b'.repeat(64);
  it('serves a non-sensitive setup page with strict browser protections', async () => {
    const r = await fetcher('/', 'GET', '');
    expect(r.status).toBe(200);
    expect(r.headers.get('cache-control')).toBe('no-store');
    expect(r.headers.get('content-security-policy')).toContain(
      "frame-ancestors 'none'",
    );
    const html = await r.text();
    expect(html).not.toContain(password);
    expect(html).not.toContain(writer);
    expect(html).not.toContain(reader);
  });
  it('requires the deployment password, not either long-lived token', async () => {
    for (const value of ['wrong', reader, writer])
      expect(
        (await fetcher('/v1/pairing/create', 'POST', '', { password: value }))
          .status,
      ).toBe(401);
  });
  it('exchanges a short-lived link exactly once, supports same-client retry and closes bootstrap', async () => {
    const { data, code } = await ticket();
    expect(data.qr).toContain('<svg');
    expect(data.link).not.toContain(writer);
    expect(data.link).not.toContain(reader);
    const redeem = () =>
      fetcher('/v1/pairing/redeem', 'POST', '', { code, claimant });
    const response = await redeem();
    expect(response.status).toBe(200);
    const body = await response.json<{
      ingest_token: string;
      mcp_token: string;
    }>();
    expect(body.ingest_token).toBe(writer);
    expect(body.mcp_token).toBe(reader);
    expect((await redeem()).status).toBe(200);
    expect(
      (
        await fetcher('/v1/pairing/redeem', 'POST', '', {
          code,
          claimant: 'c'.repeat(64),
        })
      ).status,
    ).toBe(410);
    expect((await create()).status).toBe(409);
  });
  it('only one concurrent device wins', async () => {
    const { code } = await ticket();
    const results = await Promise.all(
      ['c', 'd'].map((x) =>
        fetcher('/v1/pairing/redeem', 'POST', '', {
          code,
          claimant: x.repeat(64),
        }),
      ),
    );
    expect(results.map((r) => r.status).sort()).toEqual([200, 410]);
  });
  it('expires tickets, replaces unclaimed links, and does not reset owner when deleting health data', async () => {
    const old = await ticket();
    const fresh = await ticket();
    expect(
      (
        await fetcher('/v1/pairing/redeem', 'POST', '', {
          code: old.code,
          claimant,
        })
      ).status,
    ).toBe(410);
    await env.DB.prepare('UPDATE pairing_tickets SET expires_ms=0').run();
    expect(
      (
        await fetcher('/v1/pairing/redeem', 'POST', '', {
          code: fresh.code,
          claimant,
        })
      ).status,
    ).toBe(410);
    const current = await ticket();
    expect(
      (
        await fetcher('/v1/pairing/redeem', 'POST', '', {
          code: current.code,
          claimant,
        })
      ).status,
    ).toBe(200);
    await fetcher('/v1/data', 'DELETE');
    expect((await create()).status).toBe(409);
  });
  it('limits password guessing and rejects cross-origin browser requests', async () => {
    for (let i = 0; i < 10; i++)
      await fetcher('/v1/pairing/create', 'POST', '', { password: 'wrong' });
    expect((await create()).status).toBe(429);
    const r = await exports.default.fetch(
      'https://example.test/v1/pairing/create',
      {
        method: 'POST',
        headers: {
          Origin: 'https://foreign.test',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ password }),
      },
    );
    expect(r.status).toBe(403);
  });
});

describe('hourly replacement contract', () => {
  const start = Date.parse('2026-11-03T00:00:00Z');
  const hour = (patch = {}) => ({
    type: 'heart_rate',
    start_ms: start,
    end_ms: start + 3600000,
    tz_min: 480,
    sum: 120,
    count: 2,
    min: 50,
    max: 70,
    ...patch,
  });
  const replace = (
    hourly: unknown[],
    hourly_ranges = [
      { type: 'heart_rate', start_ms: start, end_ms: start + 7200000 },
    ],
  ) =>
    fetcher('/v1/ingest', 'POST', writer, {
      schema_version: 1,
      added: [],
      deleted: [],
      hourly,
      hourly_ranges,
    });
  it('retries atomically, excludes preserved raw, weights daily averages and removes empty hours', async () => {
    await upload([sample({ start_ms: start, end_ms: start, value: 999 })]);
    const hours = [
      hour(),
      hour({
        start_ms: start + 3600000,
        end_ms: start + 7200000,
        sum: 90,
        count: 1,
        min: 90,
        max: 90,
      }),
    ];
    expect((await replace(hours)).status).toBe(200);
    expect(await (await replace(hours)).json()).toMatchObject({
      hourly: 2,
      hourly_ranges: 1,
    });
    expect(
      await env.DB.prepare('SELECT COUNT(*) n FROM samples').first('n'),
    ).toBe(1);
    const c = await client();
    try {
      const args = {
        type: 'heart_rate',
        from: '2026-11-03T00:00:00Z',
        to: '2026-11-04T00:00:00Z',
        bucket: 'day',
      };
      const r = textResult(
        await c.callTool({ name: 'aggregate', arguments: args }),
      );
      expect(r.buckets[0]).toMatchObject({
        avg: 70,
        sum: 210,
        count: 3,
        min: 50,
        max: 90,
      });
      await replace([]);
      expect(
        textResult(await c.callTool({ name: 'aggregate', arguments: args }))
          .buckets,
      ).toEqual([]);
      expect((await status(env.DB)).counts.heart_rate).toBe(0);
      await fetcher('/v1/data?type=heart_rate', 'DELETE');
      expect(
        await env.DB.prepare('SELECT COUNT(*) n FROM hourly_ranges').first('n'),
      ).toBe(0);
    } finally {
      await c.close();
    }
  });
  it('rejects duplicate, uncovered, nonhourly and inconsistent statistics without replacing', async () => {
    await replace([hour()]);
    for (const rows of [
      [hour(), hour()],
      [hour({ start_ms: start + 1 })],
      [hour({ count: 0 })],
      [hour({ min: 100 })],
      [hour({ start_ms: start - 3600000, end_ms: start })],
    ]) {
      expect((await replace(rows)).status).toBe(400);
      expect(
        await env.DB.prepare('SELECT COUNT(*) n FROM hourly').first('n'),
      ).toBe(1);
    }
  });
  it('rejects partial-hour bounds and fractional-offset local buckets; keeps DST offsets separate', async () => {
    await replace([hour({ tz_min: 330 })]);
    const c = await client();
    const args = {
      type: 'heart_rate',
      from: '2026-11-03T00:00:00Z',
      to: '2026-11-03T02:00:00Z',
      bucket: 'day',
    };
    try {
      expect(
        (await c.callTool({ name: 'aggregate', arguments: args })).isError,
      ).toBe(true);
      await replace([hour()]);
      expect(
        (
          await c.callTool({
            name: 'aggregate',
            arguments: { ...args, from: '2026-11-03T00:30:00Z' },
          })
        ).isError,
      ).toBe(true);
      await replace([
        hour({ tz_min: -240 }),
        hour({
          start_ms: start + 3600000,
          end_ms: start + 7200000,
          tz_min: -300,
        }),
      ]);
      const r = textResult(
        await c.callTool({
          name: 'aggregate',
          arguments: { ...args, bucket: 'hour' },
        }),
      );
      expect(r.buckets.map((b: { tz_min: number }) => b.tz_min)).toEqual([
        -300, -240,
      ]);
      expect(r.buckets).toHaveLength(2);
    } finally {
      await c.close();
    }
  });
  it('stores a sharing cutoff, advertises support and refuses to invent a full hour', async () => {
    const cutoff = start + 123456;
    expect(
      (
        await (
          await fetcher('/v1/ping')
        ).json<{ hourly_schema_version: number }>()
      ).hourly_schema_version,
    ).toBe(1);
    expect((await replace([hour({ coverage_start_ms: cutoff })])).status).toBe(
      200,
    );
    expect(
      await env.DB.prepare('SELECT coverage_start_ms FROM hourly').first(
        'coverage_start_ms',
      ),
    ).toBe(cutoff);
    const c = await client();
    try {
      const r = await c.callTool({
        name: 'aggregate',
        arguments: {
          type: 'heart_rate',
          from: '2026-11-03T00:00:00Z',
          to: '2026-11-03T01:00:00Z',
          bucket: 'hour',
        },
      });
      expect(r.isError).toBe(true);
      expect(textResult(r).error).toContain('sharing/deletion cutoff');
    } finally {
      await c.close();
    }
    for (const coverage_start_ms of [start - 1, start + 3600000])
      expect((await replace([hour({ coverage_start_ms })])).status).toBe(400);
  });
  it('rolls back deletion and coverage when hourly insertion fails', async () => {
    await replace([hour()]);
    await env.DB.exec(
      "CREATE TRIGGER fail_hour BEFORE INSERT ON hourly WHEN NEW.sum=999 BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;",
    );
    try {
      expect(
        (await replace([hour({ sum: 999, count: 1, min: 999, max: 999 })]))
          .status,
      ).toBe(503);
      expect(await env.DB.prepare('SELECT sum FROM hourly').first('sum')).toBe(
        120,
      );
    } finally {
      await env.DB.exec('DROP TRIGGER fail_hour');
    }
  });
});
