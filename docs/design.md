# Design

The full design behind remarkable-bridge: stages, data model, decisions, failure modes and effort
estimates. Written before the code, revised as measurement replaced assumption.

## Goal

Handwritten notebooks become, automatically and without manual export:

1. a **vector PDF** per notebook, one page per notebook page,
2. **page images** (PNG, 300 dpi),
3. **machine-readable text** per page plus a combined Markdown rendering with YAML front matter,
4. stored in **Nextcloud** in a **chronological** folder/file layout,
5. indexed in **Postgres + pgvector** so retrieval is fast, semantic, and page-citable.

Done means: a new notebook reaches Nextcloud unaided, is findable in the index, and a second run
changes nothing.

## Architecture

Six idempotent stages, one entrypoint, run by a systemd timer. Each stage persists state, so a
re-run costs nothing and never duplicates.

### 1. Auth & poll

- `rmapi` with a one-time code from `my.remarkable.com/device/desktop/connect`; token cached in a
  `0600` file. Refresh is automatic; hard expiry is detected, not prevented.
- Poll the cloud tree, diff against local state. Cheap enough to run every 15–60 minutes.
- **Change key:** `document_id + visibleName + cloud lastModified + size`. Never mtime alone —
  renames and re-syncs shuffle it.
- Without a subscription, files untouched for ~50 days stop syncing to apps. This caps backfill of
  very old notebooks. Documented, not worked around.

### 2. Render

- `rmc` (v6 `.rm`) → vector PDF: the PDF deliverable, ink quality preserved.
- `pdftoppm -r 300 -png` → page images.
- Page order comes from `.content` (`pages` array) and `.pagedata`, never from directory listing.
- **Layers matter:** a notebook can hold multiple ink layers (one `.rm` per layer in v6). Merge all
  of them or text written on a second layer silently disappears.

### 3. Text extraction

Per page, then a combined document. `rmc` does **not** recognise handwriting — its `-t markdown`
only dumps *typed* text layers. Recognised text comes from a vision model via the ollama HTTP API.

```markdown
---
title: Kitchen budget
remarkable_id: <uuid>
created: <ISO8601>        # device-side
modified: <ISO8601>       # cloud lastModified
captured_date_source: metadata|cloud|filename
pages: 7
ocr_engine: vision-llm
ocr_model: <model>
ocr_confidence: 0.91
tags: [remarkable, handwriting]
---

## Page 1
<recognised text>

![page 1](images/page-001.png)
```

The front matter is what makes the Nextcloud copy self-describing years later, independent of the
database. Mirror the key fields into Nextcloud system tags so full-text search there works even if
the index is lost.

### 4. Publish to Nextcloud

```
/Notes/reMarkable/2026/2026-10/2026-10-24_1430_Kitchen-budget.pdf
                                          …_Kitchen-budget.md
                                          …_Kitchen-budget/images/page-001.png
```

- ISO datetime prefix → lexicographic sort equals chronological sort in every client.
- Year / year-month folders give coarse browsing without a database.
- `captured_at` = notebook creation date from metadata; fallback chain recorded in
  `captured_date_source`.
- Writes go through WebDAV as a dedicated service account, never the human user's account. Direct
  on-disk writes would require a Nextcloud file scan; WebDAV does not.

### 5. Index

One Postgres, one schema per domain. The `remarkable` schema holds `notebook` → `page` → `chunk`,
with `tsv` generated from German text and `embedding vector(1024)` per chunk, both indexed
(GIN + HNSW). `remarkable.search(q, q_emb, k)` fuses keyword and semantic ranking 50/50 and returns
page-level hits with the Nextcloud path.

Rationale for a dedicated database rather than reusing an existing document store: identity,
chronology and page-level citations are first-class here and would be foreign keys bolted onto
someone else's schema. Existing stores keep their own indexes; this one is authoritative for these
notes.

### 6. Verify & report

- After publish: `PROPFIND` the exact path, compare size and etag.
- After index: assert text length above a threshold. A zero-text upload is the likeliest silent
  failure and must exit non-zero.
- One log file, one state file, `flock` against overlapping runs, `--dry-run`, alerting on failure.

## Data model

```
core.source        id, kind, description              -- which systems feed the DB
core.ingest_run    source, stage, status, timings      -- ops visibility

remarkable.notebook  id, remarkable_id (unique), visible_name, remarkable_path,
                     captured_at, captured_date_source, cloud_modified_at, page_count,
                     pdf_sha256, rm_archive_path, nc_pdf_path, nc_md_path,
                     ocr_engine, ocr_model, ocr_confidence,
                     status(new|rendered|extracted|published|indexed|failed|archived), error
remarkable.page      notebook_id, page_no, image_path, text, text_len(generated),
                     ocr_confidence, layer_count
remarkable.chunk     notebook_id, page_no, chunk_idx, text,
                     tsv(generated, german), embedding vector(1024), embedded_at
```

Views: `v_timeline` (chronological overview), `v_attention` (failed / empty / low-confidence
notebooks — the alarm surface).

Indexes: GIN on `tsv`, GIN `gin_trgm_ops` on text, HNSW cosine on `embedding`, BTree on
`captured_at DESC`.

## Decisions

| # | Decision | Reasoning |
|---|---|---|
| D1 | Dedicated Postgres+pgvector as the authoritative index | page-level citations and chronology are primary; no second store to keep in sync |
| D2 | Target device: reMarkable 2 (`.rm` v6) | renderer support is solid; raw archive keeps Paper Pro open |
| D3 | Handwriting OCR via the ollama HTTP API, vision model | same plumbing local or cloud; tesseract is inadequate for ink |
| D4 | Polling every 15 min | matches typical cron cadence; no webhook exists |
| D5 | Page PNGs in v1, crops later | images are needed for OCR and human review first |
| D6 | `.md` beside the PDF, not a Nextcloud Notes entry | self-describing file, no API coupling |

## Risks

| Risk | Mitigation |
|---|---|
| Cloud API is unofficial; protocol changes | pin `rmapi`, archive raw `.rm` so re-render is always possible, alert on auth failure |
| Token expiry / re-auth needed | detect via exit code, alert with the connect URL, documented manual step |
| Handwriting quality insufficient | measure on real notebooks before committing; fallback is indexing a vision-generated description rather than verbatim text |
| Duplicates after rename | identity is the document UUID |
| Storage growth (PNG ≈ 1–3 MB/page at 300 dpi) | 120 dpi previews + 300 dpi only where OCR needs it, or WebP |
| Two indexes → two truths | exactly one authoritative store for these notes |

## Effort

| Phase | Content | Days |
|---|---|---|
| P0 | auth, cloud listing, single notebook dump | 0.5 |
| P1 | OCR benchmark on real notebooks, engine decision | 1 |
| P2 | poll/diff, render PDF + PNG, layers, raw archive | 2–3 |
| P3 | per-page OCR, Markdown assembly, chunking | 1–2 |
| P4 | Nextcloud service account, WebDAV idempotency, chronology, read-back | 1.5 |
| P5 | index upserts, embeddings, retrieval smoke tests | 1–1.5 |
| P6 | timer, flock, logging, alerting, backfill, runbook | 1.5 |
| **Total** | | **~9–11** |

## Acceptance criteria

1. New notebook + wifi → appears in Nextcloud within one poll interval, with `.md` and `images/`.
2. A second run changes nothing (no duplicates, no re-upload).
3. Renaming on the tablet updates the name; deleting there marks `archived` (no hard delete).
4. "What did I note about X in month Y?" returns a hit with a Nextcloud link **and page number** in
   under 2 s.
5. Failed OCR raises a visible alarm, never a document with empty content.
6. A 12-month backfill completes unattended.

## Out of scope for v1

- Write-back to the tablet (read-only pipeline).
- Real-time / on-write sync; polling only.
- Re-OCRing an existing document archive.
- Mirroring the tablet's own folder tree (the original path is stored in `remarkable_path`).
- Multi-user or shared tablets.
- Deleting anything on the tablet or in the cloud.
