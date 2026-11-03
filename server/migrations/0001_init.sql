CREATE TABLE samples (
  uuid TEXT PRIMARY KEY,
  type TEXT NOT NULL CHECK (type IN ('sleep','heart_rate','resting_hr','hrv','steps')),
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL CHECK (end_ms >= start_ms),
  tz_min INTEGER NOT NULL,
  value REAL NOT NULL,
  unit TEXT,
  source TEXT,
  device TEXT
);
CREATE INDEX idx_samples_type_start ON samples(type, start_ms);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
