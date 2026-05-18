# Skill Building Guide
*Preserved from skill-builder — reference when creating or auditing skills manually.*

## Discovery Interview (run before writing anything)

Six rounds. One topic per round. Move forward only after user answers.

**Round 1 — Goal & Name**
- What does this skill do? What problem does it solve?
- What should we call it? (lowercase, hyphens, max 64 chars)

**Round 2 — Trigger**
- What would someone say to trigger this? (2-3 natural phrases)
- User-only `/slash-command`, auto-invocable, or both?
- Does it accept arguments?

**Round 3 — Step-by-Step Process**
- Walk through from trigger to output, step by step
- For each step: Claude does it directly, or delegates to subagent/script?
- Conversational or fire-and-forget?

**Round 4 — Inputs, Outputs & Dependencies**
- What inputs does it need? (files, APIs, user args, live data)
- What does it produce? Where do outputs go?
- External APIs, scripts, tools needed?

**Round 5 — Guardrails & Edge Cases**
- What could go wrong? Common failure modes?
- What should this NOT do? Hard boundaries?
- Cost concerns? (API calls, generation costs)
- Ordering/dependency constraints?

**Round 6 — Confirm**
Summarise back to user:
```
## Skill Summary: [name]
Goal: [one sentence]
Trigger: `/name` + [natural phrases]
Arguments: [what it accepts, or "none"]
Process: 1. [step] 2. [step] ...
Inputs / Outputs / Dependencies / Guardrails
```
Only proceed once user confirms.

---

## Build Phase

**Step 1: Skill type**
- **Task skill** — step-by-step instructions for a specific action (most common)
- **Reference skill** — knowledge Claude applies to current work without performing an action

**Step 2: Frontmatter**
Only set fields you actually need:
- `name` — matches directory name
- `description` — "Use when someone asks to [action]..." Include natural trigger keywords
- `disable-model-invocation: true` — if skill has side effects (API calls, file gen, costs money)
- `argument-hint` — if skill accepts arguments (shows in `/` menu)
- `context: fork` + `agent` — if self-contained, doesn't need conversation history
- `model` — only if specific model capability required
- `allowed-tools` — if skill needs restricted tool access

**Step 3: Content structure**
1. Context (files to read, APIs, reference material)
2. Step-by-step workflow (numbered, exact)
3. Output format (templates, file paths, structure)
4. Notes (edge cases, constraints, what NOT to do)

Rules: Under 500 lines. Move detailed reference to `references/`. Use `$ARGUMENTS`/`$N` for dynamic input. Specify all file paths.

**Step 4: Supporting files**
Add to `references/` or `scripts/`. Reference from SKILL.md. Not loaded automatically — load only when needed.

**Step 5: Document in CLAUDE.md**
Skill name, trigger phrases, what it does, output location.

**Step 6: Test**
- Natural language trigger — does Claude load the skill?
- Direct `/skill-name` invocation — do `$ARGUMENTS` substitute correctly?
- Edge cases — missing args, unusual input, empty input

---

## Audit Checklist

**Frontmatter**
- [ ] `name` matches directory
- [ ] `description` uses natural keywords actually said when needing this
- [ ] `disable-model-invocation: true` set if side effects exist
- [ ] `argument-hint` set if skill accepts arguments
- [ ] No unnecessary fields

**Content**
- [ ] Under 500 lines
- [ ] Numbered steps, each tells Claude exactly what to do
- [ ] Output format specified with templates
- [ ] All file paths documented
- [ ] Notes cover edge cases and what NOT to do

**Integration**
- [ ] Documented in CLAUDE.md
- [ ] Supporting files referenced from SKILL.md (not orphaned)
- [ ] API keys in env vars, never hardcoded

**Quality**
- [ ] Actionable, not abstract
- [ ] Doesn't duplicate info from CLAUDE.md or other skills
- [ ] Delegates to subagents for verbose/self-contained work

---

## Conventions
- Skills: `~/.claude/skills/[name]/SKILL.md`
- Description format: "Use when someone asks to [action], [action], or [action]."
- Supporting files: `references/` for docs, `scripts/` for executable code, `assets/` for templates
