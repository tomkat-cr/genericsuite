# GenericSuite (GS)

**GenericSuite (GS)** is a comprehensive, modular development framework designed to accelerate the creation of AI-powered applications. It provides a robust foundation of reusable packages, tools, and AI-driven workflows for both frontend and backend development.

## 🚀 Key Features

- **Modular Architecture**: Composed of independent packages (skills, fe-scripts, gitops) that can be used together or separately.
- **AI-Powered Development**: Integrates AI tools and agents to streamline coding, testing, and deployment.
- **Cross-Platform**: Supports web, mobile (Flutter), and backend (Python/FastAPI) development.
- **GitOps Ready**: Includes tools and configurations for Infrastructure as Code and CI/CD pipelines.

## 📦 Packages

| Package | Description |
| :--- | :--- |
| [genericsuite-be](https://github.com/tomkat-cr/genericsuite-be) | Core for GenericSuite backend based projects using FastAPI, Flask or Chalice. |
| [genericsuite-be-ai](https://github.com/tomkat-cr/genericsuite-be-ai) | AI for GenericSuite backend based projects. |
| [genericsuite-be-scripts](https://github.com/tomkat-cr/genericsuite-be-scripts) | Scripts for GenericSuite backend based projects. |
| [genericsuite-fe](https://github.com/tomkat-cr/genericsuite-fe) | Core for GenericSuite frontend based projects using ReactJS. |
| [genericsuite-fe-ai](https://github.com/tomkat-cr/genericsuite-fe-ai) | AI for GenericSuite frontend based projects. |
| [genericsuite-fe-scripts](https://github.com/tomkat-cr/genericsuite-fe-scripts) | Frontend development utilities and scripts for web applications. |
| [genericsuite-basecamp](https://github.com/tomkat-cr/genericsuite-basecamp) | The starting point and documentation for GenericSuite based projects development. |
| [genericsuite-basecamp-app](https://github.com/tomkat-cr/genericsuite-basecamp-app) | Mobile app for Android and iOS with all the documentation on `genericsuite-basecamp`. |
| [genericsuite-mobile](https://github.com/tomkat-cr/genericsuite-mobile) | GenericSuite core for mobile apps using Flutter. |
| [genericsuite-mobile-exampleapp](https://github.com/tomkat-cr/genericsuite-mobile-exampleapp) | GenericSuite example mobile app. |
| [genericsuite-skills](https://github.com/tomkat-cr/genericsuite-skills) | A collection of AI skills and tools for code generation, evaluation, and automation. |
| [genericsuite-gitops](https://github.com/tomkat-cr/genericsuite-gitops) | Infrastructure as Code (IaC) and DevOps automation tools. |
| [genericsuite-app-maker](https://github.com/tomkat-cr/genericsuite-app-maker) | AI tool to enhance the software development ideation and test AI models, LLM providers and its features. |
| [genericsuite-asdt-be](https://github.com/tomkat-cr/genericsuite-asdt-be) | provides a team of autonomous entities designed to solve software development problems using AI to make decisions, learn from interactions, and adapt to changing conditions without human intervention. |

## 🛠️ Getting Started

### Prerequisites

- Node.js (v26+)
- Python (v3.12+)
- Flutter (v3.38+)
- Docker & Docker Compose (or Podman & Podman Compose)
- Make

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/tomkat-cr/genericsuite.git
   cd genericsuite
   ```

2. Retrieve all GenericSuite packages (repositories):
   ```bash
   make update-packages
   # Or
   # ./scripts/update_packages.sh
   ```

## Update Packages

About the `update-packages` command, there are some options:

```bash
# Default: add all packages as git submodules (recommended) and pull latest on BRANCH (default: develop)
make update-packages

# Alternative: add all packages as git submodules and pull latest on BRANCH main from the repository tomkat-cr/genericsuite
BRANCH=main SUBMODULE=1 GIT_USER=tomkat-cr ./scripts/update_packages.sh

# Alternative: use git clone instead of submodule-add (set SUBMODULE=0):
SUBMODULE=0 ./scripts/update_packages.sh
```

## 🤝 Contributing

Contributions are welcome! Please read our [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## 👥 Community

Join our community to share ideas, ask questions, and collaborate on building the future of GenericSuite.

## Documentation

* [https://genericsuite.carlosjramirez.com](https://genericsuite.carlosjramirez.com)
* Mirror: [https://genericsuite.readthedocs.io](https://genericsuite.readthedocs.io)

## License

[GenericSuite](https://genericsuite.carlosjramirez.com) is open-sourced software licensed under the MIT license.

## Credits

This project is developed and maintained by [Carlos J. Ramirez](https://carlosjramirez.com). For more information or to contribute to the GenericSuite project, visit [GenericSuite on GitHub](https://github.com/tomkat-cr/genericsuite).

Happy Coding!
