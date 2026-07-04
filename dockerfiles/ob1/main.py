"""
OB1 — Personal Memory MCP Server
Semantic memory over PKM vault + session summaries via fastembed + pgvector.

MCP tools (for Claude Code):  POST /mcp
REST API (for bash hooks):     POST /api/remember  GET /api/search  GET /health

Originated as a fork of NateBJones-Projects/OB1 (github.com/NateBJones-Projects/OB1,
FSL-1.1-MIT, Copyright Nate B. Jones) — a Supabase+Deno "Open Brain" memory platform.
This version has since been fully rewritten to a standalone Python/FastAPI/pgvector
service with no shared code, for personal/internal use only (FSL's Permitted Purpose).
"""

import json
import logging
import os
import re
import threading
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.server import TransportSecuritySettings
from psycopg2 import pool as pgpool
from pgvector.psycopg2 import register_vector

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ob1")

# ── Config ────────────────────────────────────────────────────────────────────

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "cryptex-pgvector"),
    "port": int(os.environ.get("DB_PORT", 5432)),
    "dbname": os.environ.get("DB_NAME", "ob1"),
    "user": os.environ.get("DB_USER", "ob1"),
    "password": os.environ["DB_PASSWORD"],
}

MODEL_NAME = "nomic-ai/nomic-embed-text-v1.5"
EMBED_DIM = 768
DEDUP_THRESHOLD = float(os.environ.get("OB1_DEDUP_THRESHOLD", 0.97))

# ── Globals (initialized at startup) ─────────────────────────────────────────

_db_pool: pgpool.ThreadedConnectionPool | None = None
_embedder = None
_embedder_lock = threading.Lock()


def get_db():
    conn = _db_pool.getconn()
    register_vector(conn)
    return conn


def release_db(conn):
    _db_pool.putconn(conn)


def get_embedder():
    global _embedder
    with _embedder_lock:
        if _embedder is None:
            from fastembed import TextEmbedding
            log.info("Loading fastembed model %s (may download ~270MB)...", MODEL_NAME)
            _embedder = TextEmbedding(MODEL_NAME)
            log.info("Embedding model ready.")
    return _embedder


def embed(text: str, kind: str = "document") -> list[float]:
    # nomic-embed-text-v1.5 requires task prefixes; omitting them degrades retrieval
    prefix = "search_query: " if kind == "query" else "search_document: "
    model = get_embedder()
    return next(model.embed([prefix + text])).tolist()


def init_db():
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS memories (
                id        BIGSERIAL PRIMARY KEY,
                content   TEXT NOT NULL,
                source    TEXT DEFAULT 'manual',
                tags      TEXT[] DEFAULT '{{}}',
                embedding vector({EMBED_DIM}),
                created_at TIMESTAMPTZ DEFAULT NOW(),
                session_id TEXT,
                is_deleted BOOLEAN NOT NULL DEFAULT FALSE
            );
        """)
        cur.execute("ALTER TABLE memories ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT FALSE;")
        cur.execute("""
            ALTER TABLE memories ADD COLUMN IF NOT EXISTS search_vector tsvector
                GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;
        """)
        cur.execute(f"""
            CREATE INDEX IF NOT EXISTS memories_embedding_idx
                ON memories USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50);
        """)
        cur.execute("CREATE INDEX IF NOT EXISTS memories_created_idx ON memories (created_at DESC);")
        cur.execute("CREATE INDEX IF NOT EXISTS memories_search_vector_idx ON memories USING GIN (search_vector);")
        conn.commit()
        cur.close()
        log.info("DB schema ready.")
    finally:
        release_db(conn)


# ── Core operations ───────────────────────────────────────────────────────────

def _remember(content: str, source: str = "manual", tags: list[str] | None = None, session_id: str = "") -> str:
    if not content.strip():
        return "Empty content — skipped."
    vec = embed(content)
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute(
            """SELECT id, 1 - (embedding <=> %s::vector) AS similarity
               FROM memories
               WHERE is_deleted = FALSE
               ORDER BY embedding <=> %s::vector
               LIMIT 1""",
            (vec, vec),
        )
        nearest = cur.fetchone()
        if nearest and nearest[1] >= DEDUP_THRESHOLD:
            return f"Duplicate of #{nearest[0]} (similarity {nearest[1]:.3f}) — skipped."
        cur.execute(
            "INSERT INTO memories (content, source, tags, embedding, session_id) VALUES (%s, %s, %s, %s, %s) RETURNING id",
            (content, source, tags or [], vec, session_id or None),
        )
        mem_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        return f"Stored memory #{mem_id}"
    finally:
        release_db(conn)


KEYWORD_BOOST = 0.15  # additive bump for exact-term hits embeddings underrate; capped at 0.999


def _search(query: str, k: int = 5) -> list[dict]:
    if not query.strip():
        return []
    vec = embed(query, kind="query")
    pool = max(k * 3, 15)

    # Postgres's parser treats dotted/hyphenated tokens (e.g. "crg-ob1-sync.timer") as a
    # single "host"-type lexeme and won't split them — plainto_tsquery on the raw query
    # then never matches. Splitting into words ourselves and OR-ing (not AND-ing, since
    # plainto_tsquery on a full sentence would require every word present) restores recall.
    words = re.findall(r"\w+", query.lower()) or [query]
    params = {"vec": vec, "pool": pool}
    word_keys = []
    for i, w in enumerate(words):
        key = f"w{i}"
        params[key] = w
        word_keys.append(key)
    or_tsquery = " || ".join(f"plainto_tsquery('english', %({k})s)" for k in word_keys)

    conn = get_db()
    try:
        from psycopg2.extras import RealDictCursor
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute(
            f"""WITH vector_hits AS (
                   SELECT id, content, source, tags, session_id, created_at,
                          1 - (embedding <=> %(vec)s::vector) AS similarity,
                          FALSE AS is_keyword_hit
                   FROM memories
                   WHERE is_deleted = FALSE
                   ORDER BY embedding <=> %(vec)s::vector
                   LIMIT %(pool)s
               ),
               keyword_hits AS (
                   SELECT id, content, source, tags, session_id, created_at,
                          1 - (embedding <=> %(vec)s::vector) AS similarity,
                          TRUE AS is_keyword_hit
                   FROM memories
                   WHERE is_deleted = FALSE
                     AND search_vector @@ ({or_tsquery})
                   ORDER BY ts_rank(search_vector, ({or_tsquery})) DESC
                   LIMIT %(pool)s
               )
               SELECT DISTINCT ON (id) *
               FROM (SELECT * FROM vector_hits UNION ALL SELECT * FROM keyword_hits) merged
               ORDER BY id, is_keyword_hit DESC""",
            params,
        )
        rows = cur.fetchall()
        cur.close()
        results = [
            {
                "id": r["id"],
                "content": r["content"],
                "source": r["source"],
                "tags": r["tags"],
                "similarity": round(float(r["similarity"]), 3),
                "created_at": str(r["created_at"]),
                "_score": min(float(r["similarity"]) + (KEYWORD_BOOST if r["is_keyword_hit"] else 0.0), 0.999),
            }
            for r in rows
        ]
        results.sort(key=lambda r: r["_score"], reverse=True)
        for r in results:
            del r["_score"]
        return results[:k]
    finally:
        release_db(conn)


def _forget(memory_id: int) -> str:
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute(
            "UPDATE memories SET is_deleted = TRUE WHERE id = %s AND is_deleted = FALSE RETURNING id",
            (memory_id,),
        )
        deleted = cur.fetchone()
        conn.commit()
        cur.close()
        return f"Deleted #{memory_id}" if deleted else f"#{memory_id} not found"
    finally:
        release_db(conn)


def _count() -> int:
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM memories WHERE is_deleted = FALSE")
        n = cur.fetchone()[0]
        cur.close()
        return n
    finally:
        release_db(conn)


# ── MCP server ────────────────────────────────────────────────────────────────

mcp = FastMCP(
    "ob1-memory",
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=False,
    ),
)


@mcp.tool()
def remember(content: str, source: str = "manual", tags: list[str] | None = None, session_id: str = "") -> str:
    """Store a memory with semantic embedding for future retrieval across sessions."""
    return _remember(content, source, tags, session_id)


@mcp.tool()
def search(query: str, k: int = 5) -> str:
    """Hybrid search: semantic (embeddings) + keyword (full-text) over memories.
    Returns top-K relevant memories as JSON. Use this before answering questions
    about past work, decisions, or context."""
    results = _search(query, k)
    if not results:
        return "No memories found."
    return json.dumps(results, indent=2)


@mcp.tool()
def forget(memory_id: int) -> str:
    """Soft-delete a specific memory by ID (excluded from search, recoverable in DB)."""
    return _forget(memory_id)


@mcp.tool()
def memory_stats() -> str:
    """Return total memory count and recent sources."""
    n = _count()
    conn = get_db()
    try:
        from psycopg2.extras import RealDictCursor
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT source, COUNT(*) as n FROM memories WHERE is_deleted = FALSE GROUP BY source ORDER BY n DESC LIMIT 10")
        sources = cur.fetchall()
        cur.close()
        return json.dumps({"total": n, "by_source": [dict(r) for r in sources]}, indent=2)
    finally:
        release_db(conn)


# ── FastAPI (REST for hooks + health) ─────────────────────────────────────────

# Build MCP ASGI app first so lifespan can run its sub-lifespan
mcp_app = mcp.streamable_http_app()


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _db_pool
    log.info("Starting ob1...")
    _db_pool = pgpool.ThreadedConnectionPool(1, 10, **DB_CONFIG)
    init_db()
    threading.Thread(target=get_embedder, daemon=True).start()
    # Run the MCP sub-app's lifespan (initializes StreamableHTTP task group)
    async with mcp_app.router.lifespan_context(mcp_app):
        log.info("ob1 ready.")
        yield
    _db_pool.closeall()


api = FastAPI(lifespan=lifespan)

# Bearer-token auth on /api/* — /health stays open for healthchecks/monitoring.
# If OB1_API_KEY is unset, auth is disabled (graceful rollout / local dev).
API_KEY = os.environ.get("OB1_API_KEY", "").strip()


def _check_auth(request: Request):
    if not API_KEY:
        return None
    auth = request.headers.get("authorization", "")
    if auth == f"Bearer {API_KEY}":
        return None
    return JSONResponse({"detail": "unauthorized"}, status_code=401)


@api.get("/health")
def health():
    try:
        n = _count()
        return {"status": "ok", "memories": n, "model_ready": _embedder is not None}
    except Exception as e:
        return JSONResponse({"status": "error", "detail": str(e)}, status_code=500)


@api.post("/api/remember")
async def api_remember(request: Request):
    denied = _check_auth(request)
    if denied:
        return denied
    body = await request.json()
    result = _remember(
        body.get("content", ""),
        body.get("source", "hook"),
        body.get("tags", []),
        body.get("session_id", ""),
    )
    return {"result": result}


@api.get("/api/search")
def api_search(request: Request, q: str = Query(...), k: int = Query(5)):
    denied = _check_auth(request)
    if denied:
        return denied
    results = _search(q, k)
    return {"results": results}


# Mount MCP at "/" — FastMCP's route is internally at /mcp.
# FastAPI's own routes (/health, /api/*) are matched first by the router.
api.mount("/", mcp_app)
log.info("MCP mounted (route: /mcp)")


if __name__ == "__main__":
    uvicorn.run("main:api", host="0.0.0.0", port=8000, log_level="info")
