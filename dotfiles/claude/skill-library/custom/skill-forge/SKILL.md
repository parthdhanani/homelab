---
name: skill-forge
date: 2026-03-19
description: >
  System management: Internal tool for adding and updating skills. 
  Triggers on explicit system commands: "sys:forge", "add-skill-to-library", 
  "import-external-skill". Avoids general coding queries.
---

# Skill Forge

## When to use this
ONLY when explicitly asked to manage the skill library or import from a URL.
Triggered by: `sys:forge` or "Add this URL to my skills".

## Capabilities
1.  **URL Parsing:** Use `python3 ~/.claude/skill-library/.router/skimport.py <URL>` to import a skill from GitHub.
2.  **Conflict Resolution:** Before finalizing a skill, run `python3 ~/.claude/skill-library/.router/search.py "<keywords>"` to check for existing similar skills.
3.  **Audit:** Use the `claude-health` logic to check for prose bloat, security risks, and technical correctness.
4.  **Formatting:** Ensure all skills follow the `SKILL-template.md` structure with Gotchas and Concrete Patterns.

## Workflow for Claude
1.  **Detect Intent:** If the user provides a URL or says "create a skill for...", load this skill.
2.  **Check Library:** Run `search.py` on the topic. If a match > 1.0 exists, present it to the user and ask to **Merge** or **Improvise**.
3.  **Fetch/Create:**
    *   If URL: Run `skimport.py`.
    *   If Text: Use the `skill-creator` logic to draft the `SKILL.md`.
4.  **Audit:** Run a semantic audit using `claude-health` principles.
5.  **Finalize:** Save to `~/.claude/skill-library/custom/<name>/SKILL.md`.
6.  **Refresh:** Remind the user that the index is updated automatically.

## References
- `~/.claude/templates/SKILL-template.md`
- `~/.claude/skill-library/custom/claude-health/SKILL.md`
