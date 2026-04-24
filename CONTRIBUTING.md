# Contributing to GenericSuite

Thank you for your interest in contributing to GenericSuite! This document explains how to get started, how the repository is organized, and the conventions you must follow.

## Table of Contents

- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Setting Up the Development Environment](#setting-up-the-development-environment)
- [Making Changes](#making-changes)
- [Architecture Conventions](#architecture-conventions)
- [Security Requirements](#security-requirements)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Code of Conduct](#code-of-conduct)

---

## Repository Structure

GenericSuite is a monorepo orchestration layer. All 14 packages live under `packages/` as **git submodules**, each pointing to an independent GitHub repository under `github.com/tomkat-cr/<package-name>`.

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
  genericsuite-asdt-be       # Multi-agent AI software dev team (CrewAI/CamelAI/LangGraph)
  genericsuite-skills        # Claude AI skills/slash commands collection
  genericsuite-mobile        # Flutter core package + app template
  genericsuite-basecamp      # Documentation hub + example apps (MkDocs)
  genericsuite-basecamp-app  # Flutter documentation viewer app
  genericsuite-gitops        # DevOps/IaC automation (Bash, Docker, Kubernetes)
```

Each package has its own `CLAUDE.md` with package-specific guidance. **Read the relevant `CLAUDE.md` before working inside a specific package.**

Contributions to individual packages should be submitted as pull requests to their respective repositories. Contributions to the monorepo itself (scripts, top-level config, documentation) are submitted here.

---

## Prerequisites

Make sure the following tools are installed before starting:

- **Node.js** v18+
- **Python** v3.10+
- **Flutter** v3.10+
- **Docker** and **Docker Compose**
- **bash** (always use bash for shell scripts — this project targets macOS and Linux; Windows users must use WSL)

---

## Setting Up the Development Environment

1. **Clone the repository:**
   ```bash
   git clone https://github.com/tomkat-cr/genericsuite.git
   cd genericsuite
   ```

2. **Pull all package submodules** (defaults to the `develop` branch):
   ```bash
   make update-packages
   # Or directly:
   BRANCH=develop SUBMODULE=1 GIT_USER=tomkat-cr ./scripts/update_packages.sh
   ```

Backend packages use **Poetry** for dependency management. Frontend packages use **npm**. Stage-specific configuration lives in `.env` files (e.g., `.env.dev`, `.env.qa`, `.env.staging`, `.env.prod`). **Never hardcode secrets.**

---

## Making Changes

- Work on a feature branch created from `develop`.
- Keep changes focused: one concern per pull request.
- Write tests for new behavior.
- Run the existing test suite before opening a PR.
- All shell scripts must be written in **bash** and be compatible with macOS and Linux.

---

## Architecture Conventions

Follow these conventions across all packages to maintain consistency.

### JSON-Driven Configuration

All CRUD entities, menus, and DB schemas are defined in JSON — **no code changes needed per entity**. The Generic CRUD Editor (GCE) on the frontend and `GenericDbHelper`/`GenericEndpointHelper` on the backend both consume the same JSON configuration files. New entities must follow this pattern.

### Backend Framework Abstraction

`genericsuite-be` exposes a single Python API that runs unchanged on FastAPI, Flask, Chalice, or as an MCP server. Framework-specific adapters live in `fastapilib/`, `flasklib/`, `chalicelib/`, `mcplib/`. **Write against the abstraction layer, not a specific framework.**

### Database Abstraction

All backend code uses MongoDB query syntax (`$eq`, `$in`, `$regex`, etc.) regardless of the underlying engine. The `DbAbstractor` factory translates these operators to MongoDB, DynamoDB, PostgreSQL, MySQL, and Supabase at runtime. Do not write engine-specific queries.

### Standard Result Shape

Every backend function must return:
```python
{"error": bool, "error_message": str | None, "resultset": Any}
```
Frontend code and tests depend on this shape. Do not deviate from it.

### AI Layer

New AI features in `genericsuite-be-ai` must be framework-agnostic and built on top of `genericsuite-be`. Use LangChain LCEL + ReAct as the default pipeline. All AI-generated URLs and file paths must be wrapped with `is_safe_url()` and `is_safe_local_path()` to prevent SSRF and LFI vulnerabilities.

### Frontend AI Components

`genericsuite-fe-ai` must never use `dangerouslySetInnerHTML`. Use the `renderMarkdownContent()` helper from `genericsuite-fe` instead.

### Mobile

New mobile entities follow the JSON-driven config pattern using asset files (`assets/stage.json`, `assets/config-{stage}.json`, `assets/backend/*.json`, `assets/frontend/*.json`). The extension points are the `CrudEditor` singleton and the JWT-aware HTTP client.

---

## Security Requirements

All contributions must comply with the following security patterns:

- **Passwords**: hash with **scrypt** (not bcrypt or MD5).
- **Authentication**: use JWT tokens (HS256) with expiry enforced.
- **SQL injection**: use parameterized queries and identifier quoting (handled by `genericsuite-be`).
- **Log injection**: sanitize newlines before writing to logs.
- **SAST scan**: a Snyk scan is required before publishing any package to PyPI or npm.
- **Secrets**: never hardcode credentials or API keys; always use stage-specific `.env` files.

---

## Submitting a Pull Request

1. Ensure your branch is up to date with `develop`.
2. Confirm all tests pass and the SAST scan is clean.
3. Open a pull request against `develop` (not `main`) with a clear description of the change and the motivation behind it.
4. Reference any related issues in the PR description.
5. A maintainer will review your PR and may request changes before merging.

---

## Code of Conduct

Be respectful and constructive. Harassment or exclusionary behavior of any kind will not be tolerated.

---

## Documentation

- Full docs: https://genericsuite.carlosjramirez.com
- Mirror: https://genericsuite.readthedocs.io

---

GenericSuite is developed and maintained by [Carlos J. Ramirez](https://carlosjramirez.com).
Licensed under the [ISC License](LICENSE).
