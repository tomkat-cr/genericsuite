# CLAUDE.md

This file provides guidance to AI Coding Assistants (Claude Code, Gemini CLI, Cursor, Antigravity, etc.) when working with code in this repository.

## Repository Structure

This is a monorepo orchestration layer (Superproject) of the GenericSuite ecosystem. All 14 packages live under `packages/` as **git submodules**, each pointing to an independent repository on GitHub (`github.com/tomkat-cr/<package-name>`). Every package has its own `CLAUDE.md` with package-specific guidance — read those when working inside a specific package.

```
packages/
  genericsuite-fe            # React component library (core UI + JSON-driven CRUD)
  genericsuite-fe-ai         # React AI chatbot components
  genericsuite-fe-scripts    # Bash deployment/dev scripts for frontend projects
  genericsuite-be            # Python backend library (FastAPI/Flask/Chalice/MCP)
  genericsuite-be-ai         # Python AI features (LLMs, embeddings, vision, audio)
  genericsuite-be-scripts    # Bash deployment/dev scripts for backend projects
  genericsuite-codegen       # FastAPI + React + MCP server for AI-powered code generation
  genericsuite-app-maker     # Streamlit + FastAPI AI development assistant (GSAM)
  genericsuite-asdt-be       # Multi-agent AI software dev team (CrewAI/CamelAI)
  genericsuite-skills        # Claude AI skills/slash commands collection
  genericsuite-mobile        # Flutter core package + app template
  genericsuite-basecamp      # Documentation hub + example apps (MkDocs)
  genericsuite-basecamp-app  # Flutter documentation viewer app
  genericsuite-gitops        # DevOps/IaC automation (Bash, Docker, Kubernetes)
```

## Monorepo Commands

```bash
# Add all packages as submodules and pull latest on BRANCH (default: develop)
make update-packages
# Or directly:
BRANCH=main SUBMODULE=1 GIT_USER=tomkat-cr ./scripts/update_packages.sh

# Clone instead of submodule-add (set SUBMODULE=0):
SUBMODULE=0 ./scripts/update_packages.sh
```

## Prerequisites

- Node.js v18+
- Python v3.10+
- Flutter v3.10+
- Docker & Docker Compose

## Cross-Package Architecture

### JSON-Driven Configuration

The central design principle across `genericsuite-fe`, `genericsuite-be`, and `genericsuite-mobile` is that **all CRUD entities, menus, and DB schemas are defined in JSON — no code changes needed per entity**. The Generic CRUD Editor (GCE) on the frontend and `GenericDbHelper`/`GenericEndpointHelper` on the backend both consume the same JSON configuration files.

### Backend Framework Abstraction

`genericsuite-be` exposes a single Python API that runs unchanged on FastAPI, Flask, Chalice, or as an MCP server. Framework-specific adapters live in `fastapilib/`, `flasklib/`, `chalicelib/`, `mcplib/`. When building new backend features, write against the abstraction layer — not a specific framework.

### Database Abstraction

`genericsuite-be` translates MongoDB-style query operators (`$eq`, `$in`, `$regex`, etc.) to native queries for MongoDB, DynamoDB, PostgreSQL, MySQL, and Supabase via `DbAbstractor` (factory pattern). All backend code uses MongoDB query syntax regardless of the underlying engine.

### Standard Result Shape

Every backend function returns:
```python
{"error": bool, "error_message": str | None, "resultset": Any}
```
Frontend code and tests expect this shape. Do not deviate from it.

### Environment-Based Configuration

All packages use stage-specific `.env` files (`dev`, `qa`, `staging`, `prod`). Secrets are never hardcoded. Backend packages use Poetry; frontend packages use npm. The `genericsuite-be-scripts` and `genericsuite-fe-scripts` packages provide the bash tooling that reads these `.env` files for deployments.

### AI Layer

`genericsuite-be-ai` is framework-agnostic and sits on top of `genericsuite-be`. It uses LangChain LCEL + ReAct as its default pipeline and supports 30+ LLM providers via `ai_langchain_models.py`. Embeddings support 7 providers via `ai_embeddings.py`. SSRF and LFI guards (`is_safe_url()`, `is_safe_local_path()`) must wrap all AI-generated URLs and file paths.

### Frontend AI Components

`genericsuite-fe-ai` depends on `genericsuite-fe` as a peer dependency and reuses its `renderMarkdownContent()` helper. It never uses `dangerouslySetInnerHTML`.

### Mobile

`genericsuite-mobile` mirrors the JSON-driven config pattern using asset files (`assets/stage.json`, `assets/config-{stage}.json`, `assets/backend/*.json`, `assets/frontend/*.json`). The `CrudEditor` singleton and JWT-aware HTTP client are the extension points for new entities.

## Security Patterns (Cross-Package)

- Passwords hashed with **scrypt** (not bcrypt/MD5)
- JWT tokens (HS256) with expiry enforced
- SQL injection prevention: parameterized queries + identifier quoting in `genericsuite-be`
- Log injection prevention: sanitize newlines before logging
- SAST scan (Snyk) required before publishing any package to PyPI/npm

## Non-Negotiable Rules

- **Shell**: always use `bash` (macOS/Linux only; use WSL on Windows)
- **Backend results**: every function must return `{"error": bool, "error_message": str | None, "resultset": Any}`
- **Passwords**: scrypt only (never bcrypt or MD5)
- **Secrets**: never hardcode; use stage-specific `.env` files
- **SQL injection**: parameterized queries + identifier quoting in `genericsuite-be`
- **Submodules**: all packages live under `packages/` — work inside the relevant submodule, not at the root
- **Lint before commit**: run the project linter before staging any changes

## Development environment

### Package Manager

- Backend: `poetry`
- Frontend: `npm` (never yarn or pnpm unless the sub-package explicitly uses it)

## Skills

Prefer invoking skills over reading long rules. Skills are only loaded when needed.

| Trigger | Skill | When to invoke |
|---------|-------|----------------|
| `/graphify` | `graphify` | Codebase exploration, knowledge graph, architecture questions |
| `/init-claude-md` | `init-claude-md` | Initialize a new CLAUDE.md file (or update an existing one) for a codebase |
| `/openspec-explore` | `openspec-explore` | Thinking through a problem before writing code |
| `/openspec-propose` | `openspec-propose` | Drafting a full change proposal with design + tasks |
| `/openspec-apply-change` | `openspec-apply-change` | Implementing tasks from an existing OpenSpec change |
| `/openspec-archive-change` | `openspec-archive-change` | Finalising and archiving a completed change |

Skills live in `.ai/skills/` (source of truth); symlinked under `.agents/skills/`, `.claude/skills/`, `.codex/skills/`, `.gemini/skills/`, and `.devin/skills/`.

## Documentation

- Full docs: https://genericsuite.carlosjramirez.com
- Mirror: https://genericsuite.readthedocs.io

## Important Notes

- The files `AGENTS.md`, `GEMINI.md`, etc. (if present) have only a referece to `@CLAUDE.md` — edit only `CLAUDE.md`.
- Skills, commands, rules, and sub-agents are located in the `.claude/`, `.codex/`, `.cursor/`, `.gemini/`, `.agents/`, `.devin/` directories, and are symlinked to the corresponding directories in the submodules and the superproject from `.ai` directory.
