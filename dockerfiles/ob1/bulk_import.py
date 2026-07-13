"""
bulk_import.py — Import PKM vault + session summaries into ob1.
Run inside the ob1 container or from the host with correct DB env vars.

Usage:
  python bulk_import.py /path/to/pkm          # import all .md files
  python bulk_import.py /path/to/pkm --dry    # count files only
"""

import argparse
import os
import sys
import time
from pathlib import Path

import uuid

import psycopg2
from pgvector.psycopg2 import register_vector
from fastembed import TextEmbedding
from chonkie import RecursiveChunker

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "cryptex-pgvector"),
    "port": int(os.environ.get("DB_PORT", 5432)),
    "dbname": os.environ.get("DB_NAME", "ob1"),
    "user": os.environ.get("DB_USER", "ob1"),
    "password": os.environ["DB_PASSWORD"],
}

MODEL_NAME = "nomic-ai/nomic-embed-text-v1.5"
BATCH_SIZE = 32
CHUNK_THRESHOLD_TOKENS = 400
CHUNK_SIZE_TOKENS = 300


def chunk_text(chunker, content: str) -> list[str]:
    if len(content) < CHUNK_THRESHOLD_TOKENS * 3:
        return [content]
    chunks = chunker.chunk(content)
    if len(chunks) <= 1:
        return [content]
    return [c.text for c in chunks]


def already_indexed(conn, source: str) -> set[str]:
    cur = conn.cursor()
    cur.execute("SELECT source FROM memories WHERE source = %s LIMIT 1", (source,))
    # Return set of all indexed sources for this directory
    cur.execute("SELECT DISTINCT source FROM memories WHERE source LIKE %s", (f"pkm:%",))
    rows = cur.fetchall()
    cur.close()
    return {r[0] for r in rows}


def import_directory(root: Path, dry: bool = False):
    print(f"Scanning {root}...")
    # Never embed the _Private/ tree (financial/personal notes) into the searchable index.
    files = sorted(p for p in root.rglob("*.md") if "_Private" not in p.parts)
    print(f"Found {len(files)} markdown files.")

    if dry:
        print("Dry run — exiting.")
        return

    print(f"Loading embedding model {MODEL_NAME} (may download)...")
    embedder = TextEmbedding(MODEL_NAME)
    chunker = RecursiveChunker(chunk_size=CHUNK_SIZE_TOKENS)
    print("Model ready.")

    conn = psycopg2.connect(**DB_CONFIG)
    register_vector(conn)

    indexed = already_indexed(conn, "pkm")
    print(f"Already indexed: {len(indexed)} pkm sources.")

    cur = conn.cursor()
    ok = skip = err = 0
    start = time.time()

    for i, path in enumerate(files):
        rel = path.relative_to(root)
        source_key = f"pkm:{rel}"

        if source_key in indexed:
            skip += 1
            continue

        try:
            content = path.read_text(encoding="utf-8", errors="ignore").strip()
            if not content or len(content) < 20:
                skip += 1
                continue

            pieces = chunk_text(chunker, content)
            if len(pieces) == 1:
                vec = next(embedder.embed([content])).tolist()
                cur.execute(
                    "INSERT INTO memories (content, source, tags, embedding) VALUES (%s, %s, %s, %s)",
                    (content, source_key, ["pkm"], vec),
                )
            else:
                doc_id = str(uuid.uuid4())
                for idx, piece in enumerate(pieces):
                    vec = next(embedder.embed([piece])).tolist()
                    cur.execute(
                        "INSERT INTO memories (content, source, tags, embedding, doc_id, chunk_index) "
                        "VALUES (%s, %s, %s, %s, %s, %s)",
                        (piece, source_key, ["pkm"], vec, doc_id, idx),
                    )
            ok += 1

            if ok % BATCH_SIZE == 0:
                conn.commit()
                elapsed = time.time() - start
                rate = ok / elapsed
                remaining = (len(files) - i - 1) / rate if rate > 0 else 0
                print(f"  {ok}/{len(files)-skip} imported  {rate:.1f}/s  ~{remaining:.0f}s remaining")

        except Exception as e:
            err += 1
            print(f"  ERROR {path.name}: {e}")

    conn.commit()
    cur.close()
    conn.close()

    elapsed = time.time() - start
    print(f"\nDone in {elapsed:.1f}s: {ok} imported, {skip} skipped, {err} errors.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="Directory to import")
    parser.add_argument("--dry", action="store_true", help="Count files only")
    args = parser.parse_args()
    import_directory(Path(args.path), dry=args.dry)
