# Free AI Stack — Implementation Plan
> Created: 2026-04-28

## Goal

Build a free AI fallback system that:
- Lets you use Claude Code CLI (`fcc` alias) without an Anthropic subscription
- Provides a stable, multi-provider backend that survives individual provider outages
- Keeps the existing `claude` setup completely untouched
- Is future-proof for local model expansion (Ollama, llama.cpp)

---

## Honest Limitations (read before building)

- **Quality gap is real.** Free models (Qwen 3, DeepSeek V3, Llama 4) are good but not Claude-level for complex infra work. Use this for dumb tasks. Use real Claude for hard problems.
- **Claude Code routing is not smart.** It doesn't analyse query complexity and pick a model. It uses MODEL_SONNET for ~90% of requests. Haiku/Opus mapping exists but rarely triggers automatically.
- **Rate limits exist.** Free tiers on all providers cap at requests/day. Heavy use will hit walls. DeepSeek ($5 top-up) is the safety net.
- **OpenRouter fails.** Deliberately excluded as primary. Used only as overflow in freellmapi.

---

## Architecture

```
You type: fcc
          │
          ▼
  Claude Code CLI (/home/ubuntu/.local/bin/claude)
  with ANTHROPIC_BASE_URL → cryptex-freecc
          │
          ▼
  ┌─────────────────────────────────┐
  │  cryptex-freecc (172.18.0.47)  │
  │  free-claude-code proxy         │
  │  Port 8082                      │
  │  Anthropic API → OpenAI API     │
  │  Maps Haiku/Sonnet/Opus tiers   │
  └─────────────────┬───────────────┘
                    │ points at freellmapi
                    ▼
  ┌─────────────────────────────────┐
  │ cryptex-freellmapi (172.18.0.48)│
  │  Port 3001                      │
  │  14 providers, failover,        │
  │  rate tracking, admin UI        │
  └──────────┬──────────────────────┘
             │ routes to whichever is alive
      ┌──────┴───────┐
      ▼              ▼
  NVIDIA NIM      Groq
  Cerebras        Cohere
  Google Gemini   OpenRouter (overflow)
  + 9 more        DeepSeek (freecc fallback)

─────────────────────────────────────────────────

You type: claude          → unchanged, hits Anthropic
You type: fcc             → hits free stack above
n8n workflow LLM call     → http://cryptex-freellmapi:3001/v1 (OpenAI-compatible)
```

---

## Components

### 1. cryptex-freecc
- **Repo:** github.com/Alishahryar1/free-claude-code
- **Role:** Translates Claude Code's Anthropic Messages API calls into OpenAI-compatible calls. Maps model tiers to specific free models.
- **Port:** 8082 (internal, cryptex_net only)
- **IP:** 172.18.0.47

**Model mapping (what to set):**
```
MODEL_HAIKU  → nvidia_nim/fast-model     # background tool calls
MODEL_SONNET → nvidia_nim/strong-model   # main loop (90% of requests)
MODEL_OPUS   → nvidia_nim/best-model     # explicit --model opus only
MODEL        → deepseek/deepseek-chat    # ultimate fallback
```
All nvidia_nim calls route to freellmapi's endpoint (not real NVIDIA NIM directly).
freellmapi handles actual provider selection and failover.

**Local expansion (future, zero code change):**
```
MODEL_SONNET=ollama/llama3.3        # point any tier at local Ollama
MODEL_HAIKU=llamacpp/phi-4          # or llama.cpp
```

### 2. cryptex-freellmapi
- **Repo:** github.com/tashfeenahmed/freellmapi
- **Role:** Unified OpenAI-compatible endpoint across 14 providers. Tracks rate limits per provider/key, auto-fails over when one is exhausted or down.
- **Port:** 3001 (admin dashboard + API, internal)
- **IP:** 172.18.0.48
- **Admin dashboard:** freellmapi.psidex.com (Zero Trust protected)

---

## API Keys Required

Get these before building. All free-tier accounts, no credit card required except DeepSeek.

| Provider | Sign-up URL | Used in | Notes |
|---|---|---|---|
| NVIDIA NIM | build.nvidia.com/settings/api-keys | freellmapi | Free credits on signup |
| Groq | console.groq.com/keys | freellmapi | Fast inference, generous free tier |
| Cerebras | cloud.cerebras.ai | freellmapi | Very fast, free tier |
| OpenRouter | openrouter.ai/keys | freellmapi | Overflow only, 14-day free credits |
| DeepSeek | platform.deepseek.com/api_keys | freecc .env | Top up $5 — lasts months at light use |
| Google Gemini | Already in .env | freellmapi | Reuse existing GEMINI_API_KEY |

**freellmapi keys** are added via its admin dashboard after deploy (not .env).
**DeepSeek key** goes into Cryptex `.env` as `DEEPSEEK_API_KEY`.

---

## Implementation Steps

### Phase 1 — Build cryptex-freellmapi

1. Write `dockerfiles/freellmapi.Dockerfile`
   - Node.js 20 Alpine base
   - Clone repo, build frontend, build server
   - Serve on port 3001
   - Needs `ENCRYPTION_KEY` env var (generate with `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`)

2. Add service to `docker-compose.yml`
   - IP: 172.18.0.48
   - Memory: 512M
   - Restart: unless-stopped
   - Healthcheck: `nc -z 127.0.0.1 3001`

3. Add to nginx — `freellmapi.psidex.com` → `cryptex-freellmapi:3001`

4. Add CF tunnel route + Zero Trust policy (admin only)

5. Deploy, open dashboard, add API keys for all providers

### Phase 2 — Build cryptex-freecc

1. Write `dockerfiles/freecc.Dockerfile`
   - Python 3.13-slim base (3.14 not yet in stable slim images)
   - Install uv
   - Clone repo, `uv sync`
   - Expose 8082
   - CMD: `uv run uvicorn server:app --host 0.0.0.0 --port 8082`

2. Add service to `docker-compose.yml`
   - IP: 172.18.0.47
   - Memory: 256M
   - Environment: load from .env
   - `NVIDIA_NIM_BASE_URL=http://cryptex-freellmapi:3001/v1` (routes through freellmapi)
   - `NVIDIA_NIM_API_KEY=internal` (freellmapi handles real auth)
   - `DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}` (direct fallback)
   - `ANTHROPIC_AUTH_TOKEN=${FCC_AUTH_TOKEN}` (any secret string)

3. Add to `.env`:
   ```
   DEEPSEEK_API_KEY=
   FCC_AUTH_TOKEN=          # random secret, e.g. "freecc-xyz"
   FREELLMAPI_ENCRYPTION_KEY=  # generated hex string
   MODEL_HAIKU=nvidia_nim/fast-model
   MODEL_SONNET=nvidia_nim/strong-model
   MODEL_OPUS=nvidia_nim/best-model
   MODEL=deepseek/deepseek-chat
   ```

### Phase 3 — Alias + access

1. Add to `/home/ubuntu/.bashrc`:
   ```bash
   alias fcc='ANTHROPIC_AUTH_TOKEN=${FCC_AUTH_TOKEN} ANTHROPIC_BASE_URL=http://172.18.0.47:8082 claude'
   ```

2. `source ~/.bashrc`

3. Test: `fcc --version` then `fcc "what is 2+2"`

### Phase 4 — Model selection (after deploy)

After freellmapi is running and providers are added via dashboard:
1. Open freellmapi admin → check which providers are active
2. Pick models for each tier in `.env` (MODEL_HAIKU, MODEL_SONNET, MODEL_OPUS)
3. Restart freecc: `docker compose restart freecc`

**Recommended model assignments (update after checking freellmapi dashboard):**
- MODEL_HAIKU: fastest available (Groq Llama 4 Scout or Cerebras fast model)
- MODEL_SONNET: best balanced (DeepSeek V3 or Qwen 3 32B via NVIDIA)
- MODEL_OPUS: strongest available (Qwen 3 235B or NVIDIA Kimi K2)

---

## File Changes Summary

| File | Change |
|---|---|
| `dockerfiles/freellmapi.Dockerfile` | New |
| `dockerfiles/freecc.Dockerfile` | New |
| `docker-compose.yml` | Add 2 services |
| `configs/nginx/` | Add freellmapi.conf |
| `.env` | Add DEEPSEEK_API_KEY, FCC_AUTH_TOKEN, FREELLMAPI_ENCRYPTION_KEY, MODEL_* vars |
| `/home/ubuntu/.bashrc` | Add fcc alias |
| `README.md` (AI_Space) | Add new containers to inventory |

---

## Network Layout (additions)

```
172.18.0.47  cryptex-freecc       (free-claude-code proxy)
172.18.0.48  cryptex-freellmapi   (14-provider aggregator)
```

Check existing assignments before deploying:
```bash
grep "172.18.0.4[5-9]\|172.18.0.5" /opt/cryptex/docker-compose.yml
```

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| freecc Python 3.14 req | Use 3.13, test compatibility — code is straightforward FastAPI |
| freellmapi dashboard key management | Keys in dashboard survive container restart (SQLite volume mount) |
| freellmapi repo abandoned/breaking | Pin to specific git commit in Dockerfile |
| Provider rate limits | freellmapi auto-routes to next provider; DeepSeek is paid fallback |
| freecc → freellmapi chain failure | Both containers have health checks; if freecc is down, `claude` still works |

---

## What This Does NOT Do

- **Does not replace Claude for hard tasks.** Real infra debugging, complex multi-file edits, architecture decisions — use `claude`.
- **Does not auto-route by query complexity.** You get MODEL_SONNET for 90% of requests regardless of how simple the task is. For dumb tasks, `fcc --model haiku` forces the cheaper path.
- **Does not provide persistent chat.** Claude Code is stateless per session. Same as real Claude.

---

## Status

- [ ] API keys collected (NVIDIA NIM, Groq, Cerebras, OpenRouter, DeepSeek)
- [ ] freellmapi Dockerfile written
- [ ] freecc Dockerfile written
- [ ] Compose services added
- [ ] Nginx config added
- [ ] CF tunnel + ZT policy added
- [ ] freellmapi deployed + providers added via dashboard
- [ ] freecc deployed + tested
- [ ] fcc alias added to .bashrc
- [ ] Model tiers configured and tested
