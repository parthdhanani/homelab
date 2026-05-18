---
name: model-routing
description: "Auto-select the right Claude model based on task type. Invoke when the user asks which model to use, or proactively suggest a switch when the current task clearly over/under-uses the active model."
trigger: /model-route
---

# /model-route

Route tasks to the correct model. Suggest switching with the exact `/model <name>` command.

## Routing Table

| Task signal | Model | Why |
|---|---|---|
| Quick lookup, single-file read, grep, trivial Q&A | **Haiku** | Fast, cheap, no reasoning needed |
| Code writing, debugging, Docker/nginx/iptables edits, multi-file changes | **Sonnet** | Default workhorse — best cost/quality ratio |
| Architecture decisions, infra planning, complex multi-step reasoning, security design, anything spanning >3 systems | **Opus** | Needed for depth; use sparingly |

## Signals that warrant Opus
- Designing a new container topology
- Planning a migration (OpenList, autossh, llama.cpp setup)
- Multi-constraint problems (CF tunnel routing + iptables + Docker network simultaneously)
- Reviewing/auditing the full Cryptex stack

## Signals that warrant Haiku
- "What's the value of X in this file?"
- Single grep/lookup task
- Summarising a log
- Any task completable in one tool call

## Default
Stay on **Sonnet** unless a signal above clearly applies. Don't switch for "moderately complex" — Sonnet handles it.

## Usage
When invoked, assess the current task and output one line:
`Suggest: /model <haiku|sonnet|opus> — <one-sentence reason>`

Do not switch the model yourself — suggest it and let the user confirm.
