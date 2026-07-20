# CHANGELOG

All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](http://semver.org/) and [Keep a Changelog](http://keepachangelog.com/).


## [Unreleased] - YYYY-MM-DD

### Added
- `childComponents` (1-N relationships) support in the GS Mobile (Flutter) CRUD Editor, matching the genericsuite-fe behavior, plus a new Mobile Development documentation section in GS Basecamp [GS-261].
- Apple-clean UI for GS Mobile: shadcn_ui-owned widget-tree root, green accent, 12px radius, iOS semantic colors, and Inter typography tokens in the getThemeParams() contract [GS-261].

### Changed

### Fixed

### Removed

### Security


## [1.0.0] - 2026-07-15

### Added
- Add: Introducing the GenericSuite superproject structure with git submodules, automation scripts, and project documentation, to make it easier to manage, change, and deploy the project as a whole [GS-319]
- AGENTS.md, GEMINI.md, and CLAUDE.md files to provide context and instructions to AI Coding Assistants [GS-303].
- Add the `release-notes` skill to the `.ai./skills` directory, to generate release notes and social media summaries for the project [GS-191].
- 1-1 relationships in the Generic CRUD Editor via the `select_table` field type, across genericsuite-be (all 5 DB engines), genericsuite-fe (GCE_RFC) and genericsuite-mobile (GCE_FLUTTER) [GS-259].
