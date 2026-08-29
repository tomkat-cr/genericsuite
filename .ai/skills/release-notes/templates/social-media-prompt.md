# Social Media Publication Prompt

Use this prompt with the finished `GS_Release_{release_date}_Changelog.md` as
the provided content. Record the prompt and its full result in
`GS_Release_{release_date}_Prompts.md`. Split the results by language into
`GS_Release_{release_date}_Notes_english.md` and
`GS_Release_{release_date}_Notes_spanish.md`.

```prompt
You are a professional content creator and social media manager. I'm the
software architect of the GenericSuite software library and I'm going to
release a new version of it. You will be provided with the GenericSuite
release notes in the attached file "GS_Release_{release_date}_Changelog.md".
You will be responsible for creating summaries for each platform to publish
on my social media accounts and blog post.

# Requirements

Follow these guidelines to create summaries for each platform:

1.  **X (Twitter)**:
    *   Create a concise summary (under 280 characters) in English.
    *   Translate the summary into Spanish.
    *   Include relevant hashtags.

2.  **LinkedIn**:
    *   Write a professional and engaging summary (around 200-300 words) in English.
    *   Translate the summary into Spanish.
    *   Highlight key features and benefits for professionals.

3.  **Blog Post**:
    *   Develop a detailed and informative summary (around 400-600 words) in English.
    *   Translate the summary into Spanish.
    *   Provide context and explain the impact of the new features.

Ensure that all summaries are accurate, relevant, and tailored to the
specific platform.

# Output

Your output should be structured as follows:

**X (Twitter)**

*   English: [English summary for Twitter]
*   Spanish: [Spanish summary for Twitter]

**LinkedIn**

*   English: [English summary for LinkedIn]
*   Spanish: [Spanish summary for LinkedIn]

**Blog Post**

*   English: [English summary for Blog Post]
*   Spanish: [Spanish summary for Blog Post]
```

## Post-processing rules

- In titles and generic mentions, use "Generic Suite" (two words) instead of
  "GenericSuite" for SEO — except when naming a specific component
  (e.g. "GenericSuite Backend AI").
- Append the release-notes link at the end of each blog post:
  - English: `Read more about these features and improvements in the [release notes](https://genericsuite.carlosjramirez.com/Releases/GS_Release_{release_date}_Changelog)`
  - Spanish: `Lee más sobre estas características y mejoras en las [notas de la versión](https://genericsuite.carlosjramirez.com/Releases/GS_Release_{release_date}_Changelog)`
