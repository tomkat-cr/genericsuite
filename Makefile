# .DEFAULT_GOAL := local
.PHONY: help install update-packages
SHELL := /bin/bash

help:
	cat Makefile

update-packages:
	bash scripts/update_packages.sh

add-ai-skills-sharing-on-superproject:
	bash scripts/setup_ai_skills_sharing_on_superproject.sh add

remove-ai-skills-sharing-on-superproject:
	bash scripts/setup_ai_skills_sharing_on_superproject.sh remove

add-ai-skills-sharing:
	bash scripts/setup_ai_skills_sharing.sh add

remove-ai-skills-sharing:
	bash scripts/setup_ai_skills_sharing.sh remove

add-agents-md-sharing:
	bash scripts/setup_agents_md_sharing.sh add symlink "$(CURDIR)" "$(CURDIR)"

remove-agents-md-sharing:
	bash scripts/setup_agents_md_sharing.sh remove symlink "$(CURDIR)" "$(CURDIR)"

install: update-packages add-ai-skills-sharing-on-superproject add-agents-md-sharing

remove: remove-ai-skills-sharing-on-superproject remove-agents-md-sharing
