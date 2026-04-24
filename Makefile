# .DEFAULT_GOAL := local
.PHONY: help install update-packages
SHELL := /bin/bash

help:
	cat Makefile

update-packages:
	bash scripts/update_packages.sh

install: update-packages
