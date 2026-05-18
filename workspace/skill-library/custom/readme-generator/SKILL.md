---
name: readme-generator
description: Generate a comprehensive README.md by analyzing project structure, dependencies, and code patterns. Detects language, frameworks, test setup, CI/CD. Produces professional documentation with correct sections.
allowed-tools: ["Read", "Glob", "Grep", "Write"]
---

# README Generator

Generate a professional README.md by analyzing the project.

## Steps

### 1. Discover project
- Glob for config files: `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `composer.json`
- Identify language(s), framework, test setup, CI/CD (`.github/workflows/`)
- Read LICENSE file if present

### 2. Analyse
Determine:
- Project type: library / app / CLI / API
- Primary language and dependencies
- Build + test commands
- Existing README (offer to merge, not overwrite blindly)

### 3. Generate README

**Always include:**
- Title + one-line description
- Installation
- Usage with code examples
- License

**Include if present:**
- Prerequisites
- Development setup
- Testing (`npm test`, `pytest`, etc.)
- Contributing
- API docs (for libraries)
- Badges (CI status, npm version, etc. — only if CI/CD detected)

**Style:**
- Active voice, concise
- Proper syntax-highlighted code blocks
- No emoji unless user requests

### 4. Deliver
Show the generated README. Ask before writing to file. If `README.md` exists, warn before overwriting.

## Project type reference

| Type | Key files | Focus |
|------|-----------|-------|
| Python | `pyproject.toml`, `setup.py`, `requirements.txt` | pip install, venv, pytest |
| Node.js | `package.json` | npm/yarn install, scripts |
| Rust | `Cargo.toml` | cargo build/test |
| Go | `go.mod` | go get, go test |

## Error handling
- No project files: ask user to confirm working directory
- Multiple languages: generate sections for each
- Missing info: use TODO placeholders
