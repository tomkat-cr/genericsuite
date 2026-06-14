## Directory Structure

```
genericsuite/
├── .ai                            # Generic AI agents skills/commands collection
├── .codex/                        # Codex AI commands collection
├── .cursor/                       # Cursor AI commands collection
├── .gemini/                       # Gemini AI commands collection
├── .agents/                       # Agents AI commands collection
├── .devin/                        # Devin AI commands collection
├── docs/                          # Documentation for the project (source of truth)
├── openspec/                      # Software Design Document specifications for the project
├── packages/                      # GenericSuite packages
│   ├── genericsuite-fe            # React component library (core UI + JSON-driven CRUD)
│   ├── genericsuite-fe-ai         # React AI chatbot components
│   ├── genericsuite-fe-scripts    # Bash deployment/dev scripts for frontend projects
│   ├── genericsuite-be            # Python backend library (FastAPI/Flask/Chalice/MCP)
│   ├── genericsuite-be-ai         # Python AI features (LLMs, embeddings, vision, audio)
│   ├── genericsuite-be-scripts    # Bash deployment/dev scripts for backend projects
│   ├── genericsuite-codegen       # FastAPI + React + MCP server for AI-powered code generation
│   ├── genericsuite-app-maker     # Streamlit + FastAPI AI development assistant (GSAM)
│   ├── genericsuite-asdt-be       # Multi-agent AI software dev team (CrewAI/CamelAI/LangGraph)
│   ├── genericsuite-skills        # Claude AI skills/slash commands collection
│   ├── genericsuite-mobile        # Flutter core package + app template
│   ├── genericsuite-basecamp      # Documentation hub + example apps (MkDocs)
│   ├── genericsuite-basecamp-app  # Flutter documentation viewer app
│   ├── genericsuite-gitops        # DevOps/IaC automation (Bash, Docker, Kubernetes)
├── scripts/                       # Script to perform package-wide tasks
└── Makefile                       # All task automation
```
