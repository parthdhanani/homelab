"""
OB1 — Personal Memory MCP Server
Semantic memory over PKM vault + session summaries via fastembed + pgvector.

MCP tools (for Claude Code):  POST /mcp
REST API (for bash hooks):     POST /api/remember  GET /api/search  GET /health
"""

import json
import logging
import os
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


def embed(text: str) -> list[float]:
    model = get_embedder()
    return next(model.embed([text])).tolist()


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
                session_id TEXT
            );
        """)
        cur.execute(f"""
            CREATE INDEX IF NOT EXISTS memories_embedding_idx
                ON memories USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50);
        """)
        cur.execute("CREATE INDEX IF NOT EXISTS memories_created_idx ON memories (created_at DESC);")
        conn.commit()
        cur.close()
        log.info("DB schema ready.")
    finally:
        release_db(conn)


# ── Core operations ───────────────────────────────────────────────────────────

def _remember(content: str, source: str = "manual", tags: list[str] = [], session_id: str = "") -> str:
    if not content.strip():
        return "Empty content — skipped."
    vec = embed(content)
    conn = get_db()
    try:
        cur = conn.cursor()
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


def _search(query: str, k: int = 5) -> list[dict]:
    if not query.strip():
        return []
    vec = embed(query)
    conn = get_db()
    try:
        from psycopg2.extras import RealDictCursor
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute(
            """SELECT id, content, source, tags, session_id, created_at,
                      1 - (embedding <=> %s::vector) AS similarity
               FROM memories
               ORDER BY embedding <=> %s::vector
               LIMIT %s""",
            (vec, vec, k),
        )
        rows = cur.fetchall()
        cur.close()
        return [
            {
                "id": r["id"],
                "content": r["content"],
                "source": r["source"],
                "tags": r["tags"],
                "similarity": round(float(r["similarity"]), 3),
                "created_at": str(r["created_at"]),
            }
            for r in rows
        ]
    finally:
        release_db(conn)


def _forget(memory_id: int) -> str:
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute("DELETE FROM memories WHERE id = %s RETURNING id", (memory_id,))
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
        cur.execute("SELECT COUNT(*) FROM memories")
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
def remember(content: str, source: str = "manual", tags: list[str] = [], session_id: str = "") -> str:
    """Store a memory with semantic embedding for future retrieval across sessions."""
    return _remember(content, source, tags, session_id)


@mcp.tool()
def search(query: str, k: int = 5) -> str:
    """Search memories semantically. Returns top-K relevant memories as JSON.
    Use this before answering questions about past work, decisions, or context."""
    results = _search(query, k)
    if not results:
        return "No memories found."
    return json.dumps(results, indent=2)


@mcp.tool()
def forget(memory_id: int) -> str:
    """Delete a specific memory by ID."""
    return _forget(memory_id)


@mcp.tool()
def memory_stats() -> str:
    """Return total memory count and recent sources."""
    n = _count()
    conn = get_db()
    try:
        from psycopg2.extras import RealDictCursor
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT source, COUNT(*) as n FROM memories GROUP BY source ORDER BY n DESC LIMIT 10")
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


@api.get("/health")
def health():
    try:
        n = _count()
        return {"status": "ok", "memories": n}
    except Exception as e:
        return JSONResponse({"status": "error", "detail": str(e)}, status_code=500)


@api.post("/api/remember")
async def api_remember(request: Request):
    body = await request.json()
    result = _remember(
        body.get("content", ""),
        body.get("source", "hook"),
        body.get("tags", []),
        body.get("session_id", ""),
    )
    return {"result": result}


@api.get("/api/search")
def api_search(q: str = Query(...), k: int = Query(5)):
    results = _search(q, k)
    return {"results": results}


# Mount MCP at "/" — FastMCP's route is internally at /mcp.
# FastAPI's own routes (/health, /api/*) are matched first by the router.
api.mount("/", mcp_app)
log.info("MCP mounted (route: /mcp)")


if __name__ == "__main__":
    uvicorn.run("main:api", host="0.0.0.0", port=8000, log_level="info")
