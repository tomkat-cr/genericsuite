# Design: `buildGsShadTheme` for GenericSuite Mobile

**Date:** 2026-07-21
**Status:** Approved
**Package affected:** `genericsuite-mobile` (`genericsuite_flutter`)

## Problem

`CreateGsApp` builds Material theme via `buildGsMaterialTheme(tp)` from GS theme
tokens, but the surrounding `ShadApp.custom` theme is inlined as a hardcoded
`ShadGreenColorScheme.light()` plus `borderRadius`. Apps cannot choose a
non-green shadcn base scheme, and GS surface/text/error tokens are not applied
to Shad components.

## Goal

Add `buildGsShadTheme` — parallel to `buildGsMaterialTheme` — that returns
`ShadThemeData` from the merged theme-params map, using a named shadcn base
scheme plus GS token overrides.

## Decisions

| Decision | Choice |
|---|---|
| Helper shape | `ShadThemeData buildGsShadTheme(Map<String, dynamic> tp)` in `create_gs_app.dart` |
| Base scheme selection | New theme param `shadColorSchemeName` (string) |
| Default scheme name | `'green'` (preserves current behavior) |
| Branding override | `accentColor` always `copyWith`s `primary` and `ring` |
| Unmapped shadcn slots | Keep from named base (e.g. `selection`) |
| Invalid scheme name | Fall back to `'green'`; optional `logDebug` when `createGsAppDebug` |
| Dark mode | Out of scope (light only, same as today) |
| Shad typography | Out of scope (Material owns Inter via `buildGsMaterialTheme`) |
| Docs / README | Out of scope for this change |

## Naming convention: `shadColorSchemeName`

New key in `defaultThemeParams` (and a top-level const, e.g.
`shadColorSchemeName = 'green'`):

```dart
'shadColorSchemeName': 'green',
```

Valid values match `ShadColorScheme.fromName`:

`blue`, `gray`, `green`, `neutral`, `orange`, `red`, `rose`, `slate`,
`stone`, `violet`, `yellow`, `zinc`

Consumer example in `getThemeParams()`:

```dart
{
  'shadColorSchemeName': 'slate',
  'accentColor': Colors.teal,
}
```

## Color mapping

Resolve base with:

```dart
ShadColorScheme.fromName(
  name,
  brightness: Brightness.light,
)
```

Then `copyWith`:

| Shad slot | GS token / value |
|---|---|
| `primary`, `ring` | `accentColor` |
| `primaryForeground` | `Colors.white` |
| `background`, `card`, `popover` | `scaffoldBackgroundColor` |
| `foreground`, `cardForeground`, `popoverForeground` | `textColor` |
| `secondary`, `muted`, `accent` | `neutralSurfaceColor` |
| `secondaryForeground`, `accentForeground` | `textColor` |
| `mutedForeground` | `secondaryTextColor` |
| `destructive` | `errorBackgroundColor` |
| `destructiveForeground` | `errorForegroundColor` |
| `border`, `input` | `separatorColor` |
| `selection` | leave from named base |

`ShadThemeData` also sets:

- `brightness: Brightness.light`
- `radius: newTp['corners']` (from `borderRadius` via `getNewThemeParams`)

Note: shadcn’s `accent` slot is the subtle hover/surface role, not the brand
color. Brand lives in `primary` / `ring`.

## Implementation outline

1. **`theme_config_defaults.dart`**
   - Add `const String shadColorSchemeName = 'green';`
   - Add `'shadColorSchemeName': shadColorSchemeName` to `defaultThemeParams`

2. **`create_gs_app.dart`**
   - Add `buildGsShadTheme(Map<String, dynamic> tp)`:
     - `newTp = getNewThemeParams(tp)`
     - Resolve scheme name from `newTp['shadColorSchemeName']` (default `'green'`)
     - `try` `ShadColorScheme.fromName(...)` / `catch` → green + optional debug log
     - `copyWith` GS token mapping above
     - Return `ShadThemeData(brightness: light, colorScheme: …, radius: corners)`
   - Replace inline `ShadThemeData(...)` in `build` with `buildGsShadTheme(tp)`

## Out of scope

- Dark / `ThemeMode` support
- Mapping GS Inter / `textTheme` into `ShadTextTheme`
- Per-component Shad themes (`ShadInputTheme`, button themes, etc.)
- README updates
- Inferring scheme name from `accentColor` / `MaterialColor`

## Success criteria

- Default apps look equivalent to today’s green Shad theme, with GS radius and
  surface/text/error tokens applied.
- An app can set `shadColorSchemeName: 'slate'` (or any valid name) and still
  brand via `accentColor` on `primary`/`ring`.
- Invalid scheme names do not crash; they fall back to green.
- `flutter analyze` passes for `genericsuite_flutter`.
