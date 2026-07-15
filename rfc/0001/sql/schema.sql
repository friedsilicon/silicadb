-- silica v0 physical layout (SPEC.md §1)
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA application_id = 0x51CA0001;
PRAGMA user_version = 1;

CREATE TABLE type_defs (
  name TEXT PRIMARY KEY,
  parent TEXT REFERENCES type_defs(name),
  sodl_version INTEGER NOT NULL
);

CREATE TABLE schema_defs (
  version INTEGER PRIMARY KEY,
  sodl_source TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE sources (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('session','user','tool','import')),
  ref TEXT,
  occurred_at INTEGER NOT NULL
);

CREATE TABLE entities (
  id INTEGER PRIMARY KEY,
  type TEXT NOT NULL REFERENCES type_defs(name),
  name TEXT,
  created_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE UNIQUE INDEX entities_type_name ON entities(type, name) WHERE name IS NOT NULL;

CREATE TABLE facts (
  id INTEGER PRIMARY KEY,
  entity_id INTEGER NOT NULL REFERENCES entities(id),
  predicate TEXT NOT NULL,
  object_entity_id INTEGER REFERENCES entities(id),
  value TEXT,
  source_id INTEGER NOT NULL REFERENCES sources(id),
  confidence REAL DEFAULT 1.0,
  asserted_at INTEGER NOT NULL,
  invalidated_at INTEGER,
  invalidated_by INTEGER REFERENCES facts(id),
  CHECK ((object_entity_id IS NULL) != (value IS NULL))
);
CREATE INDEX facts_entity ON facts(entity_id) WHERE invalidated_at IS NULL;

CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,
  actor TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL
);

CREATE VIRTUAL TABLE facts_fts USING fts5(
  entity_name, predicate, value, content='', contentless_delete=1
);

CREATE TRIGGER facts_ai AFTER INSERT ON facts BEGIN
  INSERT INTO facts_fts(rowid, entity_name, predicate, value)
  SELECT new.id, coalesce(e.name,''), new.predicate, coalesce(new.value,'')
  FROM entities e WHERE e.id = new.entity_id;
END;

CREATE TRIGGER facts_invalidate AFTER UPDATE OF invalidated_at ON facts
WHEN new.invalidated_at IS NOT NULL BEGIN
  DELETE FROM facts_fts WHERE rowid = new.id;
END;

-- starter ontology (SPEC.md §3, chat 2026-07-03)
INSERT INTO type_defs(name, parent, sodl_version) VALUES
  ('entity',     NULL,     1),
  ('decision',   'entity', 1),
  ('preference', 'entity', 1),
  ('lesson',     'entity', 1),
  ('procedure',  'entity', 1);
