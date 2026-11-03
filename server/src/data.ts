import { type Hourly, type HourlyRange } from './schema';
import { type Sample, type SampleType, types, times } from './schema';

export async function ingest(
  db: D1Database,
  added: Sample[],
  deleted: string[],
  syncedTypes: SampleType[] = [],
  hourly: Hourly[] = [],
  hourlyRanges: HourlyRange[] = [],
) {
  const now = new Date().toISOString();
  // JSON table operations keep large batches within D1's per-invocation statement budget.
  const statements = [
    db
      .prepare(
        `INSERT OR REPLACE INTO samples
    SELECT lower(json_extract(value,'$.uuid')), json_extract(value,'$.type'), json_extract(value,'$.start_ms'),
    json_extract(value,'$.end_ms'), json_extract(value,'$.tz_min'), json_extract(value,'$.value'),
    json_extract(value,'$.unit'), json_extract(value,'$.source'), json_extract(value,'$.device') FROM json_each(?)`,
      )
      .bind(JSON.stringify(added)),
    db
      .prepare(
        'DELETE FROM samples WHERE uuid IN (SELECT lower(value) FROM json_each(?))',
      )
      .bind(JSON.stringify(deleted)),
    db
      .prepare("INSERT OR REPLACE INTO meta VALUES ('last_ingest_at', ?)")
      .bind(now),
  ];
  statements.push(
    db
      .prepare(
        `DELETE FROM hourly WHERE EXISTS (SELECT 1 FROM json_each(?) r WHERE hourly.type=json_extract(r.value,'$.type') AND hourly.start_ms>=json_extract(r.value,'$.start_ms') AND hourly.start_ms<json_extract(r.value,'$.end_ms'))`,
      )
      .bind(JSON.stringify(hourlyRanges)),
    db
      .prepare(
        `INSERT OR IGNORE INTO hourly_ranges SELECT json_extract(value,'$.type'),json_extract(value,'$.start_ms'),json_extract(value,'$.end_ms') FROM json_each(?)`,
      )
      .bind(JSON.stringify(hourlyRanges)),
    db
      .prepare(
        `INSERT OR REPLACE INTO hourly SELECT json_extract(value,'$.type'),json_extract(value,'$.start_ms'),json_extract(value,'$.end_ms'),json_extract(value,'$.tz_min'),coalesce(json_extract(value,'$.coverage_start_ms'),json_extract(value,'$.start_ms')),json_extract(value,'$.sum'),json_extract(value,'$.count'),json_extract(value,'$.min'),json_extract(value,'$.max') FROM json_each(?)`,
      )
      .bind(JSON.stringify(hourly)),
  );
  const touched = new Set([
    ...added.map((s) => s.type),
    ...syncedTypes,
    ...hourlyRanges.map((r) => r.type),
  ]);
  for (const type of touched)
    statements.push(
      db
        .prepare('INSERT OR REPLACE INTO meta VALUES (?, ?)')
        .bind(`last_ingest_at.${type}`, now),
    );
  await db.batch(statements);
}
export async function status(db: D1Database) {
  const [rows, meta] = await db.batch<Record<string, string | number | null>>([
    db.prepare(
      `SELECT s.type, COUNT(*) AS count, MAX(s.end_ms) AS last_sample_ms,
       (SELECT COUNT(*) FROM hourly h WHERE h.type=s.type) AS hourly_count,
       (SELECT tz_min FROM effective_statistics latest WHERE latest.type=s.type ORDER BY latest.end_ms DESC, latest.start_ms LIMIT 1) AS tz_min
       FROM effective_statistics s GROUP BY s.type`,
    ),
    db.prepare('SELECT key,value FROM meta'),
  ]);
  const metadata = Object.fromEntries(
    (meta!.results as { key: string; value: string }[]).map((r) => [
      r.key,
      r.value,
    ]),
  );
  const result = types.map((type) => {
    const row = rows!.results.find((r) => r.type === type);
    return {
      type,
      count: Number(row?.count ?? 0),
      hourly_count: Number(row?.hourly_count ?? 0),
      count_unit: 'stored_records',
      last_sample: times(
        row ? Number(row.last_sample_ms) : null,
        Number(row?.tz_min ?? 0),
      ),
      last_ingest_at: metadata[`last_ingest_at.${type}`] ?? null,
    };
  });
  return {
    schema_version: 1,
    hourly_schema_version: 1,
    version: '0.1.0',
    last_ingest_at: metadata.last_ingest_at ?? null,
    types: result,
    counts: Object.fromEntries(result.map((r) => [r.type, r.count])),
  };
}
export async function timezone(db: D1Database, specified?: number) {
  if (specified !== undefined) return specified;
  const row = await db
    .prepare(
      'SELECT tz_min FROM effective_statistics ORDER BY end_ms DESC, start_ms LIMIT 1',
    )
    .first<{ tz_min: number }>();
  return row?.tz_min ?? 0;
}
export async function clear(db: D1Database, type?: SampleType) {
  if (type)
    await db.batch([
      db.prepare('DELETE FROM samples WHERE type = ?').bind(type),
      db.prepare('DELETE FROM hourly WHERE type = ?').bind(type),
      db.prepare('DELETE FROM hourly_ranges WHERE type = ?').bind(type),
      db
        .prepare('DELETE FROM meta WHERE key = ?')
        .bind(`last_ingest_at.${type}`),
    ]);
  else
    await db.batch([
      db.prepare('DELETE FROM samples'),
      db.prepare('DELETE FROM hourly'),
      db.prepare('DELETE FROM hourly_ranges'),
      db.prepare('DELETE FROM meta'),
    ]);
}
