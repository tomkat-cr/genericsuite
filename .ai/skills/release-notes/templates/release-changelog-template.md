# {YYYYMMDD} - {Edition name}

![GS_Release_{release_date}_Image_1A.png](./images/GS_Release_{release_date}_Image_1A.png)

Date: {release_date}

## Summary

{Enthusiastic, professional announcement (150–250 words). Lead with the edition
name and a one-line hook. Group the release's key benefits into 3–6 bullets
(e.g. flexibility, performance, security, developer experience, AI). Close
with a call to action to read the full changelog.}

<!--
Repeat the section below for every package included in the release, in this order:
Frontend Core, Frontend AI, Backend Core, Backend AI, Backend Scripts,
Frontend Scripts*, BaseCamp, BaseCamp App*, Gitops*, GSAM*, ASDT*, CodeGen*,
Mobile*, AI Agent Skills*.   (* = only when changed in this release)

- Omit the "Package:" bullet for repos not published to NPM/PyPI.
- If a package has multiple PRs, list all of them under "Pull Request:".
- If a package has multiple versions since the last GS release, include every
  dated version section under "CHANGELOG.md".
-->

## {Changelog section title, e.g. GenericSuite Frontend Core}

### Package, Pull Request and Tag

* Package: [{registry URL with version}]({registry URL with version})
* Pull Request: [{PR URL}]({PR URL})
* Tag: [https://github.com/tomkat-cr/{submodule}/releases/tag/{version}](https://github.com/tomkat-cr/{submodule}/releases/tag/{version})

### Pull Request Overview

{One-line PR title/summary}

{One paragraph describing the PR's overall intent and impact, from the
Copilot-generated PR body or written from the CHANGELOG entries.}

Highlights

- {Highlight 1}
- {Highlight 2}
- {Highlight 3}

### CHANGELOG.md

#### [{version}] - {release_date}

##### Added
- {entries copied verbatim from the package CHANGELOG.md, keeping [GS-XXX] refs}

##### Changed
- {...}

##### Fixed
- {...}

##### Security
- {...}

##### Removed
- {...}
