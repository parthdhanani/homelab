"""One-shot migration: re-embed all memories with the search_document prefix
required by nomic-embed-text-v1.5. Safe to re-run (idempotent — recomputes all).
Run inside the container: docker exec cryptex-ob1 python reembed.py
"""
import os

import psycopg2
from fastembed import TextEmbedding
from pgvector.psycopg2 import register_vector

conn = psycopg2.connect(
    host=os.environ.get("DB_HOST", "cryptex-pgvector"),
    port=int(os.environ.get("DB_PORT", 5432)),
    dbname=os.environ.get("DB_NAME", "ob1"),
    user=os.environ.get("DB_USER", "ob1"),
    password=os.environ["DB_PASSWORD"],
)
register_vector(conn)

model = TextEmbedding("nomic-ai/nomic-embed-text-v1.5")

cur = conn.cursor()
cur.execute("SELECT id, content FROM memories ORDER BY id")
rows = cur.fetchall()
print(f"re-embedding {len(rows)} memories...")

BATCH = 4
for i in range(0, len(rows), BATCH):
    batch = rows[i:i + BATCH]
    texts = ["search_document: " + content[:2000] for _, content in batch]
    vecs = list(model.embed(texts))
    for (mem_id, _), vec in zip(batch, vecs):
        cur.execute("UPDATE memories SET embedding = %s WHERE id = %s", (vec.tolist(), mem_id))
    conn.commit()
    print(f"  {min(i + BATCH, len(rows))}/{len(rows)}")

cur.close()
conn.close()
print("done")
