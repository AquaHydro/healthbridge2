CREATE TABLE pairing_tickets (
  code_hash TEXT PRIMARY KEY,
  owner_hash TEXT NOT NULL,
  expires_ms INTEGER NOT NULL,
  claimant_hash TEXT,
  redeemed_ms INTEGER
);
CREATE TABLE pairing_owners (
  owner_hash TEXT PRIMARY KEY,
  claimed_ms INTEGER NOT NULL
);
CREATE TABLE pairing_attempts (
  bucket TEXT PRIMARY KEY,
  attempts INTEGER NOT NULL,
  expires_ms INTEGER NOT NULL
);
