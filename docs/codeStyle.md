# Code Style Guidelines

## Python (docs dependencies, scripts)
- Formatter: `autopep8`
- Linter: `Flake8`
- Python version: `3.12+` (< 4.0)
- Dependency management: `uv` (preferred), `poetry` or `pipenv`
- Monorepo orchestration: `NPM Workspaces` (preferred) or `TurboRepo`

## JavaScript / TypeScript (ExampleApp, FastAPI Template UI)
- Formatter: `Prettier`
- Linter: `ESLint` with per-package configs
- Node.js version: `20+`
- Package manager: `npm workspaces` (preferred) or `pnpm`
- Build tool: `Vite` (preferred) or `Webpack`
- Monorepo orchestration: `NPM Workspaces` (preferred) or `TurboRepo`

## Shell Scripts
- All shell scripts must be POSIX-compliant (bash/zsh compatible).
- Use `#!/bin/bash` shebang.
- Always call bash scripts with `bash`, not `sh`.
- Use `set -euo pipefail` for safety.
- Quote all variable expansions: `"${var}"`.
- Handle macOS vs Linux differences (e.g., prefer `perl -pi -e` over `sed -i`).
- Avoid bash-specific features unless necessary, and if so, document them clearly.
- Provide clear usage examples and error messages.
- Don't use `read -p "Any prompt: " VAR`, use `echo "Any prompt: "` and `read VAR < /dev/tty`.

## Documentation (Markdown)
- All docs written in Markdown with minimal HTML
- Follow progressive disclosure: overview → section summary → detail page
- Enhanced syntax via `pymdown-extensions` for projects using `MkDocs`

## Important Notes
- When this file is updated, warn the user to update `codeStyle.md` file in all projects.
