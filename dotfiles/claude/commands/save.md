---
description: Capture project decisions, status, or next steps into project memory
---

# /save — $ARGUMENTS

```bash
MEM_DIR=".claude"
MEM_FILE="${MEM_DIR}/MEMORY.md"
[ ! -d "$MEM_DIR" ] && mkdir -p "$MEM_DIR"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
SLUG=$(echo "$ARGUMENTS" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-40)
printf '\n## [%s] %s\n**What:** %s\n**Decision:** \n**Rationale:** \n**Tools:** claude-alone\n**Contract:** none\n**Open:** none\n' \
  "$TIMESTAMP" "$SLUG" "$ARGUMENTS" >> "$MEM_FILE"
echo "✓ ${MEM_FILE}"
```

Then Edit the file to fill: Decision, Rationale, Tools (claude-alone | gemini-map | gemini-search | nlm:[notebook]), Contract (.gemini-plan.md deleted | none), Open.
