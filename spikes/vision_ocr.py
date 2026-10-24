#!/usr/bin/env python3
"""vision_ocr.py — handwriting/image OCR through the local ollama HTTP API.

Deliberately dependency-free (urllib only) so it runs on the host without a venv.
Used as the P1 spike harness: point it at a page image, get text + timing.

Usage:
    python3 vision_ocr.py PAGE_IMAGE [--model kimi-k2.6:cloud] [--json]
"""
import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request

OLLAMA = "http://127.0.0.1:11434/api/chat"

PROMPT = """Du bist ein Transkriptionswerkzeug fuer handschriftliche Notizen.

Transkribiere den gesamten handschriftlichen Text auf diesem Bild woertlich und
vollstaendig, Zeile fuer Zeile, in der Originalsprache. Regeln:
- Keine Zusammenfassung, keine Kommentare, keine Einleitung.
- Layout grob erhalten: Aufzaehlungen, Absaetze, Tabellenzeilen.
- Zahlen, Daten, Betraege und Namen exakt uebernehmen.
- Handelt es sich um eine Skizze oder Zeichnung ohne Text, gib "[[KEIN_TEXT]]" aus.
- Unleserliche Stellen als "[?]" markieren.
"""


def ocr(image_path: str, model: str, timeout: int = 300, think: bool = False) -> dict:
    with open(image_path, "rb") as fh:
        b64 = base64.b64encode(fh.read()).decode()

    payload = {
        "model": model,
        "stream": False,
        "messages": [{"role": "user", "content": PROMPT, "images": [b64]}],
        # thinking models otherwise burn the whole num_predict budget on reasoning
        # tokens and return an empty content string (observed with kimi-k2.6:cloud).
        "think": think,
        "options": {"temperature": 0.0, "num_predict": 4096},
    }
    req = urllib.request.Request(
        OLLAMA, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    started = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode() or "{}")
    elapsed = time.time() - started

    content = (body.get("message") or {}).get("content", "")
    return {
        "model": model,
        "image": image_path,
        "elapsed_s": round(elapsed, 1),
        "chars": len(content.strip()),
        "text": content.strip(),
        "eval_count": body.get("eval_count"),
        "prompt_eval_count": body.get("prompt_eval_count"),
        "done_reason": body.get("done_reason"),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--model", default="kimi-k2.6:cloud")
    ap.add_argument("--think", action="store_true", help="allow thinking tokens")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    try:
        out = ocr(args.image, args.model, think=args.think)
    except urllib.error.HTTPError as exc:
        print(f"ollama HTTP {exc.code}: {exc.read().decode()[:400]}", file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001 - spike harness, report anything
        print(f"failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 3

    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        print(f"model={out['model']} elapsed={out['elapsed_s']}s "
              f"chars={out['chars']} eval={out['eval_count']} "
              f"reason={out['done_reason']}")
        print("-" * 60)
        print(out["text"][:2000])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
