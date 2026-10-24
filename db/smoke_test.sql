-- smoke_test.sql — proves the schema accepts writes and that hybrid search returns
-- the expected notebook. Runs as the pipeline role, then cleans up after itself.
\pset pager off
\set ON_ERROR_STOP on

BEGIN;

INSERT INTO core.ingest_run (source, stage, status, finished_at, detail)
VALUES ('remarkable', 'smoke-test', 'ok', now(), 'schema smoke test');

INSERT INTO remarkable.notebook
    (remarkable_id, visible_name, remarkable_path, captured_at, captured_date_source,
     cloud_modified_at, page_count, ocr_engine, ocr_model, ocr_confidence, status)
VALUES
    ('smoke-0000-1111-2222-333344445555', 'Kuechenrenovierung Budget', '/Work/2026',
     now() - interval '30 days', 'metadata', now() - interval '1 hour', 2,
     'ollama-vision', 'gemma4:latest', 0.870, 'indexed');

INSERT INTO remarkable.page (notebook_id, page_no, image_path, text, ocr_confidence, layer_count)
SELECT id, 1, 'images/page-001.png',
       'Kuechenrenovierung: Budget 12000 Euro. Fliesen 3200, Elektrik 1800, Schreiner offen.',
       0.910, 1
FROM remarkable.notebook WHERE remarkable_id = 'smoke-0000-1111-2222-333344445555';

INSERT INTO remarkable.page (notebook_id, page_no, image_path, text, ocr_confidence, layer_count)
SELECT id, 2, 'images/page-002.png',
       'Termin mit dem Schreiner am Dienstag, Angebot vergleichen.',
       0.830, 2
FROM remarkable.notebook WHERE remarkable_id = 'smoke-0000-1111-2222-333344445555';

-- chunk 1 carries an embedding, chunk 2 is text-only (FTS path)
INSERT INTO remarkable.chunk (notebook_id, page_no, chunk_idx, text, embedding, embedded_at)
SELECT id, 1, 0, 'Kuechenrenovierung: Budget 12000 Euro. Fliesen 3200, Elektrik 1800, Schreiner offen.',
       ('[' || repeat('0.01,', 1023) || '0.01]')::vector, now()
FROM remarkable.notebook WHERE remarkable_id = 'smoke-0000-1111-2222-333344445555';

INSERT INTO remarkable.chunk (notebook_id, page_no, chunk_idx, text)
SELECT id, 2, 0, 'Termin mit dem Schreiner am Dienstag, Angebot vergleichen.'
FROM remarkable.notebook WHERE remarkable_id = 'smoke-0000-1111-2222-333344445555';

\echo '--- full-text only (q, no embedding) ---'
SELECT visible_name, page_no, round(score::numeric, 4) AS score, left(snippet, 60) AS snippet
FROM remarkable.search('Schreiner Angebot', NULL, 5);

\echo '--- vector only (embedding, no q) ---'
SELECT visible_name, page_no, round(score::numeric, 4) AS score
FROM remarkable.search(NULL, ('[' || repeat('0.01,', 1023) || '0.01]')::vector, 5);

\echo '--- hybrid (q + embedding) ---'
SELECT visible_name, page_no, round(score::numeric, 4) AS score, captured_at::date
FROM remarkable.search('Budget Fliesen', ('[' || repeat('0.01,', 1023) || '0.01]')::vector, 5);

\echo '--- generated tsv is populated + german stemming works ---'
SELECT chunk_idx, tsv IS NOT NULL AS has_tsv,
       tsv @@ websearch_to_tsquery('german', 'Kuechenrenovierung') AS matches
FROM remarkable.chunk ORDER BY chunk_idx;

\echo '--- views ---'
SELECT visible_name, page_count, status FROM remarkable.v_timeline;
SELECT visible_name, pages, pages_without_text FROM remarkable.v_attention;

ROLLBACK;

\echo '--- after rollback: nothing left behind ---'
SELECT count(*) AS notebooks FROM remarkable.notebook;
SELECT count(*) AS chunks FROM remarkable.chunk;
