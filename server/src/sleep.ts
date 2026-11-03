import { type Sample, times } from './schema';

function unionMinutes(samples: Sample[]) {
  const intervals = samples
    .map((s) => [s.start_ms, s.end_ms] as const)
    .sort((a, b) => a[0] - b[0]);
  let end = -Infinity,
    length = 0;
  for (const [start, stop] of intervals) {
    length += Math.max(0, stop - Math.max(start, end));
    end = Math.max(end, stop);
  }
  return length / 60000;
}
export function summarizeSleep(samples: Sample[], from: string, to: string) {
  const nights = new Map<string, Map<string, Sample[]>>();
  for (const s of samples) {
    const date = new Date(s.end_ms + s.tz_min * 60000 + 6 * 3600000)
      .toISOString()
      .slice(0, 10);
    if (date < from || date >= to) continue;
    const sources = nights.get(date) ?? new Map<string, Sample[]>();
    nights.set(date, sources);
    const key = JSON.stringify([s.source ?? 'Unknown', s.device ?? null]);
    sources.set(key, [...(sources.get(key) ?? []), s]);
  }
  return [...nights]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, sources]) => {
      const ranked = [...sources.entries()].sort(([ak, a], [bk, b]) => {
        const stagesA = a.filter((s) => s.value >= 3).length,
          stagesB = b.filter((s) => s.value >= 3).length;
        return (
          stagesB - stagesA ||
          unionMinutes(b.filter((s) => s.value === 1 || s.value >= 3)) -
            unionMinutes(a.filter((s) => s.value === 1 || s.value >= 3)) ||
          ak.localeCompare(bk)
        );
      });
      const chosen = ranked[0]![1];
      const asleep = chosen.filter((s) => s.value === 1 || s.value >= 3);
      const first = asleep.reduce<Sample | undefined>(
        (a, s) => (!a || s.start_ms < a.start_ms ? s : a),
        undefined,
      );
      const last = asleep.reduce<Sample | undefined>(
        (a, s) => (!a || s.end_ms > a.end_ms ? s : a),
        undefined,
      );
      return {
        date,
        source: chosen[0]!.source ?? 'Unknown',
        device: chosen[0]!.device ?? null,
        asleep: first ? times(first.start_ms, first.tz_min) : null,
        awake: last ? times(last.end_ms, last.tz_min) : null,
        total_sleep_minutes: unionMinutes(asleep),
        stages_minutes: Object.fromEntries(
          ['in_bed', 'unspecified', 'awake', 'core', 'deep', 'rem'].map(
            (name, value) => [
              name,
              unionMinutes(chosen.filter((s) => s.value === value)),
            ],
          ),
        ),
        note: 'One source/device per night; interval unions remove overlapping duplicates. Stage totals may overlap if source stages conflict.',
      };
    });
}
