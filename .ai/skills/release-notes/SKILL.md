---
name: release-notes
description: Use when preparing or publishing a GenericSuite release — compiling per-package CHANGELOG.md entries, PR overviews, tags, and NPM/PyPI published versions into the release changelog document for GS Basecamp, generating social media summaries (English/Spanish) and image generation prompts. Triggers: "GS release", "release changelog", "release notes", "release compendium", "publish release".
---

# GenericSuite Release Documentation

## Overview

Automates the GenericSuite release documentation process: gather every package's changes, PRs, tags, and published versions; produce the release changelog for GS Basecamp; generate social media summaries and image prompts.

**All outputs are in English** (social media summaries are also translated to Spanish). The Spanish version of the Basecamp changelog is produced later by Basecamp's `make translate_uncommitted`, not by this skill.

## Inputs (ask the user if not provided)

| Input | Example | Notes |
|---|---|---|
| Release date | `2026-02-18` | Used in all filenames as `{release_date}` |
| Edition name | `v1.0.0` | Ask the user, suggesting the latest version in the **superproject** CHANGELOG.md (repo root) prefixed with `v` as the default; the user can override it |
| Jira ticket | `GS-262` | The release ticket; reference it in commits |
| Packages included | auto-detected | Every package whose CHANGELOG.md has a dated version newer than the last GS release (see Phase 0); confirm the resulting list with the user |
| Working directory | `releases-work/GS_Release_{release_date}/` (superproject root, gitignored) | For intermediate files (Prompts, Notes, PENDING) and the draft changelog for user review — never committed; the final changelog goes to the basecamp Releases dir only after user approval |

## Package Reference

Repo names, registry package names, and section titles differ — use this table verbatim.

| Changelog section title | Submodule (`packages/`) | Registry | Registry name | In release by default |
|---|---|---|---|---|
| GenericSuite Superproject | (repo root, `tomkat-cr/genericsuite`) | — | — | Yes |
| GenericSuite Frontend Core | genericsuite-fe | NPM | `genericsuite` | Yes |
| GenericSuite Frontend AI | genericsuite-fe-ai | NPM | `genericsuite-ai` | Yes |
| GenericSuite Backend Core | genericsuite-be | PyPI | `genericsuite` | Yes |
| GenericSuite Backend AI | genericsuite-be-ai | PyPI | `genericsuite-ai` | Yes |
| GenericSuite Backend Scripts | genericsuite-be-scripts | NPM | `genericsuite-be-scripts` | Yes |
| GenericSuite Frontend Scripts | genericsuite-fe-scripts | NPM | `genericsuite-fe-scripts` | If changed |
| GenericSuite BaseCamp | genericsuite-basecamp | — | — | Yes |
| GenericSuite BaseCamp App | genericsuite-basecamp-app | — | — | If changed |
| GenericSuite Gitops | genericsuite-gitops | — | — | If changed |
| GenericSuite App Maker (GSAM) | genericsuite-app-maker | — | — | If changed |
| GenericSuite ASDT | genericsuite-asdt-be | PyPI | `genericsuite_asdt` | If changed |
| GenericSuite CodeGen | genericsuite-codegen | — | — | If changed |
| GenericSuite Mobile | genericsuite-mobile | — | — | If changed |
| GenericSuite AI Agent Skills | genericsuite-skills | — | — | If changed |

All repos live at `https://github.com/tomkat-cr/<submodule-name>`. The Superproject section uses the root `CHANGELOG.md` and repo `tomkat-cr/genericsuite`; its latest version provides the suggested edition name.

## Workflow

### Phase 0 — Verification gate (drafts allowed, publish blocked)

Check ALL of the following at the start of every run and report the result as a checklist table (package → condition → OK/missing):

1. **`gh` CLI installed and authenticated**: `command -v gh && gh auth status`. If missing, warn with the install instructions (`brew install gh && gh auth login`).
2. **CHANGELOGs dated**: the package's CHANGELOG.md has a dated version section newer than the last GS release (not `[Unreleased]`). This is what actually decides inclusion — a package without one is **excluded from this release**, not a blocker.
3. **PRs merged** (library packages only): a merged `develop` → `main` PR exists since the last GS release.
4. **Tags created** (library packages only): a tag matching the CHANGELOG version exists.
5. **Packages published** (registry packages only): NPM/PyPI latest version equals the CHANGELOG version.

**Gate policy**:
- Condition 2 failing **excludes that package from the release** (it never blocks the skill). List excluded packages in the gate report; if an excluded package has meaningful `[Unreleased]` content, warn the user — they may have forgotten to date/version it — and let them confirm the exclusion or fix the CHANGELOG and re-run.
- Conditions 1 and 3–5 failing do NOT block drafting: run Phases 1–5 using `{PR URL — pending}` placeholders, tag/package URLs derived from the CHANGELOG versions, and PR overviews written from the CHANGELOG entries; record every unmet condition in the PENDING file.
- **Phase 6 (basecamp publish) is hard-blocked** until every condition passes. Report what is missing, let the user fulfil it, then re-run the skill to resume.

**Exemption**: `genericsuite-basecamp` and the superproject are exempt from checks 3–4 — their PR and tag are created AFTER the release doc is committed into basecamp (chicken-and-egg). Their PR/tag links are backfilled post-publish; list them in the PENDING file.

**Resume behavior**: when re-run and `releases-work/GS_Release_{release_date}/` already contains documents from a previous attempt, do NOT regenerate them from scratch — re-run this gate, backfill the missing pieces (PR URLs, PR overviews, tag links, package links) in the existing documents, and continue from where the run stopped (usually Phase 6).

### Phase 1 — Gather release data per package

For each included package:

1. **CHANGELOG entries**: read `packages/<submodule>/CHANGELOG.md` and extract the most recent **dated version section(s)** for this release (there may be more than one version since the last GS release). Skip `[Unreleased]` sections — if the release changes are still under `[Unreleased]`, tell the user the CHANGELOG must be dated and versioned first.
2. **Version**: the version number from the CHANGELOG heading, e.g. `[1.2.0] - 2026-02-18`.
3. **Merged PR(s)** since the last release:
   ```bash
   gh pr list --repo tomkat-cr/<submodule> --state merged --base main --limit 5 \
     --json number,title,url,mergedAt
   ```
4. **PR Overview**: the Copilot-generated summary in the PR body:
   ```bash
   gh pr view <number> --repo tomkat-cr/<submodule> --json title,body
   ```
   Use its title as the one-line PR summary and its "Highlights" as the overview bullets. If there is no Copilot summary, write one from the CHANGELOG entries.
5. **Tag**:
   ```bash
   gh release list --repo tomkat-cr/<submodule> --limit 3
   ```
   Tag URL pattern: `https://github.com/tomkat-cr/<submodule>/releases/tag/<version>`
6. **Published version** (verify it matches the CHANGELOG version):
   ```bash
   npm view <registry-name> version                       # NPM packages
   curl -s https://pypi.org/pypi/<registry-name>/json | jq -r .info.version   # PyPI packages
   ```
   Package URL patterns: `https://www.npmjs.com/package/<name>/v/<version>` and `https://pypi.org/project/<name>/<version>/`

**Report any mismatch** (CHANGELOG version ≠ published version ≠ tag) to the user before continuing.

### Phase 2 — Assemble the release changelog

Create `GS_Release_{release_date}_Changelog.md` from [templates/release-changelog-template.md](templates/release-changelog-template.md). One `##` section per package, in the order of the package table. Each section contains:

- **Package, Pull Request and Tag** — bullet links (omit the Package bullet for repos with no registry)
- **Pull Request Overview** — one-line summary, a paragraph, and a "Highlights" bullet list
- **CHANGELOG.md** — the extracted version section(s), verbatim, with headings demoted to `####`/`#####`

### Phase 3 — Write the Summary

After all sections exist, write the top `## Summary`: an enthusiastic, professional announcement (150–250 words) leading with the edition name, grouping the release's key benefits into 3–6 bullets (flexibility, performance, security, DX, AI, etc.). Model it on previous releases in `packages/genericsuite-basecamp/mkdocs_root/en/Releases/`.

### Phase 4 — Social media summaries

Using the finished changelog as input, run the prompt in [templates/social-media-prompt.md](templates/social-media-prompt.md) and produce, in the working directory:

- `GS_Release_{release_date}_Notes_english.md` — X, LinkedIn, and Blog Post summaries in English
- `GS_Release_{release_date}_Notes_spanish.md` — the same, in Spanish
- `GS_Release_{release_date}_Prompts.md` — every prompt used and its result (audit trail)

Each blog post must end with the release-notes link:
`Read more about these features and improvements in the [release notes](https://genericsuite.carlosjramirez.com/Releases/GS_Release_{release_date}_Changelog)` (Spanish: `Lee más sobre estas características y mejoras en las [notas de la versión](...)`).

### Phase 5 — Image generation prompts

Fill the two prompts (artistic + photorealistic) in [templates/image-prompts.md](templates/image-prompts.md) with the **English LinkedIn summary**, and append them to `GS_Release_{release_date}_Prompts.md`. The user generates the images externally (ChatGPT, Flux, Nano Banana). Expected filenames: `GS_Release_{release_date}_Image_{n}A.png`, `..._1B.png`, etc., placed in `packages/genericsuite-basecamp/mkdocs_root/en/Releases/images/`. Reference the chosen image at the top of the changelog:
`![GS_Release_{release_date}_Image_1A.png](./images/GS_Release_{release_date}_Image_1A.png)`

### Phase 6 — Publish into Basecamp

Only after the user has reviewed and approved the draft in the working directory:

1. Copy the changelog to `packages/genericsuite-basecamp/mkdocs_root/en/Releases/GS_Release_{release_date}_Changelog.md`.
2. Add the release at the **top** of `.../Releases/index.md`:
   `* [GS Release {YYYYMMDD} - {Edition name}](./GS_Release_{release_date}_Changelog.md)`
3. Optionally update the announcement block in `mkdocs_root/en/index.md` (banner image + link).
4. Remind the user to run `make translate_uncommitted` and `make transfer` in the basecamp package, and to commit with the `[GS-XXX]` ticket reference.

### Phase 7 — Pending items compendium

Collect unresolved items from the PR reviews (open Copilot/Gemini comments, "pending" notes) into `GS_Release_{release_date}_PENDING.md` in the working directory, so the user can create follow-up Jira tickets.

## Output Files

The working dir is `releases-work/GS_Release_{date}/` at the superproject root (gitignored).

| File | Location | Purpose |
|---|---|---|
| `GS_Release_{date}_Changelog.md` | working dir → basecamp `mkdocs_root/en/Releases/` after approval | Final published document |
| `GS_Release_{date}_Notes_english.md` | working dir | X / LinkedIn / Blog posts (EN) |
| `GS_Release_{date}_Notes_spanish.md` | working dir | X / LinkedIn / Blog posts (ES) |
| `GS_Release_{date}_Prompts.md` | working dir | Prompts + results audit trail |
| `GS_Release_{date}_PENDING.md` | working dir | Pending items for follow-up tickets |
| `GS_Release_{date}_Image_{n}.png` | basecamp `.../Releases/images/` | Release cover images (user-generated) |

For the manual publication steps that follow (WordPress, Medium, X, LinkedIn, post-release branch cleanup), see [references/publishing-checklist.md](references/publishing-checklist.md).

## Common Mistakes

- **Registry name ≠ repo name**: `genericsuite-fe` publishes to NPM as `genericsuite`; `genericsuite-fe-ai` as `genericsuite-ai`; `genericsuite-be` publishes to PyPI as `genericsuite`. Always use the package table.
- **Different packages have different versions** in the same release (e.g. FE 1.2.0, BE 0.3.0). Never assume one release version number.
- **Including `[Unreleased]` sections** — the release changelog only carries dated, published versions.
- **Writing outputs in Spanish** — source templates are Spanish but every generated document is English (Spanish only for the social media translations).
- **Skipping verification** — always cross-check CHANGELOG version vs published registry version vs GitHub tag before assembling.
- **Bypassing the Phase 0 gate** — drafts with placeholders are fine, but never publish into basecamp while any PR/tag/package condition is unmet "to save time"; report what's missing and resume after the user fulfils it.
- **Regenerating on resume** — if `releases-work/GS_Release_{date}/` already has documents, backfill them; don't overwrite work the user may have reviewed or edited.
