# `buildGsShadTheme` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `buildGsShadTheme` that returns `ShadThemeData` from GenericSuite theme tokens, using a named shadcn base scheme (`shadColorSchemeName`) plus GS `copyWith` overrides (including `accentColor` → `primary`/`ring`).

**Architecture:** Mirror `buildGsMaterialTheme` in `create_gs_app.dart`. Resolve the base via `ShadColorScheme.fromName(shadColorSchemeName)`, fall back to `'green'` on invalid names, then override surface/text/error/brand slots from `getNewThemeParams(tp)`. Wire `ShadApp.custom(theme: …)` to the new helper. Defaults live in `theme_config_defaults.dart`.

**Tech Stack:** Flutter/Dart (`genericsuite_flutter`, Dart SDK ^3.10.7), `shadcn_ui` ^0.53, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-07-21-build-gs-shad-theme-design.md`

## Global Constraints

- Ticket for ALL changelog entries and ALL commit messages: **[GS-261]**.
- Commit message style: `Add: ... [GS-261]`, `Change: ... [GS-261]`, `Fix: ... [GS-261]`.
- Work inside the submodule `packages/genericsuite-mobile` (branch `develop`). Commit there; do not require a superproject submodule-pointer commit unless the user asks.
- All Flutter commands run from `packages/genericsuite-mobile/genericsuite_flutter/` unless stated otherwise. `flutter analyze` must pass (zero issues) before every commit.
- Shell: bash.
- Backward compatibility: apps may omit `shadColorSchemeName`; default `'green'` preserves current behavior.
- Out of scope: dark mode, Shad typography / Inter wiring, per-component Shad themes, README updates, inferring scheme name from `accentColor`.

## File Structure

`packages/genericsuite-mobile/genericsuite_flutter/`:
- Modify `lib/services/theme_config_defaults.dart` — add `shadColorSchemeName` const + `defaultThemeParams` key.
- Modify `lib/services/create_gs_app.dart` — extend `getNewThemeParams` for Shad-needed tokens; add `buildGsShadTheme`; replace inline `ShadThemeData` at call site.
- Modify `test/theme_params_test.dart` — cover default key + `buildGsShadTheme` mapping / fallback.
- Modify `CHANGELOG.md` (package root `packages/genericsuite-mobile/CHANGELOG.md`) — Unreleased entry.

---

### Task 1: Default token `shadColorSchemeName`

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/theme_config_defaults.dart`
- Test: `packages/genericsuite-mobile/genericsuite_flutter/test/theme_params_test.dart`

**Interfaces:**
- Consumes: existing `defaultThemeParams` map.
- Produces: `const String shadColorSchemeName = 'green'` and `'shadColorSchemeName': shadColorSchemeName` in `defaultThemeParams`. Task 2 reads this key.

- [ ] **Step 1: Write the failing test**

In `test/theme_params_test.dart`, add inside the existing `'defaultThemeParams carries…'` test (or as a sibling test):

```dart
expect(defaultThemeParams['shadColorSchemeName'], 'green');
expect(shadColorSchemeName, 'green');
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd packages/genericsuite-mobile/genericsuite_flutter
flutter test test/theme_params_test.dart
```

Expected: FAIL — `shadColorSchemeName` undefined / key missing.

- [ ] **Step 3: Add the default token**

In `theme_config_defaults.dart`, after the `borderRadius` / near the accent defaults, add:

```dart
// Named shadcn_ui base scheme for buildGsShadTheme(). Valid values match
// ShadColorScheme.fromName: blue, gray, green, neutral, orange, red, rose,
// slate, stone, violet, yellow, zinc. Apps override via getThemeParams().
const String shadColorSchemeName = 'green';
```

In `defaultThemeParams`, add:

```dart
'shadColorSchemeName': shadColorSchemeName,
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cd packages/genericsuite-mobile/genericsuite_flutter
flutter test test/theme_params_test.dart
flutter analyze
```

Expected: PASS / no issues.

- [ ] **Step 5: Commit (submodule)**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/lib/services/theme_config_defaults.dart \
        genericsuite_flutter/test/theme_params_test.dart
git commit -m "$(cat <<'EOF'
Add: shadColorSchemeName default theme token [GS-261]

EOF
)"
```

---

### Task 2: `buildGsShadTheme` + call-site wiring

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/create_gs_app.dart`
- Test: `packages/genericsuite-mobile/genericsuite_flutter/test/theme_params_test.dart`

**Interfaces:**
- Consumes: `getNewThemeParams(tp)`, `ShadColorScheme.fromName`, GS tokens including `shadColorSchemeName`, `accentColor`, `scaffoldBackgroundColor`, `textColor`, `neutralSurfaceColor`, `secondaryTextColor`, `errorBackgroundColor`, `errorForegroundColor`, `separatorColor`, `corners`.
- Produces: `ShadThemeData buildGsShadTheme(Map<String, dynamic> tp)`. `CreateGsApp.build` uses `theme: buildGsShadTheme(tp)`.

- [ ] **Step 1: Write the failing tests**

Append to `test/theme_params_test.dart`:

```dart
  test('buildGsShadTheme maps GS tokens and keeps named-base selection', () {
    final theme = buildGsShadTheme({
      ...defaultThemeParams,
      'shadColorSchemeName': 'slate',
      'accentColor': Colors.teal,
    });
    expect(theme.brightness, Brightness.light);
    expect(theme.colorScheme.primary, Colors.teal);
    expect(theme.colorScheme.ring, Colors.teal);
    expect(theme.colorScheme.primaryForeground, Colors.white);
    expect(theme.colorScheme.background, Colors.white);
    expect(theme.colorScheme.foreground, const Color(0xFF111111));
    expect(theme.colorScheme.mutedForeground, const Color(0xFF6E6E73));
    expect(theme.colorScheme.destructive, const Color(0xFFFF3B30));
    expect(theme.colorScheme.destructiveForeground, Colors.white);
    expect(theme.colorScheme.border, const Color(0xFFD1D1D6));
    expect(theme.colorScheme.input, const Color(0xFFD1D1D6));
    expect(theme.colorScheme.secondary, const Color(0xFFF2F2F7));
    expect(theme.colorScheme.muted, const Color(0xFFF2F2F7));
    expect(theme.colorScheme.accent, const Color(0xFFF2F2F7));
    // selection left from named slate base (must not equal teal brand)
    expect(theme.colorScheme.selection, isNot(Colors.teal));
    expect(theme.radius, BorderRadius.circular(12.0));
  });

  test('buildGsShadTheme falls back to green for invalid scheme names', () {
    final theme = buildGsShadTheme({
      ...defaultThemeParams,
      'shadColorSchemeName': 'not-a-real-scheme',
      'accentColor': Colors.orange,
    });
    expect(theme.colorScheme.primary, Colors.orange);
    expect(theme.colorScheme.ring, Colors.orange);
    // Green base keeps a non-null selection; fallback must not throw.
    expect(theme.colorScheme.selection, isNotNull);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd packages/genericsuite-mobile/genericsuite_flutter
flutter test test/theme_params_test.dart
```

Expected: FAIL — `buildGsShadTheme` not defined.

- [ ] **Step 3: Extend `getNewThemeParams` for Shad-needed tokens**

In `create_gs_app.dart` inside `getNewThemeParams`, after the existing token defaults, ensure these keys exist (same `??` style as the others):

```dart
  newTp['shadColorSchemeName'] =
      tp['shadColorSchemeName'] ?? shadColorSchemeName;
  newTp['neutralSurfaceColor'] =
      tp['neutralSurfaceColor'] ?? neutralSurfaceColor;
  newTp['errorForegroundColor'] =
      tp['errorForegroundColor'] ?? errorForegroundColor;
```

- [ ] **Step 4: Implement `buildGsShadTheme`**

Place immediately after `buildGsMaterialTheme` in `create_gs_app.dart`:

```dart
/*
 * Build the ShadApp ShadThemeData from the GenericSuite theme tokens
 * (defaultThemeParams merged with the app's getThemeParams()) [GS-261].
 *
 * Base scheme: ShadColorScheme.fromName(shadColorSchemeName).
 * Brand: accentColor overrides primary + ring. Other GS surface/text/error
 * tokens override matching Shad slots; selection stays from the named base.
 */
ShadThemeData buildGsShadTheme(Map<String, dynamic> tp) {
  final Map<String, dynamic> newTp = getNewThemeParams(tp);
  final String schemeName =
      (newTp['shadColorSchemeName'] ?? shadColorSchemeName).toString();

  ShadColorScheme baseScheme;
  try {
    baseScheme = ShadColorScheme.fromName(
      schemeName,
      brightness: Brightness.light,
    );
  } catch (_) {
    if (createGsAppDebug) {
      logDebug(
        'buildGsShadTheme | invalid shadColorSchemeName "$schemeName", '
        'falling back to "$shadColorSchemeName"',
      );
    }
    baseScheme = ShadColorScheme.fromName(
      shadColorSchemeName,
      brightness: Brightness.light,
    );
  }

  final ShadColorScheme colorScheme = baseScheme.copyWith(
    background: newTp['scaffoldBackgroundColor'],
    foreground: newTp['textColor'],
    card: newTp['scaffoldBackgroundColor'],
    cardForeground: newTp['textColor'],
    popover: newTp['scaffoldBackgroundColor'],
    popoverForeground: newTp['textColor'],
    primary: newTp['accentColor'],
    primaryForeground: Colors.white,
    secondary: newTp['neutralSurfaceColor'],
    secondaryForeground: newTp['textColor'],
    muted: newTp['neutralSurfaceColor'],
    mutedForeground: newTp['secondaryTextColor'],
    accent: newTp['neutralSurfaceColor'],
    accentForeground: newTp['textColor'],
    destructive: newTp['errorBackgroundColor'],
    destructiveForeground: newTp['errorForegroundColor'],
    border: newTp['separatorColor'],
    input: newTp['separatorColor'],
    ring: newTp['accentColor'],
  );

  return ShadThemeData(
    brightness: Brightness.light,
    colorScheme: colorScheme,
    radius: newTp['corners'],
  );
}
```

- [ ] **Step 5: Wire the call site**

In `CreateGsAppState.build`, replace the inline theme:

```dart
    return ShadApp.custom(
      themeMode: ThemeMode.light,
      theme: buildGsShadTheme(tp),
      appBuilder: (context) {
```

- [ ] **Step 6: Run tests and analyze**

Run:

```bash
cd packages/genericsuite-mobile/genericsuite_flutter
flutter test test/theme_params_test.dart
flutter analyze
```

Expected: PASS / no issues.

- [ ] **Step 7: Commit (submodule)**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/lib/services/create_gs_app.dart \
        genericsuite_flutter/test/theme_params_test.dart
git commit -m "$(cat <<'EOF'
Add: buildGsShadTheme from named scheme + GS tokens [GS-261]

EOF
)"
```

---

### Task 3: CHANGELOG

**Files:**
- Modify: `packages/genericsuite-mobile/CHANGELOG.md`

**Interfaces:**
- Consumes: Tasks 1–2 behavior.
- Produces: Unreleased changelog bullets only (no README).

- [ ] **Step 1: Update Unreleased section**

Under `## [Unreleased]` → `### Added`, add:

```markdown
- `buildGsShadTheme()` builds `ShadThemeData` from GenericSuite theme tokens; new `shadColorSchemeName` theme param selects the shadcn base scheme (`green` default; any `ShadColorScheme.fromName` value), with `accentColor` overriding `primary`/`ring` and GS surface/text/error tokens applied via `copyWith` [GS-261].
```

- [ ] **Step 2: Commit (submodule)**

```bash
cd packages/genericsuite-mobile
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
Docs: CHANGELOG for buildGsShadTheme [GS-261]

EOF
)"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
|---|---|
| `shadColorSchemeName` default `'green'` in `defaultThemeParams` | Task 1 |
| `buildGsShadTheme(Map<String, dynamic> tp)` | Task 2 |
| `fromName` + invalid → green fallback + optional debug log | Task 2 |
| `accentColor` → `primary`/`ring`; full `copyWith` table; `selection` kept | Task 2 |
| `radius` from `corners` / `borderRadius` | Task 2 |
| Call site uses helper | Task 2 |
| `flutter analyze` passes | Tasks 1–2 |
| CHANGELOG | Task 3 |
| Out of scope (dark, Shad text theme, README, inference) | Not planned ✓ |
