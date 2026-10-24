# Database

Postgres 16 + `pgvector`, running on loopback only. One instance, one schema per domain:

- `core` — foundation shared by every pipeline: source registry, run log, trigger helper.
- `remarkable` — the notebook domain: `notebook` → `page` → `chunk`, plus hybrid search and views.

## Bring it up

```bash
printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)" > .env && chmod 600 .env
printf '%s\n' "$(openssl rand -hex 24)" > .pgpass && chmod 600 .pgpass
docker compose up -d
```

Defaults: database `remarkable`, superuser `remarkable`, container `remarkable-db`, published on
`127.0.0.1:5433`. Override `POSTGRES_DB` / `POSTGRES_USER` in `.env` if you are deploying this under
a house name — the schema itself never hardcodes either, so only the compose file changes.

> The reference deployment runs this as the central database of a multi-service host, under a
> different container and database name. The schema is byte-identical; only `docker-compose.yml`
> differs.

## Init scripts

`init/*.sql` are executed by the Postgres entrypoint **only on first initialisation** of an empty
data volume. To change the schema later, either apply the statements manually or recreate the
volume — never assume an edit to these files lands on an existing database.

- `001_core.sql` — extensions (`vector`, `pg_trgm`), `core.source`, `core.ingest_run`,
  `core.touch_updated_at()`
- `002_remarkable.sql` — `remarkable.notebook/page/chunk`, generated `tsv`, HNSW + GIN indexes,
  `remarkable.search(q, q_emb, k)`, `v_timeline`, `v_attention`, and the unprivileged `rmbridge`
  pipeline role with grants scoped to those two schemas

## Check it

```bash
# structure: tables, views, indexes, functions, role
docker exec -i remarkable-db psql -U remarkable -d remarkable -f /dev/stdin < verify.sql

# behaviour: write, search, roll back — run as the pipeline role, not as superuser
PW=$(cat .pgpass)
docker exec -i remarkable-db psql -U remarkable -d remarkable -c "ALTER ROLE rmbridge PASSWORD '$PW';"
docker exec -i remarkable-db psql -U rmbridge -d remarkable -f /dev/stdin < smoke_test.sql
```

`smoke_test.sql` inserts a notebook, two pages and two chunks, exercises keyword-only,
vector-only and hybrid search, checks German stemming and the views, then `ROLLBACK`s and asserts
that nothing was left behind. If it prints hits and then zeros, the schema and the grants are good.

## Querying it

```sql
-- chronological overview
SELECT * FROM remarkable.v_timeline LIMIT 20;

-- keyword search (German stemming)
SELECT visible_name, page_no, score, snippet FROM remarkable.search('Schreiner Angebot', NULL, 5);

-- semantic search: pass a 1024-dim embedding, q may be NULL
SELECT visible_name, page_no, score FROM remarkable.search(NULL, $1::vector, 5);

-- hybrid
SELECT visible_name, page_no, score FROM remarkable.search('Budget Fliesen', $1::vector, 10);

-- what needs attention (failed OCR, empty pages, low confidence)
SELECT * FROM remarkable.v_attention;
```

Embedding width is fixed at `vector(1024)` to match `mxbai-embed-large`. A different model means
changing the column type in `002_remarkable.sql` and the function signature together.
