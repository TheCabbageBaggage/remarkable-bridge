-- 001_core.sql — remarkable-bridge database: instance-level foundation
-- Schema-per-domain: this file owns `core`, remarkable content owns `remarkable`,
-- later domains add their own schema (mail, finance, health, ...).
-- Embedding dimension is fixed at 1024 to match ollama mxbai-embed-large.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS core;

-- Registry of content sources feeding this database.
CREATE TABLE IF NOT EXISTS core.source (
    id          text        PRIMARY KEY,
    kind        text        NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO core.source (id, kind, description) VALUES
    ('remarkable', 'device',           'Handschriftliche Notizbuecher vom reMarkable 2 (Cloud-Sync, rmapi)'),
    ('paperless',  'document-store',   'Paperless-ngx Bestand (1044 Dokumente, eigener sqlite-vec Index)')
ON CONFLICT (id) DO NOTHING;

-- Pipeline run log, shared by every pipeline that writes into this database.
CREATE TABLE IF NOT EXISTS core.ingest_run (
    id          bigserial   PRIMARY KEY,
    source      text        NOT NULL REFERENCES core.source (id),
    stage       text        NOT NULL,
    status      text        NOT NULL CHECK (status IN ('started','ok','failed','skipped')),
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    detail      text
);

CREATE INDEX IF NOT EXISTS ingest_run_source_started_idx
    ON core.ingest_run (source, started_at DESC);

CREATE OR REPLACE FUNCTION core.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
