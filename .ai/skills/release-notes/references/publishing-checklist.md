# GenericSuite Release Publishing Checklist

Manual steps surrounding the automated documentation flow in SKILL.md.
Steps 1–3 happen BEFORE running the skill; steps 4+ happen AFTER.

## 1. Release preparation (per package)

- Create the Jira ticket for the release ("GS-XXX - GS Release {release_date}").
- Update/improve README, docs and Memory Bank / Specs where needed.
- Run PR code reviews (Copilot + Gemini) on each package's `develop` → `main` PR;
  fix or document every finding (sometimes the review email never arrives —
  check the PR on GitHub directly).
- Pre-publication self review per package:
  - Change every `DEBUG = True` to `DEBUG = False`.
  - Verify the version to publish differs from the last one on NPM/PyPI.
  - Check the most recent GitHub tag.
  - Review all CHANGELOG.md entries; set the publication date; commit + push.
  - Run the project linter and `make publish` in dry-run mode to surface
    last-minute changes; commit + push.

## 2. Publish packages

For each package with a registry:

- `make publish` (actually publishing to NPMJS / PyPI).
- Copy the latest CHANGELOG entries into the PR description.
- Resolve remaining Copilot comments, merge the PR, create the tag.
- Verify the publication on NPMJS / PyPI.
- Document package URL, PR URL, and tag URL in the Jira ticket.

Optional side-project releases: GS Gitops, GSAM, ASDT, CodeGen, Skills.

## 3. Run the release-notes skill

Produces the changelog, social summaries, image prompts, and pending
compendium (see SKILL.md).

## 4. Basecamp release

- Fix `npm install` / dependency pins so they don't point to `develop` versions.
- Run `make translate_uncommitted` to generate the Spanish docs.
- Publish with `make transfer` (FTP) and verify
  https://genericsuite.carlosjramirez.com shows the latest changes.
- Commit + push + PR + tag on genericsuite-basecamp.

## 5. Blog (WordPress at carlosjramirez.com)

1. New Post → "Use Default Editor".
2. Paste the title and post from `GS_Release_{date}_Notes_spanish.md`
   (Spanish first, then repeat for English via the language flag section
   in Post properties).
3. Use "Generic Suite" (two words) in titles/generic mentions for SEO.
4. Convert bullet paragraphs to list blocks; subtitles to headers; verify
   all hyperlinks.
5. Add the GenericSuite logo image at the end, linked to
   https://genericsuite.carlosjramirez.com.
6. Post properties:
   - Feature Image titled/alt-texted "Generic Suite release {release_date}",
     caption/description = first paragraph of the LinkedIn post.
   - Format: Standard; Excerpt = first paragraph of the LinkedIn post;
     Newsletter: "Post Only".
7. Publish; note the URL in the Jira ticket and the social media posts.

## 6. Medium

- https://medium.com/me/stories → "Import a story" → paste the WordPress URL
  (Spanish first, then English).
- Add the main image after the title (with title/alt), add Topics
  (Software Development, AI, ...).
- Schedule: best slot is Tuesday 6 AM Colombia time (GMT-5).

## 7. Social networks

- Post on X (@genericsuitelib) and LinkedIn using the summaries from the
  Notes files, including the blog/release-notes URLs and the release image.

## 8. Post-release

- Ensure every repo is back on a `develop` branch (create it if missing,
  delete stray branches); switch local machines to `develop`.
- Consolidate pending items from PR reviews into follow-up Jira tickets
  (source: `GS_Release_{date}_PENDING.md`).
- Log invested hours in the Jira ticket.
- Update this skill if the process changed.
