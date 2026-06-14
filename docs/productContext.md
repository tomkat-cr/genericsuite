# genericsuite superproject

This repository is the starting point and documentation for GenericSuite-based project development.

In this repository you will find:

- Main Documentation Page @mkdocs_root/en/index.md
- App Frontend @mkdocs_root/en/Frontend-Development/index.md
- App Backend @mkdocs_root/en/Backend-Development/index.md
- GenericSuite Core @mkdocs_root/en/Backend-Development/GenericSuite-Core/index.md
- GenericSuite AI @mkdocs_root/en/Backend-Development/GenericSuite-AI/index.md
- Configuration Guide @mkdocs_root/en/Configuration-Guide/index.md
- Generic CRUD Editor Configuration @mkdocs_root/en/Configuration-Guide/Generic-CRUD-Editor-Configuration.md)
- Code examples: ExampleApp monorepo with TurboRepo @mkdocs_root/code/exampleapp/README.md and FastAPI Template monorepo with NPM Workspaces @mkdocs_root/code/fastapitemplate/README.md
- Releases @mkdocs_root/en/Releases/index.md of the GenericSuite library.
- Basecamp Changelog @CHANGELOG.md for the genericsuite superproject repository.

## About GenericSuite

GenericSuite is a collection of packages designed to improve software developer productivity and streamline workflows. It consists of a Core set of tools and several extensions, including an AI-powered extension.

### Key Features

- **Full-Stack Integration:** Unified library for frontend and backend development.
- **AI-Driven Efficiency:** Built-in AI capabilities for automation and content generation.
- **Customizable and Scalable:** Adaptable to various frameworks, databases, and deployment platforms.
- **Accelerated Workflow:** Pre-built utilities and automation tools to save time.
- **Cross-Platform Compatibility:** Supports FastAPI, Flask, Chalice, DynamoDB, and MongoDB.

### Core Components

- **GenericSuite Core:**
  - Customizable CRUD editor, menu generator, and login interface.
  - Generic database and API endpoint builder.
  - Backend framework abstraction (FastAPI, Flask, Chalice).
  - Database abstraction (MongoDB, DynamoDB, Postgres, MySQL, Supabase).
- **GenericSuite AI:**
  - AI chatbot endpoint with integrations for OpenAI, LangChain, and Hugging Face.
  - Computer vision, image generation, speech processing, and text-to-speech capabilities.
  - Web scraping, translation tools, and vector search.
- **GSAM (Generic Suite App Maker):**
  - AI-assisted app development, code generation, and database structuring.
- **ASDT (Agentic Software Development Team):**
  - Multi-agent AI collaboration for software automation.
- **GitOps:**
  - Pre-configured scripts for Kubernetes, Docker, and VPS environments.

## Project Structure

The genericsuite superproject project is organized into the following main directories:

- `mkdocs_root/`: Contains the documentation for the project, including guides for backend and frontend development, configuration, and sample code.
- `scripts/`: Includes various shell scripts for tasks such as installing MkDocs, running the documentation server, and transferring the site.
- `overrides/`: Contains files to override the default MkDocs theme.
- `docs/`: Project documentation for AI Agents.
- `.claude/`: Skills, plugins, commands, rules and sub-agents configuration for AI Agents.

## Getting Started

1. **Explore the documentation:** The `mkdocs_root/en/` directory contains detailed information about the GenericSuite ecosystem.
2. **Review the sample code:** The `mkdocs_root/code/` directory provides examples for different backend and frontend frameworks.
3. **Use the scripts:** The `scripts/` directory contains useful scripts for managing the documentation site.
4. **Start the mkdocs local server:** The `scripts/mkdocs_run.sh` script can be used to start the mkdocs local server. You can run it using the `make serve` command to build and serve the documentation or `make run` to only serve the documentation.
5. **Translate from english to other languages:** The `scripts/translation` directory contains the scripts to translate the documentation from english to other languages (e.g. spanish), checking the documents under `mkdocs_root/en` directory modified after its counterparts under `mkdocs_root/en` directory. You can run `make translate_uncommitted` script to run the translation process.

## Example Application

genericsuite superproject includes a full-stack `exampleapp` to demonstrate a real-world implementation of the suite's capabilities. This application is structured as a monorepo and showcases how to integrate frontend and backend components efficiently.

**ExampleApp** is a full-stack application to manage food ingredients, recipes, and daily meals, demonstrating a modern web app architecture with multiple backend services and a React-based frontend implementing GenericSuite.

It is inspired by the principles of Caloric Deficit. The purpose is to achieve weight loss goals and maintain a better lifestyle, based on proper nutrition. 

**ExampleApp** let users:

- Record their preferred food ingredients, recipes, and daily meals
- Keep track their calorie consumption
- AI-powered experiences to the users by letting them to communicate by voice, text, or image uploads to a specialized assistant called ExampleApp Bot, which is based on large language models, speech-to-text, text to image and image to text technologies.

### Key Features of the Example App

- **Monorepo Structure:** Managed with **PNPM** and **Turborepo** to streamline package management and build processes.

- **Frontend**: Modern React application with Vite

- **Backend Options**:

  - FastAPI (Python)
  - Flask (Python)
  - Chalice (Python)
  - MCP Server (Python)

- **Database Options**:

  - DynamoDB (AWS)
  - MongoDB (MongoDB Atlas or self-hosted)
  - Postgres (PostgreSQL or AWS RDS)
  - MySQL (MySQL or AWS RDS)
  - Supabase

- **Development Tools**:

  - NPM Workspaces or pnpm for package management
  - NPM Workspaces or TurboRepo for monorepo management
  - Environment-based configuration

### Running the Example App

The following `make` commands are available to manage the `exampleapp`:

- `make exampleapp-install`: Installs all dependencies for the monorepo.
- `make exampleapp-update`: Updates the dependencies.
- `make exampleapp-run`: Starts the application.
- `make exampleapp-clean`: Removes all installed dependencies and build artifacts.

## FastAPI Template Application

genericsuite superproject includes a full-stack `fastapitemplate` to demonstrate a real-world implementation of the suite's capabilities. This application is structured as a monorepo and showcases how to integrate frontend and backend components efficiently.

**FastAPITemplate** is a full-stack application with no specific purpose, demonstrating a modern web app architecture with FastAPI based backend services and a React-based frontend implementing GenericSuite.

**FastAPITemplate** let developers:

- To have a template as a starting point to build their own applications
- Pre-packed AI-powered experiences by letting application users to communicate by voice, text, or image uploads to a specialized assistant called AI Assistant, which is based on large language models, speech-to-text, text to image and image to text technologies.

### Key Features of the FastAPITemplate App

- **Monorepo Structure:** Managed with **NPM Workspaces** to streamline package management and build processes.

- **Frontend**: Modern React application with Vite

- **Backend Options**:

  - FastAPI (Python)
  - MCP Server (Python)

- **Database Options**:

  - DynamoDB (AWS)
  - MongoDB (MongoDB Atlas or self-hosted)
  - Postgres (PostgreSQL or AWS RDS)
  - MySQL (MySQL or AWS RDS)
  - Supabase

- **Development Tools**:

  - npm for package management and monorepo management
  - Environment-based configuration

### Running the FastAPITemplate App

The following `make` commands are available to manage the `fastapitemplate`:

- `make fastapitemplate-install`: Installs dependencies for the monorepo.
- `make fastapitemplate-install-all`: Installs dependencies for all the services in the monorepo.
- `make fastapitemplate-update`: Updates the dependencies.
- `make fastapitemplate-create-ssl-certs`: Creates SSL self-signed certificates for the application.
- `make fastapitemplate-run`: Starts the application.
- `make fastapitemplate-clean`: Removes all installed dependencies and build artifacts.

## Repositories

A full list of GenericSuite repositories can be found in the @mkdocs_root/en/repositories.md file.
