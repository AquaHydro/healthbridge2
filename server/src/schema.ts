import { z } from 'zod';

export const types = [
  'sleep',
  'heart_rate',
  'resting_hr',
  'hrv',
  'steps',
] as const;
export const typeSchema = z.enum(types);
export type SampleType = z.infer<typeof typeSchema>;
const timestamp = z.number().int().min(0).max(253402214400000);
export const sampleSchema = z
  .object({
    uuid: z.uuid(),
    type: typeSchema,
    start_ms: timestamp,
    end_ms: timestamp,
    tz_min: z.number().int().min(-720).max(840),
    value: z.number().finite().nonnegative().max(Number.MAX_SAFE_INTEGER),
    unit: z.enum(['bpm', 'ms', 'count']).nullable(),
    source: z.string().max(200).nullable().optional(),
    device: z.string().max(100).nullable().optional(),
  })
  .strict()
  .superRefine((s, ctx) => {
    if (s.end_ms < s.start_ms)
      ctx.addIssue({
        code: 'custom',
        message: 'end_ms must not precede start_ms',
      });
    const units = {
      sleep: null,
      heart_rate: 'bpm',
      resting_hr: 'bpm',
      hrv: 'ms',
      steps: 'count',
    };
    if (s.unit !== units[s.type])
      ctx.addIssue({ code: 'custom', message: 'unit does not match type' });
    if (s.type === 'sleep' && (!Number.isInteger(s.value) || s.value > 5))
      ctx.addIssue({ code: 'custom', message: 'invalid sleep stage' });
    if (s.type === 'steps' && !Number.isSafeInteger(s.value))
      ctx.addIssue({ code: 'custom', message: 'steps must be a safe integer' });
  });
const hourlyType = z.enum(['steps', 'heart_rate']);
const hourTime = timestamp.refine(
  (n) => n % 3600000 === 0,
  'Use UTC hour boundaries',
);
const statistic = z
  .number()
  .finite()
  .nonnegative()
  .max(Number.MAX_SAFE_INTEGER);
export const hourlySchema = z
  .object({
    type: hourlyType,
    start_ms: hourTime,
    end_ms: hourTime,
    tz_min: z.number().int().min(-720).max(840),
    coverage_start_ms: timestamp.optional(),
    sum: statistic,
    count: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
    min: statistic,
    max: statistic,
  })
  .strict()
  .superRefine((h, ctx) => {
    if (
      (h.coverage_start_ms !== undefined &&
        (h.coverage_start_ms < h.start_ms ||
          h.coverage_start_ms >= h.end_ms)) ||
      h.end_ms !== h.start_ms + 3600000 ||
      h.min > h.max ||
      h.sum / h.count < h.min - 1e-8 ||
      h.sum / h.count > h.max + 1e-8 ||
      (h.type === 'steps' &&
        (h.count !== 1 || h.min !== h.sum || h.max !== h.sum))
    )
      ctx.addIssue({ code: 'custom', message: 'Invalid hourly statistics' });
  });
export const hourlyRangeSchema = z
  .object({
    type: hourlyType,
    start_ms: hourTime,
    end_ms: hourTime,
  })
  .strict()
  .refine((r) => r.end_ms > r.start_ms, 'Invalid replacement range');
export type Hourly = z.infer<typeof hourlySchema>;
export type HourlyRange = z.infer<typeof hourlyRangeSchema>;
export const ingestSchema = z
  .object({
    schema_version: z.literal(1),
    added: z.array(sampleSchema).max(1000),
    deleted: z.array(z.uuid()).max(5000),
    types: z.array(typeSchema).max(5).optional(),
    hourly: z.array(hourlySchema).max(1000).default([]),
    hourly_ranges: z.array(hourlyRangeSchema).max(1000).default([]),
  })
  .strict()
  .superRefine((batch, ctx) => {
    const keys = new Set<string>();
    for (const h of batch.hourly) {
      const key = `${h.type}:${h.start_ms}`;
      if (
        keys.has(key) ||
        !batch.hourly_ranges.some(
          (r) =>
            r.type === h.type &&
            r.start_ms <= h.start_ms &&
            r.end_ms >= h.end_ms,
        )
      )
        ctx.addIssue({
          code: 'custom',
          message: 'Duplicate or uncovered hour',
          path: ['hourly'],
        });
      keys.add(key);
    }
    for (const s of batch.added) {
      if (
        batch.hourly_ranges.some(
          (r) =>
            r.type === s.type &&
            s.start_ms >= r.start_ms &&
            s.start_ms < r.end_ms,
        )
      )
        ctx.addIssue({
          code: 'custom',
          message: 'Raw sample conflicts with hourly replacement',
          path: ['added'],
        });
    }
  });
export type Sample = z.infer<typeof sampleSchema>;
export class InputError extends Error {}

export function time(value: string, tz: number): number {
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const ms = Date.parse(`${value}T00:00:00Z`);
    if (
      !Number.isFinite(ms) ||
      new Date(ms).toISOString().slice(0, 10) !== value
    )
      throw new InputError('Invalid date');
    return ms - tz * 60000;
  }
  if (
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value,
    )
  )
    throw new InputError('Use ISO 8601 with timezone or YYYY-MM-DD');
  const ms = Date.parse(value);
  const date = value.slice(0, 10);
  if (
    !Number.isFinite(ms) ||
    new Date(Date.parse(`${date}T00:00:00Z`)).toISOString().slice(0, 10) !==
      date
  )
    throw new InputError('Invalid timestamp');
  return ms;
}
export function range(from: string, to: string, tz: number) {
  const start = time(from, tz),
    end = time(to, tz);
  if (start >= end)
    throw new InputError('from must precede to; end is exclusive');
  return { start, end };
}
export function times(ms: number | null, tz: number) {
  if (ms === null) return null;
  const sign = tz < 0 ? '-' : '+';
  const offset = `${sign}${String(Math.floor(Math.abs(tz) / 60)).padStart(2, '0')}:${String(Math.abs(tz) % 60).padStart(2, '0')}`;
  return {
    utc: new Date(ms).toISOString(),
    local: new Date(ms + tz * 60000).toISOString().replace('Z', offset),
    tz_min: tz,
  };
}
