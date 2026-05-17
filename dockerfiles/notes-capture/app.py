import os
from datetime import datetime, timezone
from pathlib import Path
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse

TOKEN = os.environ["CAPTURE_TOKEN"]
INBOX = Path(os.environ.get("INBOX_PATH", "/pkm/00 Capture/Inbox.md"))

app = FastAPI(title="notes-capture")


def _check(token: str | None):
    if not token or token != TOKEN:
        raise HTTPException(401, "bad token")


def _append(text: str, source: str) -> str:
    text = text.strip()
    if not text:
        raise HTTPException(400, "empty")
    ts = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
    line = f"- [{ts}] ({source}) {text}\n"
    INBOX.parent.mkdir(parents=True, exist_ok=True)
    with INBOX.open("a", encoding="utf-8") as f:
        f.write(line)
    return line


@app.get("/c", response_class=HTMLResponse)
def page(t: str = ""):
    if t != TOKEN:
        return HTMLResponse("unauthorized — append ?t=TOKEN", status_code=401)
    return HTMLResponse(f"""<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>capture</title>
<link rel="manifest" href="/c/manifest.json?t={t}">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="capture">
<style>
:root{{color-scheme:dark}}
*{{box-sizing:border-box;font-family:-apple-system,system-ui,sans-serif}}
body{{margin:0;padding:1rem;background:#0a0a0a;color:#eee;display:flex;flex-direction:column;height:100vh}}
textarea{{flex:1;width:100%;padding:1rem;font-size:1.1rem;background:#1a1a1a;color:#eee;border:1px solid #333;border-radius:8px;resize:none;font-family:inherit}}
button{{margin-top:.75rem;padding:1rem;font-size:1.1rem;background:#2563eb;color:#fff;border:none;border-radius:8px;cursor:pointer}}
button:active{{background:#1d4ed8}}
#s{{margin-top:.5rem;text-align:center;color:#888;font-size:.9rem;min-height:1.2em}}
</style></head><body>
<textarea id="t" autofocus placeholder="capture..."></textarea>
<button onclick="send()">send</button>
<div id="s"></div>
<script>
const t='{t}';
async function send(){{
  const ta=document.getElementById('t'),s=document.getElementById('s');
  const v=ta.value.trim();if(!v)return;
  s.textContent='sending...';
  try{{
    const r=await fetch('/c',{{method:'POST',headers:{{'Authorization':'Bearer '+t,'Content-Type':'application/json'}},body:JSON.stringify({{text:v,source:'pwa'}})}});
    if(r.ok){{ta.value='';s.textContent='✓ '+new Date().toLocaleTimeString();ta.focus()}}
    else s.textContent='✗ '+r.status;
  }}catch(e){{s.textContent='✗ '+e.message}}
}}
document.addEventListener('keydown',e=>{{if((e.metaKey||e.ctrlKey)&&e.key==='Enter')send()}});
</script></body></html>""")


@app.get("/c/manifest.json")
def manifest(t: str = ""):
    if t != TOKEN:
        raise HTTPException(401)
    return JSONResponse({
        "name": "Capture",
        "short_name": "capture",
        "start_url": f"/c?t={t}",
        "display": "standalone",
        "background_color": "#0a0a0a",
        "theme_color": "#0a0a0a",
        "icons": [],
    })


@app.post("/c")
async def capture(request: Request, authorization: str | None = Header(None)):
    token = (authorization or "").removeprefix("Bearer ").strip()
    _check(token)
    body = await request.json()
    line = _append(body.get("text", ""), body.get("source", "api"))
    return {"ok": True, "line": line}
