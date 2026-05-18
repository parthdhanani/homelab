# skill-library

A modular, searchable skill system for [Claude Code](https://claude.ai/code). Skills are domain-specific prompt packages — each adds expert-level behavior for a specific area (VPS infra, SCORM/LMS, Docker, PKM, AI agents, etc.).

## Concept

`/sk <query>` → fuzzy-search the library → Claude loads the matching skill → domain knowledge is active for the conversation.

Skills are structured directories:

```
skill-name/
  SKILL.md          # frontmatter (name, description, trigger, tools) + prompt body
  references/       # optional reference docs loaded alongside
  evals.json        # optional eval cases
  sources.yaml      # optional upstream sources
```

## Structure

```
skill-library/
  .router/          # indexer, search, import, sync tooling (Python + bash)
  custom/           # 52 personal skills (vps-infra, graphify, pkm, scorm-xapi, …)
  .sources.json     # registry of external skill repos (superpowers, AbsolutelySkilled, etc.)
```

The `.router/` scripts handle:
- **indexer.py** — scans all SKILL.md files, extracts metadata, writes `index.json`
- **search.py** — TF-IDF-style ranked search over the index; auto-rebuilds if stale
- **skimport.py** — imports a skill from any GitHub URL (clones, copies, registers)
- **sync.py** — re-pulls all `.sources.json` entries to update external skills
- **build-index.sh** — orchestrates indexer + optional sync; atomic write with locking

## Usage

```bash
# Search
python3 .router/search.py "docker nginx"

# List all skills by category
python3 .router/search.py --list

# Import a skill from GitHub
python3 .router/skimport.py https://github.com/user/repo/tree/main/skills/my-skill

# Rebuild index
bash .router/build-index.sh

# Rebuild + pull upstream updates
bash .router/build-index.sh --update
```

Inside Claude Code, these are wired as `/sk` slash commands.

## Custom Skills (52)

| Category | Skills |
|---|---|
| Infra/VPS | `vps-infra`, `vps-health`, `containers-audit`, `docker-patterns`, `health` |
| AI/PKM | `graphify`, `pkm`, `pkm-enrich`, `notebooklm`, `research`, `analyze`, `brief` |
| Dev | `skill-forge`, `skill-creator`, `autonomous-loops`, `context-budget`, `model-routing` |
| LMS/SCORM | `scorm-xapi`, `lms-help`, `js-debug` |
| UI/Frontend | `ui-ux-pro-max`, `impeccable-frontend-design`, `impeccable-impeccable`, `playwright-pro` |
| Writing/Docs | `readme-generator`, `changelog-generator`, `content-research-writer`, `prompt-engineer` |
| Agents | `mcp-builder`, `dispatching-parallel-agents`, `subagent-driven-development`, `agent-introspection-debugging` |
| Tools | `ref`, `image-gen`, `llm-cost-optimizer`, `a11y-audit`, `domain-name-brainstormer` |

## External Sources

Registered in `.sources.json` — pulled via `build-index.sh --update`:

- [AbsolutelySkilled](https://github.com/AbsolutelySkilled/AbsolutelySkilled) — broad skill collection (pinned to commit `4ff890c`)
- [obra/superpowers](https://github.com/obra/superpowers) — dev methodology skills
- [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills) — community skills

## Installation

```bash
# Clone to ~/.claude/skill-library
git clone https://github.com/parthdhanani/dotfiles ~/.claude/dotfiles
cp -r ~/.claude/dotfiles/skill-library ~/.claude/skill-library

# Build initial index
bash ~/.claude/skill-library/.router/build-index.sh
```

Wire `/sk` in your Claude Code `settings.json` as a skill pointing to `search.py`.
