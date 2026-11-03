import { runtimeTokens } from './credentials';
import QRCode from 'qrcode';
import { z } from 'zod';
import { status } from './data';

const secret = z.string().regex(/^[a-f0-9]{64}$/);
export const pairingCreateSchema = z
  .object({ password: z.string().min(1).max(256) })
  .strict();
export const pairingRedeemSchema = z
  .object({ code: secret, claimant: secret })
  .strict();
export const pairingHeaders = {
  'Cache-Control': 'no-store',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
};
const reply = (data: unknown, code = 200) =>
  Response.json(data, { status: code, headers: pairingHeaders });
export async function hash(value: string) {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)),
    ),
    (x) => x.toString(16).padStart(2, '0'),
  ).join('');
}
const random = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(32)), (x) =>
    x.toString(16).padStart(2, '0'),
  ).join('');
export async function same(a: string, b: string) {
  return crypto.subtle.timingSafeEqual(
    new TextEncoder().encode(await hash(a)),
    new TextEncoder().encode(await hash(b)),
  );
}
async function admitted(db: D1Database, ip: string) {
  const now = Date.now(),
    window = Math.floor(now / 60000),
    ipKey = await hash(ip);
  const entries = [`global:${window}`, `${ipKey}:${window}`];
  const results = await db.batch<{ attempts: number }>([
    db.prepare('DELETE FROM pairing_attempts WHERE expires_ms < ?').bind(now),
    ...entries.map((key) =>
      db
        .prepare(
          'INSERT INTO pairing_attempts VALUES (?,1,?) ON CONFLICT(bucket) DO UPDATE SET attempts=attempts+1 RETURNING attempts',
        )
        .bind(key, now + 120000),
    ),
  ]);
  return Number(results[1]?.results[0]?.attempts ?? 999) > 120 ||
    Number(results[2]?.results[0]?.attempts ?? 999) > 10
    ? false
    : true;
}
export async function createTicket(
  env: Env,
  origin: string,
  password: string,
  ip: string,
) {
  if (!env.CONNECT_PASSWORD || env.CONNECT_PASSWORD.length < 16)
    return reply({ error: 'setup_unavailable' }, 503);
  if (!(await admitted(env.DB, ip))) return reply({ error: 'try_later' }, 429);
  if (!(await same(password, env.CONNECT_PASSWORD)))
    return reply({ error: 'invalid_password' }, 401);
  const owner = await hash(env.CONNECT_PASSWORD);
  if (
    await env.DB.prepare('SELECT 1 FROM pairing_owners WHERE owner_hash=?')
      .bind(owner)
      .first()
  )
    return reply({ error: 'setup_completed' }, 409);
  const code = random(),
    expires = Date.now() + 5 * 60000;
  const inserted = await env.DB.batch([
    env.DB.prepare(
      'DELETE FROM pairing_tickets WHERE expires_ms < ? OR (owner_hash=? AND claimant_hash IS NULL)',
    ).bind(Date.now(), owner),
    env.DB.prepare(
      'INSERT INTO pairing_tickets(code_hash,owner_hash,expires_ms) SELECT ?,?,? WHERE NOT EXISTS(SELECT 1 FROM pairing_owners WHERE owner_hash=?)',
    ).bind(await hash(code), owner, expires, owner),
  ]);
  if (inserted[1]?.meta.changes !== 1)
    return reply({ error: 'setup_completed' }, 409);
  const payload = btoa(JSON.stringify({ v: 1, server: origin, code }))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');
  const link = `healthbridge://connect#${payload}`;
  // Render only our generated URL, never arbitrary SVG or user-provided markup.
  const qr = await QRCode.toString(link, {
    type: 'svg',
    errorCorrectionLevel: 'M',
    margin: 4,
    width: 300,
  });
  return reply({ ok: true, link, qr, expires_at: expires });
}
export async function redeemTicket(
  env: Env,
  code: string,
  claimant: string,
  ip: string,
) {
  if (!(await admitted(env.DB, ip))) return reply({ error: 'try_later' }, 429);
  const codeHash = await hash(code),
    claimantHash = await hash(claimant),
    now = Date.now();
  const owner = env.CONNECT_PASSWORD ? await hash(env.CONNECT_PASSWORD) : '';
  // The owner claim and ticket claim are one D1 transaction. Exactly one claimant wins;
  // only that same claimant may retry a lost response during the ticket's lifetime.
  const result = await env.DB.batch([
    env.DB.prepare(
      `UPDATE pairing_tickets SET claimant_hash=?,redeemed_ms=?
      WHERE code_hash=? AND owner_hash=? AND expires_ms>? AND claimant_hash IS NULL
      AND NOT EXISTS(SELECT 1 FROM pairing_owners WHERE owner_hash=pairing_tickets.owner_hash)`,
    ).bind(claimantHash, now, codeHash, owner, now),
    env.DB.prepare(
      `INSERT OR IGNORE INTO pairing_owners SELECT owner_hash,redeemed_ms FROM pairing_tickets WHERE code_hash=? AND claimant_hash=? AND expires_ms>?`,
    ).bind(codeHash, claimantHash, now),
    env.DB.prepare(
      'SELECT 1 AS allowed FROM pairing_tickets WHERE code_hash=? AND owner_hash=? AND claimant_hash=? AND expires_ms>?',
    ).bind(codeHash, owner, claimantHash, now),
  ]);
  if (!result[2]?.results[0])
    return reply({ error: 'link_expired_or_used' }, 410);
  const tokens = runtimeTokens(env);
  if (!tokens) return reply({ error: 'setup_unavailable' }, 503);
  return reply({
    ok: true,
    ingest_token: tokens.ingest,
    mcp_token: tokens.mcp,
    status: { ok: true, ...(await status(env.DB)) },
  });
}
