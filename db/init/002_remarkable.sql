-- 002_remarkable.sql — reMarkable notebook domain
-- One row per notebook (identity = reMarkable document UUID, never the filename),
-- one row per page, chunk-level text + embedding for hybrid retrieval.

CREATE SCHEMA IF NOT EXISTS remarkable;

CREATE TABLE IF NOT EXISTS remarkable.notebook (
    id                   bigserial   PRIMARY KEY,
    remarkable_id        text        NOT NULL UNIQUE,
    visible_name         text        NOT NULL,
    remarkable_path      text,
    -- device-side creation date: drives the chronological order in Nextcloud and here
    captured_at          timestamptz NOT NULL,
    captured_date_source text        NOT NULL DEFAULT 'metadata'
        CHECK (captured_date_source IN ('metadata','cloud','filename')),
    cloud_modified_at    timestamptz,
    page_count           integer     CHECK (page_count >= 0),
    pdf_sha256           char(64),
    rm_archive_path      text,
    nc_pdf_path          text,
    nc_md_path           text,
    ocr_engine           text,
    ocr_model            text,
    ocr_confidence       numeric(4,3) CHECK (ocr_confidence BETWEEN 0 AND 1),
    status               text        NOT NULL DEFAULT 'new'
        CHECK (status IN ('new','rendered','extracted','published','indexed','failed','archived')),
    error                text,
    first_seen_at        timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notebook_captured_at_idx ON remarkable.notebook (captured_at DESC);
CREATE INDEX IF NOT EXISTS notebook_status_idx      ON remarkable.notebook (status);

DROP TRIGGER IF EXISTS notebook_touch ON remarkable.notebook;
CREATE TRIGGER notebook_touch BEFORE UPDATE ON remarkable.notebook
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();

CREATE TABLE IF NOT EXISTS remarkable.page (
    notebook_id    bigint      NOT NULL REFERENCES remarkable.notebook (id) ON DELETE CASCADE,
    page_no        integer     NOT NULL CHECK (page_no >= 1),
    -- paths are relative to the notebook folder so the Nextcloud tree can be relocated
    image_path     text,
    text           text,
    text_len       integer     GENERATED ALWAYS AS (length(coalesce(text,''))) STORED,
    ocr_confidence numeric(4,3) CHECK (ocr_confidence BETWEEN 0 AND 1),
    layer_count    integer,
    PRIMARY KEY (notebook_id, page_no)
);

CREATE TABLE IF NOT EXISTS remarkable.chunk (
    id          bigserial PRIMARY KEY,
    notebook_id bigint    NOT NULL,
    page_no     integer   NOT NULL,
    chunk_idx   integer   NOT NULL DEFAULT 0,
    text        text      NOT NULL,
    tsv         tsvector  GENERATED ALWAYS AS (to_tsvector('german', coalesce(text,''))) STORED,
    embedding   vector(1024),
    embedded_at timestamptz,
    UNIQUE (notebook_id, page_no, chunk_idx),
    FOREIGN KEY (notebook_id, page_no)
        REFERENCES remarkable.page (notebook_id, page_no) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS chunk_tsv_idx       ON remarkable.chunk USING gin (tsv);
CREATE INDEX IF NOT EXISTS chunk_trgm_idx      ON remarkable.chunk USING gin (text gin_trgm_ops);
CREATE INDEX IF NOT EXISTS chunk_embedding_idx ON remarkable.chunk
    USING hnsw (embedding vector_cosine_ops);

-- Hybrid retrieval: German full-text + cosine similarity, fused 50/50.
-- q may be empty when only an embedding is available (and vice versa).
CREATE OR REPLACE FUNCTION remarkable.search(
    q      text,
    q_emb  vector(1024) DEFAULT NULL,
    k      integer      DEFAULT 10
) RETURNS TABLE (
    notebook_id  bigint,
    visible_name text,
    page_no      integer,
    captured_at  timestamptz,
    score        real,
    snippet      text,
    nc_pdf_path  text
)
LANGUAGE sql STABLE AS $$
    WITH scored AS (
        SELECT c.notebook_id,
               c.page_no,
               c.text,
               CASE WHEN coalesce(q,'') <> ''
                    THEN ts_rank_cd(c.tsv, websearch_to_tsquery('german', q))
                    ELSE 0::real END AS fts_rank,
               CASE WHEN q_emb IS NOT NULL AND c.embedding IS NOT NULL
                    THEN (1 - (c.embedding <=> q_emb))::real
                    ELSE 0::real END AS vec_score
        FROM remarkable.chunk c
    )
    SELECT s.notebook_id,
           n.visible_name,
           s.page_no,
           n.captured_at,
           (0.5 * s.fts_rank + 0.5 * s.vec_score)::real AS score,
           left(s.text, 400) AS snippet,
           n.nc_pdf_path
    FROM scored s
    JOIN remarkable.notebook n ON n.id = s.notebook_id
    WHERE s.fts_rank > 0 OR s.vec_score > 0
    ORDER BY score DESC, n.captured_at DESC
    LIMIT k;
$$;

-- Chronological overview for the agent: newest notebooks first.
CREATE OR REPLACE VIEW remarkable.v_timeline AS
SELECT id,
       captured_at,
       captured_date_source,
       visible_name,
       page_count,
       status,
       ocr_engine,
       ocr_confidence,
       nc_pdf_path
FROM remarkable.notebook
WHERE status <> 'archived'
ORDER BY captured_at DESC;

-- Notebooks that need attention (failed OCR, empty text, missing publish).
CREATE OR REPLACE VIEW remarkable.v_attention AS
SELECT n.id, n.captured_at, n.visible_name, n.status, n.error,
       count(p.page_no)                                        AS pages,
       count(*) FILTER (WHERE coalesce(p.text_len,0) = 0)      AS pages_without_text
FROM remarkable.notebook n
LEFT JOIN remarkable.page p ON p.notebook_id = n.id
WHERE n.status IN ('failed','new')
   OR (n.status = 'indexed' AND n.ocr_confidence < 0.5)
GROUP BY n.id, n.captured_at, n.visible_name, n.status, n.error
ORDER BY n.captured_at DESC;

-- Service role for the pipeline. Password is set out-of-band by the deploy step
-- (never in this file); keep the pipeline credentials in a 0600 file beside the compose file.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rmbridge') THEN
        CREATE ROLE rmbridge LOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA core, remarkable TO rmbridge;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, remarkable TO rmbridge;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core, remarkable TO rmbridge;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, remarkable
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rmbridge;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, remarkable
    GRANT USAGE, SELECT ON SEQUENCES TO rmbridge;
