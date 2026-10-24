# pipeline

The ingest pipeline. **Not written yet** — this file describes the intended module layout so the
design survives contact with the code. Nothing here should be assumed to exist until the roadmap
box is ticked in the top-level README.

## Intended layout

```
pipeline/
  __main__.py      entrypoint: --dry-run, --only <stage>, --since <date>, exit codes
  config.py        env/TOML loading; paths, intervals, model names, DB DSN from a 0600 file
  state.py         state file (JSON), flock, per-document fingerprints, atomic writes
  cloud.py         rmapi wrapper: auth, list, fetch, change detection on document_id
  render.py        rmc → PDF, pdftoppm → PNG, page order from .content/.pagedata, layers merged
  ocr.py           ollama HTTP client: per-page text, think=false, retries, confidence
  assemble.py      Markdown + YAML front matter, chunking for the index
  publish.py       WebDAV: MKCOL/PUT idempotently, chronological paths, read-back verification
  index.py         upserts into remarkable.notebook/page/chunk, embeddings, search smoke test
  verify.py        PROPFIND/GET assertions, non-zero exit on silent-empty results
```

## Invariants the code must keep

1. **Identity is the document UUID.** Every upsert, state key and dedupe check keys on
   `remarkable_id`. Filenames are display, nothing else.
2. **A re-run is free.** Any stage can be re-executed on the same input without creating a second
   file, a second row or a second share.
3. **Never publish before verifying.** Text length is asserted after publish; a zero-text document
   is a failure, not a success with empty content.
4. **All layers are merged** before rendering. A second ink layer that disappears is data loss that
   looks like success.
5. **Raw ink is archived** before any conversion, so a better renderer or model later costs nothing
   but compute.
6. **Failures are loud.** Non-zero exit, alert, and a row in `core.ingest_run`; a silent skip is a
   bug.
7. **The pipeline role is unprivileged.** `rmbridge`, grants scoped to `core` and `remarkable`,
   never a superuser DSN.
