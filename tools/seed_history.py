#!/usr/bin/env python3
"""Seed Clipword's SwiftData store with synthetic clipboard history.

Writes HistoryItem + ClipboardEvent rows directly into
~/Library/Application Support/Clipword/Storage.sqlite, matching the
on-disk format produced by HistoryStore.addFromPasteboard (sorted-keys
JSON contentData blob, CoreData timestamps, 16-byte UUID blobs).

Run this while the app is NOT running, then launch the app.

Usage:
    python3 tools/seed_history.py --count 1600 --days 14
    python3 tools/seed_history.py --clean

Seeded rows are tagged via ZPINKEY='__seed__' (an unused column) so
--clean removes exactly them and nothing else.
"""

import argparse
import json
import os
import random
import sqlite3
import sys
import uuid

STORE = os.path.expanduser(
    "~/Library/Application Support/Clipword/Storage.sqlite"
)
# CoreData timestamps are seconds since 2001-01-01 00:00:00 UTC.
COREDATA_EPOCH_OFFSET = 978307200.0

BUNDLE_IDS = [
    "com.apple.TextEdit",
    "com.apple.Safari",
    "com.apple.Terminal",
    "com.tinyspeck.slackmacgap",
    None,
]
PB_TYPES = ["public.utf8-plain-text", "NSStringPboardType"]

WORDS = (
    "alpha beta gamma delta epsilon clipboard snippet manager render "
    "scroll buffer history palette hotkey window search filter store "
    "memory thread async await context kernel driver packet socket "
).split()

CODE_SNIPPETS = [
    "let value = compute(input: data)\n    return value.sorted()",
    "func handle(event: ClipboardEvent) -> Bool {\n    guard event.isValid else { return false }\n    return true\n}",
    "SELECT z_pk, z_title FROM zhistoryitem WHERE z_ispinned = 1;",
    "for (const item of items) {\n  render(item.title, item.icon);\n}",
    "struct Config { var interval: Double = 0.5; var limit: Int = 80 }",
    "curl -fsSL https://api.example.com/v2/items?offset=120 -H 'Accept: application/json'",
]

URLS = [
    "https://example.com/articles/entry-{:04d}",
    "https://docs.flutter.dev/testing/widget-tests#{:04d}",
    "https://github.com/cognition-ai/clipword/pull/{:04d}",
    "https://en.wikipedia.org/wiki/Clipboard_(computing)?rev={:04d}",
]


def sentence(rng: random.Random, lo: int, hi: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(rng.randint(lo, hi))).capitalize() + "."


def make_text(rng: random.Random, i: int) -> tuple[str, str]:
    """Return (plainText, category) for item i."""
    roll = rng.random()
    if roll < 0.15:
        return rng.choice(URLS).format(i), "link"
    if roll < 0.30:
        snippet = rng.choice(CODE_SNIPPETS)
        return f"Snippet {i:04d}: {snippet}", "code"
    if roll < 0.38:
        # Long-form items to exercise detail-pane scrolling and metrics.
        paras = [
            f"Paragraph {i:04d}.{p} " + sentence(rng, 30, 80)
            for p in range(rng.randint(3, 9))
        ]
        return "\n\n".join(paras), "plainText"
    return f"Stress item {i:04d} — " + sentence(rng, 4, 14), "plainText"


def metrics(text: str) -> tuple[int, int, int, int]:
    words = len(text.split())
    lines = text.count("\n") + 1
    chars = len(text)
    reading = int(words * 0.3)
    return words, lines, chars, reading


def content_data(plain_text: str) -> bytes:
    blob = {
        "contentType": "text",
        "hasColorOnPasteboard": False,
        "pasteboardTypes": PB_TYPES,
        "plainText": plain_text,
    }
    return json.dumps(blob, separators=(",", ":"), sort_keys=True).encode()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--count", type=int, default=1600)
    ap.add_argument("--days", type=int, default=14,
                    help="Spread items across this many days")
    ap.add_argument("--pin-rate", type=float, default=0.008)
    ap.add_argument("--bookmark-rate", type=float, default=0.012)
    ap.add_argument("--store", default=STORE)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--clean", action="store_true",
                    help="Delete all rows previously inserted by this tool")
    args = ap.parse_args()

    if not os.path.exists(args.store):
        sys.exit(f"Store not found: {args.store}")

    con = sqlite3.connect(args.store)
    cur = con.cursor()

    if args.clean:
        cur.execute(
            "DELETE FROM ZCLIPBOARDEVENT WHERE ZITEM IN "
            "(SELECT Z_PK FROM ZHISTORYITEM WHERE ZPINKEY='__seed__')"
        )
        n = cur.execute("DELETE FROM ZHISTORYITEM WHERE ZPINKEY='__seed__'").rowcount
        con.commit()
        total = cur.execute("SELECT COUNT(*) FROM ZHISTORYITEM").fetchone()[0]
        print(f"Removed {n} seeded items. Store now holds {total} history items.")
        con.close()
        return

    ent = cur.execute(
        "SELECT Z_ENT, Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='HistoryItem'"
    ).fetchone()
    event_ent = cur.execute(
        "SELECT Z_ENT, Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='ClipboardEvent'"
    ).fetchone()
    if not ent or not event_ent:
        sys.exit("Z_PRIMARYKEY entries missing — is this a Clipword store?")
    hist_ent, next_pk = ent
    evt_ent, next_evt_pk = event_ent

    import time

    now_cd = time.time() - COREDATA_EPOCH_OFFSET
    rng = random.Random(args.seed)
    span = args.days * 86400.0
    step = span / args.count

    rows = []
    events = []
    for i in range(args.count):
        pk = next_pk + 1 + i
        # Newest first, spread back `days` days, small jitter inside the step.
        ts = now_cd - (i * step + rng.uniform(0, step * 0.9))
        text, category = make_text(rng, i)
        words, lines, chars, reading = metrics(text)
        title = text.splitlines()[0][:200]
        pinned = 1 if rng.random() < args.pin_rate else 0
        bookmarked = 1 if rng.random() < args.bookmark_rate else 0
        bundle = rng.choice(BUNDLE_IDS)
        item_id = uuid.uuid4().bytes
        evt_id = uuid.uuid4().bytes
        rows.append((
            pk, hist_ent, 1, chars, 1, bookmarked, pinned, lines, 0,
            reading, words, ts, ts, None, bundle, category, "text",
            None, "__seed__", text, title, item_id, content_data(text),
            None, json.dumps(PB_TYPES).encode(),
        ))
        events.append((
            next_evt_pk + 1 + i, evt_ent, 1, pk, ts, bundle, "copied", evt_id,
        ))

    cur.executemany("INSERT INTO ZHISTORYITEM VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    cur.executemany("INSERT INTO ZCLIPBOARDEVENT VALUES (?,?,?,?,?,?,?,?)", events)
    cur.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME='HistoryItem'", (next_pk + args.count,))
    cur.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME='ClipboardEvent'", (next_evt_pk + args.count,))
    con.commit()

    total = cur.execute("SELECT COUNT(*) FROM ZHISTORYITEM").fetchone()[0]
    days = cur.execute(
        "SELECT COUNT(DISTINCT date(ZLASTCOPIEDAT + 978307200, 'unixepoch')) FROM ZHISTORYITEM"
    ).fetchone()[0]
    cats = dict(cur.execute(
        "SELECT ZCONTENTCATEGORYRAW, COUNT(*) FROM ZHISTORYITEM GROUP BY 1"
    ).fetchall())
    con.close()
    print(f"Inserted {args.count} items. Store now holds {total} history items across {days} days.")
    print(f"Categories: {cats}")


if __name__ == "__main__":
    main()
