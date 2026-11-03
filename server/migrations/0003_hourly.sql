CREATE TABLE hourly (
  type TEXT NOT NULL CHECK (type IN ('steps','heart_rate')),
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL CHECK (end_ms = start_ms + 3600000),
  tz_min INTEGER NOT NULL,
  coverage_start_ms INTEGER NOT NULL,
  sum REAL NOT NULL,
  count INTEGER NOT NULL CHECK (count > 0),
  min REAL NOT NULL,
  max REAL NOT NULL,
  PRIMARY KEY (type, start_ms)
);
CREATE TABLE hourly_ranges (
  type TEXT NOT NULL CHECK (type IN ('steps','heart_rate')),
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL CHECK (end_ms > start_ms),
  PRIMARY KEY (type, start_ms, end_ms)
);
CREATE VIEW effective_statistics AS
SELECT type, start_ms, end_ms, tz_min, value AS sum, 1 AS count, value AS min, value AS max
FROM samples s WHERE NOT EXISTS (
 SELECT 1 FROM hourly_ranges r WHERE r.type=s.type AND s.start_ms>=r.start_ms AND s.start_ms<r.end_ms
)
UNION ALL SELECT type, start_ms, end_ms, tz_min, sum, count, min, max FROM hourly;
