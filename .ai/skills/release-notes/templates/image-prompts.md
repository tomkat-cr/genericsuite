# Release Image Generation Prompts

Fill `{linkedin_summary_english}` with the English LinkedIn summary from the
social media step. Generate the images with ChatGPT, or Gemini (Nano Banana):

- https://chatgpt.com
- https://gemini.google.com/

Save the results as
`GS_Release_{release_date}_Image_{n}{variant}.png` (e.g. `_1A.png`, `_1B.png`)
in `packages/genericsuite-basecamp/mkdocs_root/en/Releases/images/`.

## 1. Artistic Style Image

```prompt
Artistic style image for GS release {release_date}

You will be provided with the following information:
```
{linkedin_summary_english}
```

Follow these instructions to create an Artistic Style Image:
* The image should be an artistic style allegorical image.
* Should symbolize the new features of GenericSuite, focusing on the very short features.
* Ensure the image is vibrant, full-color, and eye-catching.
* It should have a horizontal rectangular shape to be used as a cover image.
* Should appeal to developers and investors.
* Should not contain any text, only graphical elements.
```

## 2. Photorealistic Image

```prompt
Photorealistic image for GS release {release_date}

You will be provided with the following information:
```
{linkedin_summary_english}
```

Follow these instructions to create a Photorealistic Image:
* The image should be a photorealistic allegorical image.
* Should symbolize the new features of GenericSuite, focusing on the very short features.
* Ensure the image is vibrant, full-color, and eye-catching.
* It should have a horizontal rectangular shape to be used as a cover image.
* Should appeal to developers and investors.
* Should not contain any text, only graphical elements.
```

## Optional: README / app cover image style

For app README covers (e.g. FastAPITemplate), a proven prompt style:

```prompt
Landscape, ultra-photorealistic corporate office portrait.
A diverse group of men and women (visible from wrist to head) standing and
sitting naturally around a modern office desk, collaboratively looking at a
sleek Apple iMac. The iMac screen displays a modern web application dashboard
featuring two clean, minimal pie charts and the {app name} logo clearly
visible on the interface (logo sourced from the uploaded image).

Expressions: polite, calm, mildly comfortable smiles.
Wardrobe: modern business-casual fashion, tailored, minimalist, high-end.
Color palette: muted pastels, warm neutrals, soft beiges, light greys, subtle blues.
Lighting: cinematic studio lighting, soft directional light, high contrast with gentle falloff.
Camera & style: shot on medium-format film, shallow depth of field, soft focus,
subtle film grain, faint vignette.
Mood: premium, elegant, authentic enterprise realism.
Quality: ultra-high resolution, photorealistic skin tones, true-to-life materials.

Avoid: fake UI, distorted charts, bad logos
```
