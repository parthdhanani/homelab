---
description: Skill library — search, load, import, browse, or run diagnostics. /sk [query] · /sk list [cat] · /sk import [url] · /sk doctor · /sk build
---

# /sk — $ARGUMENTS

## Intent aliases (resolve before search)

| Prefix | Routes to |
|--------|-----------|
| `fix`, `debug` | `systematic-debugging` |
| `verify`, `check` | `verification-before-completion` |
| `review` | `analyze` + `receiving-code-review` |
| `plan` | `writing-plans` |
| `test` | `test-driven-development` |
| `refactor` | `refactoring-patterns` |

## Subcommands

**`list [cat]`**
```bash
python3 ~/.claude/skill-library/.router/search.py --list [--cat CAT]
```
Categories: scorm infra dev ai test security ui tools seo data mobile product writing business custom

**`import [url]`**
```bash
python3 ~/.claude/skill-library/.router/skimport.py "[url]"
```

**`doctor`** — `bash ~/.claude/commands/skdoctor.sh`

**`build`** — `bash ~/.claude/skill-library/.router/build-index.sh`

**`https://...`** — `python3 ~/.claude/skill-library/.router/skimport.py "$ARGUMENTS"`

## Default: search and load

```bash
python3 ~/.claude/skill-library/.router/search.py "$ARGUMENTS"
echo "$ARGUMENTS" > /tmp/.sk-last-query
```

No match → "No skill for '[query]'. Try `/sk import [url]`."
Match → `cat ~/.claude/skill-library/[dir]/SKILL.md` — read fully, apply. Up to 3 HIGH matches.
