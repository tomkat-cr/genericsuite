# GS Mobile childComponents + ShadCN-like UI Implementation Plan [GS-261]

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Sub-agent model guidance:** dispatch each code task (Tasks 1–9) to a **sonnet** sub-agent; dispatch the documentation/changelog tasks (Tasks 10–11) to a **haiku** sub-agent. Review between tasks in the main session.

**Goal:** Make the genericsuite-mobile Flutter CRUD Editor handle `childComponents` (1-N relationships) the way genericsuite-fe already does, and restyle the whole mobile library to an Apple-clean design language with `shadcn_ui` owning the widget-tree root.

**Architecture:** All code changes live inside the `packages/genericsuite-mobile` git submodule (Flutter library `genericsuite_flutter/`). Child components declared in the frontend JSON config (`"childComponents": ["Name", ...]`) are resolved against the `callbacks['childComponents']` registry supplied by the consumer app and rendered as tappable navigation sections at the bottom of the edit form (the mobile equivalent of genericsuite-fe's inline `iterateChildComponents()`); each child opens full-screen and is a `CrudEditor` with `type: 'child_listing'` receiving `parentData`. Theming is centralized: new design tokens in `theme_config_defaults.dart`, a merged `defaultThemeParams` map, and a Material `ThemeData` built from those tokens by `CreateGsApp`, whose root widget becomes `ShadApp.custom`. Documentation goes to `packages/genericsuite-basecamp` (new "Mobile Development" section).

**Tech Stack:** Flutter/Dart (Dart SDK ^3.10.7), `shadcn_ui` (flutter-shadcn-ui port), `google_fonts` (Inter, SF-Pro-like), flutter_test, MkDocs (basecamp docs).

## Global Constraints

- Ticket for ALL changelog entries and ALL commit messages: **[GS-261]**.
- Commit message style follows the repos' existing convention: `Add: ... [GS-261]`, `Change: ... [GS-261]`, `Fix: ... [GS-261]`. End every commit message body with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Work **inside the submodules** (`packages/genericsuite-mobile`, `packages/genericsuite-basecamp`), each already on branch `develop`. Commit in each submodule separately. Note: `packages/` is untracked in the superproject, so there are no submodule-pointer commits at the root — only `docs/activeContext.md` and root `CHANGELOG.md` are committed at the root.
- All Flutter commands run from `packages/genericsuite-mobile/genericsuite_flutter/` unless stated otherwise. `flutter analyze` must pass (zero issues) before every commit.
- Shell: bash.
- Do NOT touch backend result-shape conventions; API responses keep `{"error": bool, "error_message": str|None, "resultset": Any}`.
- Design language (mobile): Apple-clean — white/neutral surfaces, near-black text (`Color(0xFF111111)`), ONE accent color (default `Colors.green`), **12 px** corner radius, iOS system semantic colors (systemRed `0xFFFF3B30`, systemBlue `0xFF007AFF`, systemOrange `0xFFFF9500`, systemGreen `0xFF34C759`, separator `0xFFD1D1D6`).
- Typography intent: Inter via `google_fonts` for the SF-Pro-like feel, exposed as `fontFamily` / `textTheme` tokens in the `getThemeParams()` contract.
- Backward compatibility: existing consumer apps override `getThemeParams()` and may return only a subset of keys — `CreateGsApp` must merge their map OVER `defaultThemeParams`, never require new keys.
- Out of scope (do NOT implement here): any web-side ShadCN work. For reference only: web work composes ShadCN components from `packages/genericsuite-codegen/ui/src/components/ui/` (button, card, input, select, sheet already exist there) — that is ticket GS-150, not this plan.
- `genericsuite_flutter` version bump: `0.4.1` → `0.5.0` (new features, no breaking API removal).

## Reference: how genericsuite-fe handles childComponents (the behavior to mirror)

From `packages/genericsuite-fe/src/lib/services/`:
- `generic.editor.rfc.common.jsx:85` — `editor.childComponents` defaults to `[]`.
- `generic.editor.rfc.formpage.jsx:268` — child components render **only when NOT in create mode**, below the form.
- `generic.editor.rfc.formpage.jsx:1029` (`iterateChildComponents`) — each child gets `parentData` = the parent row's field values, plus `handleFormPageActions`.
- `generic.editor.rfc.formpage.jsx:1071` (`saveRowToDatabase`) — for `editor.type === "child_listing"`: parent key(s) from `endpointKeyNames` + `parentData` are merged into the payload; for `subType === "array"` the payload becomes `{parentKeys..., <array_name>: submittedValues, <array_name>_old: initialValues}` with `rowId = null`; for `subType === "table"` parent keys are merged into the child row.
- Config example (`packages/genericsuite-basecamp/mkdocs_root/code/exampleapp/apps/config_dbdef/frontend/users.json:220`): `"childComponents": ["UsersFoodTimes", "UsersUserHistory", "UsersConfig", "UsersApiKey"]`.

Mobile already has: `childComponents` defaulted to `[]` (`crud_editor.dart:432-436`), `child_listing`/`subType`/`endpointKeyNames` validation and `_setEndpointFilter()` (`crud_editor.dart:150-172, 444-525`). Missing: rendering the child sections, the child-listing save/delete payload, and back-navigation for pushed children.

## File Structure

`packages/genericsuite-mobile/genericsuite_flutter/`:
- Modify `pubspec.yaml` — version 0.5.0, add `shadcn_ui`, `google_fonts`.
- Modify `lib/services/crud_editor_commons.dart` — add pure function `buildChildRowToSave()`.
- Create `lib/services/crud_editor_child_components.dart` — child-section widgets + `ChildComponentBuilder` typedef.
- Modify `lib/services/form_field_service.dart` — render child sections in `DataFormBody`.
- Modify `lib/services/crud_editor.dart` — keep original row copy, child-listing save/delete payload, `isChildComponent` back navigation.
- Modify `lib/services/theme_config_defaults.dart` — Apple-clean tokens + `defaultThemeParams`.
- Modify `lib/services/app_callables_super.dart` — `getThemeParams()` returns `defaultThemeParams`.
- Modify `lib/services/create_gs_app.dart` — `ShadApp.custom` root + `buildGsMaterialTheme()`.
- Modify `lib/genericsuite.dart` — export the new file.
- Create `test/child_row_to_save_test.dart`, `test/crud_editor_child_components_test.dart`, `test/theme_params_test.dart`; fix `test/genericsuite_test.dart`.
- Modify `README.md` (childComponents + theming sections), `CHANGELOG.md`.

`packages/genericsuite-basecamp/`:
- Create `mkdocs_root/en/Mobile-Development/index.md`.
- Modify `mkdocs.yml` (nav), `CHANGELOG.md`.

Superproject root:
- Modify `docs/activeContext.md`, `CHANGELOG.md`.

---

### Task 1: `buildChildRowToSave()` pure function (child-listing payload)

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/crud_editor_commons.dart`
- Test: `packages/genericsuite-mobile/genericsuite_flutter/test/child_row_to_save_test.dart`

**Interfaces:**
- Consumes: existing constants `actionCreate`/`actionUpdate`/`actionDelete` in the same file.
- Produces: `Map<String, dynamic> buildChildRowToSave({required Map<String, dynamic> editorConfig, required String action, required String? rowId, required Map<String, dynamic> submittedItem, required Map<String, dynamic> initialValues})` returning `{'rowId': String?, 'rowToSave': Map<String, dynamic>}`. Task 4 calls this from `_saveItem`/`_deleteItem`.

- [ ] **Step 1: Write the failing test**

Create `test/child_row_to_save_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:genericsuite/services/crud_editor_commons.dart';

void main() {
  group('buildChildRowToSave', () {
    final masterConfig = {'type': 'master_listing'};

    final childArrayConfig = {
      'type': 'child_listing',
      'subType': 'array',
      'array_name': 'food_times',
      'endpointKeyNames': [
        {'parameterName': 'user_id', 'parentElementName': '_id'},
      ],
      'parentData': {'_id': 'USER1', 'firstname': 'Carlos'},
    };

    final childTableConfig = {
      'type': 'child_listing',
      'subType': 'table',
      'endpointKeyNames': [
        {'parameterName': 'user_id', 'parentElementName': '_id'},
      ],
      'parentData': {'_id': 'USER1'},
    };

    test('master_listing passes the row through unchanged', () {
      final result = buildChildRowToSave(
        editorConfig: masterConfig,
        action: actionUpdate,
        rowId: 'ROW1',
        submittedItem: {'name': 'a', 'resultset': 'junk'},
        initialValues: {'name': 'old'},
      );
      expect(result['rowId'], 'ROW1');
      expect(result['rowToSave'], {'name': 'a'}); // resultset stripped
    });

    test('child_listing/array wraps new and old values with parent key', () {
      final result = buildChildRowToSave(
        editorConfig: childArrayConfig,
        action: actionUpdate,
        rowId: 'ROW1',
        submittedItem: {'food_moment_id': 'fm2', 'food_time': '10:00'},
        initialValues: {'food_moment_id': 'fm1', 'resultset': 'junk'},
      );
      expect(result['rowId'], isNull); // array children never send a rowId
      expect(result['rowToSave'], {
        'user_id': 'USER1',
        'food_times': {'food_moment_id': 'fm2', 'food_time': '10:00'},
        'food_times_old': {'food_moment_id': 'fm1'},
      });
    });

    test('child_listing/table merges parent key into the child row', () {
      final result = buildChildRowToSave(
        editorConfig: childTableConfig,
        action: actionCreate,
        rowId: null,
        submittedItem: {'note': 'hello'},
        initialValues: {},
      );
      expect(result['rowId'], isNull);
      expect(result['rowToSave'], {'note': 'hello', 'user_id': 'USER1'});
    });

    test('child_listing/array delete sends only the old element', () {
      final result = buildChildRowToSave(
        editorConfig: childArrayConfig,
        action: actionDelete,
        rowId: 'ROW1',
        submittedItem: {'food_moment_id': 'fm1', 'food_time': '09:00'},
        initialValues: {'food_moment_id': 'fm1', 'food_time': '09:00'},
      );
      expect(result['rowId'], isNull);
      expect(
        result['rowToSave']['food_times_old'],
        {'food_moment_id': 'fm1', 'food_time': '09:00'},
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/genericsuite-mobile/genericsuite_flutter && flutter test test/child_row_to_save_test.dart`
Expected: FAIL — `buildChildRowToSave` is not defined.

- [ ] **Step 3: Write the implementation**

Append to `lib/services/crud_editor_commons.dart`:

```dart
/*
 * Build the row payload for a database write, mirroring genericsuite-fe's
 * saveRowToDatabase() child_listing handling
 * (generic.editor.rfc.formpage.jsx). For master_listing editors the row
 * passes through unchanged (minus any 'resultset' attribute).
 *
 * child_listing / subType 'array': the child rows live inside an array
 * attribute of the parent row, so the payload becomes
 *   {parentKeys..., <array_name>: submittedItem, <array_name>_old: initialValues}
 * and rowId must be null.
 *
 * child_listing / subType 'table': the child rows live in their own table,
 * so the parent key(s) are merged into the child row.
 */
Map<String, dynamic> buildChildRowToSave({
  required Map<String, dynamic> editorConfig,
  required String action,
  required String? rowId,
  required Map<String, dynamic> submittedItem,
  required Map<String, dynamic> initialValues,
}) {
  final Map<String, dynamic> rowToSave = Map<String, dynamic>.from(
    submittedItem,
  )..remove('resultset');
  final Map<String, dynamic> cleanInitialValues = Map<String, dynamic>.from(
    initialValues,
  )..remove('resultset');

  if (editorConfig['type'] != 'child_listing') {
    return {'rowId': rowId, 'rowToSave': rowToSave};
  }

  // Parent id field name(s) and value(s), from endpointKeyNames + parentData
  final Map<String, dynamic> parentKeys = {};
  for (final keyPair in (editorConfig['endpointKeyNames'] as List)) {
    parentKeys[keyPair['parameterName']] =
        editorConfig['parentData'][keyPair['parentElementName']];
  }

  if (editorConfig['subType'] == 'array') {
    final String arrayName = editorConfig['array_name'];
    if (action == actionDelete) {
      return {
        'rowId': null,
        'rowToSave': {...parentKeys, '${arrayName}_old': cleanInitialValues},
      };
    }
    return {
      'rowId': null,
      'rowToSave': {
        ...parentKeys,
        arrayName: rowToSave,
        '${arrayName}_old': cleanInitialValues,
      },
    };
  }

  // subType 'table'
  return {
    'rowId': action == actionCreate ? null : rowId,
    'rowToSave': {...rowToSave, ...parentKeys},
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/child_row_to_save_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Analyze and commit**

```bash
cd packages/genericsuite-mobile
(cd genericsuite_flutter && flutter analyze)
git add genericsuite_flutter/lib/services/crud_editor_commons.dart genericsuite_flutter/test/child_row_to_save_test.dart
git commit -m "Add: buildChildRowToSave() payload builder for child_listing editors, mirroring genericsuite-fe saveRowToDatabase [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Child component section widgets

**Files:**
- Create: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/crud_editor_child_components.dart`
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/genericsuite.dart`
- Test: `packages/genericsuite-mobile/genericsuite_flutter/test/crud_editor_child_components_test.dart`

**Interfaces:**
- Consumes: nothing from earlier tasks (standalone widgets).
- Produces:
  - `typedef ChildComponentBuilder = Widget Function({required Map<String, dynamic> parentData, Map<String, dynamic>? props});`
  - `List<Widget> buildChildComponentSections({required BuildContext context, required Map<String, dynamic> editorConfig, required Map<String, dynamic> callbacks, required Map<String, dynamic> parentData})`
  - `String childComponentLabel(String name)`
  Task 3 calls `buildChildComponentSections` from `DataFormBody`. Consumer apps register builders under `callbacks['childComponents']` keyed by the names listed in the JSON config's `"childComponents"` array.

- [ ] **Step 1: Write the failing test**

Create `test/crud_editor_child_components_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genericsuite/services/crud_editor_child_components.dart';

void main() {
  testWidgets('renders one navigation card per registered child and pushes it '
      'with parentData on tap', (tester) async {
    Map<String, dynamic>? receivedParentData;
    Map<String, dynamic>? receivedProps;

    final editorConfig = {
      'childComponents': ['UsersFoodTimes'],
    };
    final callbacks = {
      'childComponents': {
        'UsersFoodTimes':
            ({
              required Map<String, dynamic> parentData,
              Map<String, dynamic>? props,
            }) {
              receivedParentData = parentData;
              receivedProps = props;
              return const Scaffold(body: Text('CHILD SCREEN'));
            },
      },
    };
    final parentData = {'_id': 'USER1', 'firstname': 'Carlos'};

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: buildChildComponentSections(
                context: context,
                editorConfig: editorConfig,
                callbacks: callbacks,
                parentData: parentData,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Users Food Times'), findsOneWidget);

    await tester.tap(find.text('Users Food Times'));
    await tester.pumpAndSettle();

    expect(find.text('CHILD SCREEN'), findsOneWidget);
    expect(receivedParentData, parentData);
    expect(receivedProps?['isChildComponent'], true);
    expect(receivedProps?['showAppMenu'], false);
  });

  testWidgets('shows an error tile when the child builder is not registered',
      (tester) async {
    final editorConfig = {
      'childComponents': ['MissingChild'],
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: buildChildComponentSections(
                context: context,
                editorConfig: editorConfig,
                callbacks: const {},
                parentData: const {'_id': 'X'},
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      find.text('Child component [MissingChild] Not Found'),
      findsOneWidget,
    );
  });

  test('childComponentLabel splits CamelCase names', () {
    expect(childComponentLabel('UsersFoodTimes'), 'Users Food Times');
    expect(childComponentLabel('UsersApiKey'), 'Users Api Key');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/crud_editor_child_components_test.dart`
Expected: FAIL — file `crud_editor_child_components.dart` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/services/crud_editor_child_components.dart`:

```dart
import 'package:flutter/material.dart';

/*
 * Child components support for the Flutter CRUD Editor.
 *
 * Mirrors genericsuite-fe's iterateChildComponents()
 * (generic.editor.rfc.formpage.jsx): each name in the JSON config's
 * "childComponents" array is resolved against the app-supplied
 * callbacks['childComponents'] registry, and the resulting widget receives
 * the parent row as parentData. On mobile the child opens full-screen
 * (Navigator.push) instead of rendering inline below the form, because a
 * nested CrudEditor carries its own Scaffold/AppFrame.
 */

typedef ChildComponentBuilder =
    Widget Function({
      required Map<String, dynamic> parentData,
      Map<String, dynamic>? props,
    });

/*
 * 'UsersFoodTimes' -> 'Users Food Times'
 */
String childComponentLabel(String name) => name.replaceAllMapped(
  RegExp(r'(?<=[a-z0-9])(?=[A-Z])'),
  (m) => ' ',
);

/*
 * Build one tappable navigation section per child component.
 * Unregistered names render an error tile (same spirit as the fe's
 * "Component Not Found" handling).
 */
List<Widget> buildChildComponentSections({
  required BuildContext context,
  required Map<String, dynamic> editorConfig,
  required Map<String, dynamic> callbacks,
  required Map<String, dynamic> parentData,
}) {
  final Map<String, dynamic> registry = Map<String, dynamic>.from(
    callbacks['childComponents'] ?? {},
  );
  return List<Widget>.from(
    (editorConfig['childComponents'] as List).map((name) {
      final dynamic builder = registry[name];
      if (builder == null) {
        return ListTile(
          key: ValueKey('childComponent_$name'),
          leading: const Icon(Icons.error_outline, color: Colors.red),
          title: Text('Child component [$name] Not Found'),
        );
      }
      return Card(
        key: ValueKey('childComponent_$name'),
        child: ListTile(
          title: Text(childComponentLabel(name)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => builder(
                  parentData: parentData,
                  props: {'isChildComponent': true, 'showAppMenu': false},
                ),
              ),
            );
          },
        ),
      );
    }),
  );
}
```

In `lib/genericsuite.dart`, add (keeping alphabetical order) after the `export 'services/crud_editor.dart';` line:

```dart
export 'services/crud_editor_child_components.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/crud_editor_child_components_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Analyze and commit**

```bash
cd packages/genericsuite-mobile
(cd genericsuite_flutter && flutter analyze)
git add genericsuite_flutter/lib/services/crud_editor_child_components.dart genericsuite_flutter/lib/genericsuite.dart genericsuite_flutter/test/crud_editor_child_components_test.dart
git commit -m "Add: childComponents navigation sections for the Flutter CRUD Editor [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Render child sections in `DataFormBody`

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/form_field_service.dart`
- Test: extend `packages/genericsuite-mobile/genericsuite_flutter/test/crud_editor_child_components_test.dart`

**Interfaces:**
- Consumes: `buildChildComponentSections()` (Task 2); `actionUpdate` from `crud_editor_commons.dart`.
- Produces: `DataFormBody` now shows child sections when `action == actionUpdate` and the config has child components. No signature change — `DataFormBody` already receives `editorConfig`, `callbacks`, `selectedItem`, `action`.

- [ ] **Step 1: Write the failing test**

Append to `test/crud_editor_child_components_test.dart` (add the imports at top of file):

```dart
import 'package:genericsuite/services/crud_editor_commons.dart';
import 'package:genericsuite/services/form_field_service.dart';
```

```dart
  Widget dataFormApp(String action) {
    final editorConfig = {
      'fieldElements': [
        {
          'name': 'firstname',
          'label': 'First Name',
          'type': 'text',
          'required': false,
          'readonly': false,
        },
      ],
      'childComponents': ['UsersFoodTimes'],
    };
    final callbacks = {
      'childComponents': {
        'UsersFoodTimes':
            ({
              required Map<String, dynamic> parentData,
              Map<String, dynamic>? props,
            }) => const Scaffold(body: Text('CHILD SCREEN')),
      },
    };
    return MaterialApp(
      home: Scaffold(
        body: DataFormBody(
          editorConfig: editorConfig,
          constants: const {},
          selectedItem: {'_id': 'USER1', 'firstname': 'Carlos'},
          callbacks: callbacks,
          currentUserData: const {},
          action: action,
          saveItem: (item) {},
          setEditMode: (mode) {},
          setError: (msg, code, [severity = 0]) {},
        ),
      ),
    );
  }

  testWidgets('DataFormBody shows child sections in update mode',
      (tester) async {
    await tester.pumpWidget(dataFormApp(actionUpdate));
    expect(find.text('Users Food Times'), findsOneWidget);
  });

  testWidgets('DataFormBody hides child sections in create mode',
      (tester) async {
    await tester.pumpWidget(dataFormApp(actionCreate));
    expect(find.text('Users Food Times'), findsNothing);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/crud_editor_child_components_test.dart`
Expected: the two new tests FAIL (`Users Food Times` not found in update mode).

- [ ] **Step 3: Write the implementation**

In `lib/services/form_field_service.dart`:

1. Add imports at the top (after the existing `import 'autocomplete_service.dart';` block):

```dart
import 'crud_editor_child_components.dart';
import 'crud_editor_commons.dart';
```

2. In `_buildDataFormBody()`, immediately AFTER the `formFields.add(Center(child: Row(...Save/Cancel...)))` block and BEFORE `return Form(`, insert:

```dart
    // Child components (1-N relationships), like genericsuite-fe's
    // iterateChildComponents(): only when editing an existing row.
    final List childComponents =
        widget.editorConfig['childComponents'] ?? const [];
    if (widget.action == actionUpdate && childComponents.isNotEmpty) {
      formFields.add(const SizedBox(height: 24));
      formFields.add(const Divider());
      formFields.addAll(
        buildChildComponentSections(
          context: context,
          editorConfig: widget.editorConfig,
          callbacks: widget.callbacks,
          parentData: widget.selectedItem,
        ),
      );
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/crud_editor_child_components_test.dart`
Expected: PASS (all tests, including the two new ones).

- [ ] **Step 5: Analyze and commit**

```bash
cd packages/genericsuite-mobile
(cd genericsuite_flutter && flutter analyze)
git add genericsuite_flutter/lib/services/form_field_service.dart genericsuite_flutter/test/crud_editor_child_components_test.dart
git commit -m "Add: render childComponents sections in the CRUD Editor edit form [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: CrudEditor integration — child-listing save/delete + back navigation

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/crud_editor.dart`

**Interfaces:**
- Consumes: `buildChildRowToSave()` (Task 1); existing `_setEndpointFilter()`, `rowId()`, `_runApiCall()`.
- Produces: `CrudEditor` accepts `props: {'parentData': ..., 'isChildComponent': true, 'showAppMenu': false}` (the exact props Task 2's sections pass) and behaves correctly as a pushed child screen. No public signature changes.

- [ ] **Step 1: Keep a copy of the originally loaded row**

In `CrudEditorState` (near the other state fields, after `dynamic selectedItem;` at `crud_editor.dart:55`), add:

```dart
  Map<String, dynamic> originalSelectedItem = {};
```

In `_loadSelectedItem()`, right before the final `return itemData;` (after `isEditMode = true;`), add:

```dart
    // Keep a deep copy of the loaded row: child_listing 'array' writes need
    // the initial values ('<array_name>_old') to locate the old element.
    originalSelectedItem = Map<String, dynamic>.from(
      json.decode(json.encode(itemData)),
    );
```

In `build()`'s `floatingActionButton` `onPressed` (the creation path, `crud_editor.dart:1886-1890`) and in the `isCreationForced` path inside `_loadConfig()` (`crud_editor.dart:678-688`), add `originalSelectedItem = {};` next to `selectedItem = _getEmptyItem();` in both places.

- [ ] **Step 2: Use the child payload in `_saveItem`**

In `_saveItem()`, replace the API call block:

```dart
    final localApiResp = await _runApiCall(
      urlGenSuffix,
      (isCreation ? 'post' : 'put'),
      item,
      {},
    );
```

with:

```dart
    // Build the payload: pass-through for master_listing, wrapped payload
    // for child_listing editors (parent keys, array/_old handling).
    final Map<String, dynamic> childPayload = buildChildRowToSave(
      editorConfig: editorConfig,
      action: isCreation ? actionCreate : actionUpdate,
      rowId: isCreation ? null : rowId(item),
      submittedItem: item,
      initialValues: originalSelectedItem,
    );
    final localApiResp = await _runApiCall(
      urlGenSuffix,
      (isCreation ? 'post' : 'put'),
      childPayload['rowToSave'],
      {},
    );
```

Then guard the id assignment (the API may not return `_id` for array children). Replace:

```dart
    // Update item id with the one returned by the API
    item['id'] = localApiResp['resultset']['_id'];
```

with:

```dart
    // Update item id with the one returned by the API
    if (localApiResp['resultset'] is Map &&
        localApiResp['resultset']['_id'] != null) {
      item['id'] = localApiResp['resultset']['_id'];
    }
```

- [ ] **Step 3: Use the child payload in `_deleteItem`**

In `_deleteItem()`, replace:

```dart
    // Delete item from database (API)
    Map<String, dynamic> body = {'id': itemId};
    Map<String, dynamic> getParams = {'id': itemId};
```

with:

```dart
    // Delete item from database (API). child_listing editors send the
    // wrapped payload (parent keys + '<array_name>_old' for 'array').
    Map<String, dynamic> body = {'id': itemId};
    Map<String, dynamic> getParams = {'id': itemId};
    if (editorConfig['type'] == 'child_listing') {
      final Map<String, dynamic> childPayload = buildChildRowToSave(
        editorConfig: editorConfig,
        action: actionDelete,
        rowId: itemId,
        submittedItem: Map<String, dynamic>.from(selectedItem),
        initialValues: originalSelectedItem,
      );
      body = childPayload['rowToSave'];
      if (editorConfig['subType'] == 'array') {
        getParams = fixMapString(editorConfig['endpointFilter']);
      }
    }
```

- [ ] **Step 4: Back navigation for pushed child screens**

In `build()` (`crud_editor.dart:1846`), before the `return AppFrame(` statement add:

```dart
    final bool isChildComponent =
        widget.props != null && (widget.props!['isChildComponent'] ?? false);
```

Then change the `AppFrame` arguments `showBackButton:` and `action:` from:

```dart
      showBackButton:
          !showAppMenu && (widget.backButtonAction != null || isEditMode),
      action: widget.backButtonAction == null
          ? isEditMode
                ? () => _setEditMode(false)
                : null
          : () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => widget.backButtonAction!(),
              ),
            ),
```

to:

```dart
      showBackButton:
          !showAppMenu &&
          (widget.backButtonAction != null || isEditMode || isChildComponent),
      action: widget.backButtonAction == null
          ? isEditMode
                ? () => _setEditMode(false)
                : isChildComponent
                ? () => Navigator.pop(context)
                : null
          : () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => widget.backButtonAction!(),
              ),
            ),
```

(Behavior: inside a pushed child, the back button leaves the edit form first — `_setEditMode(false)` — and pops back to the parent form from the child listing.)

- [ ] **Step 5: Verify parentData wiring already works**

Confirm (read, no change needed) that `_setEditorConfig()` calls `_setEndpointFilter(widget.props!['parentData'])` when `type == 'child_listing'` and `widget.props` contains `parentData` (`crud_editor.dart:522-524`). This is what filters the child listing by the parent row.

- [ ] **Step 6: Run all tests and analyze**

Run: `flutter test && flutter analyze`
Expected: all tests PASS, analyze reports no issues.

- [ ] **Step 7: Commit**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/lib/services/crud_editor.dart
git commit -m "Add: child_listing save/delete payloads and child-screen back navigation in CrudEditor [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Mobile README — childComponents usage docs

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/README.md`

- [ ] **Step 1: Update the childComponents callbacks example**

Find the `"childComponents": { ... }` block inside the `ExampleappAnyOtherCrudEditorViewState` example (around line 842) and replace the old builder signature with the new contract:

```dart
      "childComponents": {
        "ExampleappAnyOtherChildComponent": ({
          required Map<String, dynamic> parentData,
          Map<String, dynamic>? props,
        }) =>
            CrudEditor(
              jsonFileName: 'exampleapp_any_other_child_table.json',
              callbacks: AppCallables().getUserCallbacks(context),
              props: {...?props, 'parentData': parentData},
            ),
      }
```

- [ ] **Step 2: Add a "Child components (1-N relationships)" section**

After the section that documents the CRUD editor JSON config (the one containing the `"childComponents": [` example around line 333), add:

```markdown
### Child components (1-N relationships)

When a frontend JSON config declares `"childComponents": ["SomeChild"]`, the
CRUD editor renders one tappable section per child at the bottom of the edit
form (edit mode only, never on creation). Tapping a section opens the child
editor full-screen with the parent row passed as `parentData`.

Each name must be registered in the `callbacks['childComponents']` map with a
builder of type:

```dart
typedef ChildComponentBuilder = Widget Function({
  required Map<String, dynamic> parentData,
  Map<String, dynamic>? props,
});
```

The builder normally returns a `CrudEditor` whose JSON config has
`"type": "child_listing"`, a `"subType"` of `"array"` (child rows stored in an
array attribute of the parent row, requires `"array_name"`) or `"table"`
(child rows in their own table), and `"endpointKeyNames"` mapping the API
parameter name to the parent's id field:

```json
{
    "type": "child_listing",
    "subType": "array",
    "array_name": "food_times",
    "endpointKeyNames": [
        {"parameterName": "user_id", "parentElementName": "_id"}
    ]
}
```

Spread the received `props` into the `CrudEditor` `props` (they carry
`isChildComponent: true` and `showAppMenu: false`, which enable the back
button on the pushed screen) and add `'parentData': parentData`.
```

- [ ] **Step 3: Commit**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/README.md
git commit -m "Add: childComponents usage documentation in genericsuite_flutter README [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Dependencies + version bump

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/pubspec.yaml`

- [ ] **Step 1: Bump version and add dependencies**

```bash
cd packages/genericsuite-mobile/genericsuite_flutter
flutter pub add shadcn_ui google_fonts
```

Then edit `pubspec.yaml`: change `version: 0.4.1` to `version: 0.5.0`. Keep the versions `flutter pub add` resolved (do not hand-pin different ones).

- [ ] **Step 2: Verify resolution**

Run: `flutter pub get && flutter analyze`
Expected: no errors. (If `shadcn_ui` demands a newer Flutter/Dart SDK than `^3.10.7`, adjust the `environment.sdk` floor in `pubspec.yaml` to the minimum shadcn_ui requires and note it for the CHANGELOG — do not silence the error any other way.)

- [ ] **Step 3: Commit**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/pubspec.yaml genericsuite_flutter/pubspec.lock
git commit -m "Add: shadcn_ui and google_fonts dependencies; bump genericsuite_flutter to 0.5.0 [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Apple-clean theme tokens + `getThemeParams()` contract

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/theme_config_defaults.dart`
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/app_callables_super.dart`
- Test: `packages/genericsuite-mobile/genericsuite_flutter/test/theme_params_test.dart`
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/test/genericsuite_test.dart` (fix broken assertion)

**Interfaces:**
- Produces: token constants (`accentColor`, `borderRadius`, `gsFontFamily`, `textColor`, `secondaryTextColor`, `separatorColor`, `neutralSurfaceColor`, updated semantic colors) and `Map<String, dynamic> defaultThemeParams`. `AppCallablesSuper.getThemeParams()` returns a copy of `defaultThemeParams`. Task 8 reads these via `{...defaultThemeParams, ...appCallables.getThemeParams()}`.

- [ ] **Step 1: Write the failing test**

Create `test/theme_params_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genericsuite/genericsuite.dart';

void main() {
  test('defaultThemeParams carries the Apple-clean design tokens', () {
    expect(defaultThemeParams['accentColor'], Colors.green);
    expect(defaultThemeParams['borderRadius'], 12.0);
    expect(defaultThemeParams['fontFamily'], 'Inter');
    expect(defaultThemeParams['textTheme'], isNull);
    expect(defaultThemeParams['textColor'], const Color(0xFF111111));
    expect(defaultThemeParams['scaffoldBackgroundColor'], Colors.white);
    expect(defaultThemeParams['appBarBackgroundColor'], Colors.white);
    // iOS system semantic colors
    expect(defaultThemeParams['errorBackgroundColor'], const Color(0xFFFF3B30));
    expect(defaultThemeParams['infoBackgroundColor'], const Color(0xFF007AFF));
    expect(
      defaultThemeParams['warningBackgroundColor'],
      const Color(0xFFFF9500),
    );
    expect(
      defaultThemeParams['successBackgroundColor'],
      const Color(0xFF34C759),
    );
    expect(defaultThemeParams['closeButtonPlacement'], 'bottom');
  });

  test('getThemeParams() returns the defaults and keeps the legacy keys', () {
    final params = AppCallablesSuper().getThemeParams();
    for (final key in defaultThemeParams.keys) {
      expect(params.containsKey(key), true, reason: 'missing key: $key');
    }
    // Legacy keys still present for existing consumer apps
    expect(params.containsKey('primarySwatch'), true);
    expect(params.containsKey('drawerBackgroundColor'), true);
  });
}
```

Also fix `test/genericsuite_test.dart` — the existing assertion is malformed (`expect(x == primarySwatch, 3)`). Replace the whole file with:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:genericsuite/genericsuite.dart';

void main() {
  test('AppCallablesSuper class', () {
    final appCallablesInstance = AppCallablesSuper();
    expect(
      appCallablesInstance.getThemeParams()['primarySwatch'],
      primarySwatch,
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/theme_params_test.dart`
Expected: FAIL — `defaultThemeParams` and the new tokens are not defined.

- [ ] **Step 3: Rewrite `theme_config_defaults.dart`**

Replace the full content of `lib/services/theme_config_defaults.dart` with:

```dart
import 'package:flutter/material.dart';

// GenericSuite Mobile default theme tokens [GS-261].
//
// Design language: Apple-clean — white/neutral surfaces, near-black text,
// ONE accent color, 12 px corner radius, iOS system semantic colors.
// Typography intent: Inter (via google_fonts) for an SF-Pro-like feel.
//
// Consumer apps override AppCallablesSuper.getThemeParams(); CreateGsApp
// merges that map OVER defaultThemeParams, so apps may return only the keys
// they want to change.

const MaterialColor accentColor = Colors.green;
const double borderRadius = 12.0;

// Typography tokens. 'Inter' triggers GoogleFonts.interTextTheme() in
// CreateGsApp; any other family name is applied verbatim. An app can also
// provide a full TextTheme via the 'textTheme' theme param (null = derive
// from fontFamily).
const String gsFontFamily = 'Inter';

const Color textColor = Color(0xFF111111); // near-black
const Color secondaryTextColor = Color(0xFF6E6E73); // iOS secondary label
const Color separatorColor = Color(0xFFD1D1D6); // iOS separator
const Color neutralSurfaceColor = Color(0xFFF2F2F7); // iOS systemGray6

// Legacy token, superseded by accentColor. Kept because existing apps
// reference it in their getThemeParams() overrides.
const MaterialColor primarySwatch = accentColor;
const Color scaffoldBackgroundColor = Colors.white;

const Color appBarBackgroundColor = Colors.white;
const Color appBarForegroundColor = textColor;

const Color drawerBackgroundColor = Colors.white;
const Color drawerForegroundColor = textColor;

// iOS system semantic colors
const Color errorBackgroundColor = Color(0xFFFF3B30); // systemRed
const Color errorForegroundColor = Colors.white;
const Color infoBackgroundColor = Color(0xFF007AFF); // systemBlue
const Color infoForegroundColor = Colors.white;
const Color warningBackgroundColor = Color(0xFFFF9500); // systemOrange
const Color warningForegroundColor = Colors.white;
const Color successBackgroundColor = Color(0xFF34C759); // systemGreen
const Color successForegroundColor = Colors.white;

const String closeButtonPlacement = "bottom"; // "bottom" or "right"

const Map<String, dynamic> defaultThemeParams = {
  'accentColor': accentColor,
  'borderRadius': borderRadius,
  'fontFamily': gsFontFamily,
  'textTheme': null, // TextTheme? — app-provided full text theme
  'textColor': textColor,
  'secondaryTextColor': secondaryTextColor,
  'separatorColor': separatorColor,
  'neutralSurfaceColor': neutralSurfaceColor,
  'primarySwatch': primarySwatch,
  'scaffoldBackgroundColor': scaffoldBackgroundColor,
  'appBarBackgroundColor': appBarBackgroundColor,
  'appBarForegroundColor': appBarForegroundColor,
  'drawerBackgroundColor': drawerBackgroundColor,
  'drawerForegroundColor': drawerForegroundColor,
  'errorBackgroundColor': errorBackgroundColor,
  'errorForegroundColor': errorForegroundColor,
  'infoBackgroundColor': infoBackgroundColor,
  'infoForegroundColor': infoForegroundColor,
  'warningBackgroundColor': warningBackgroundColor,
  'warningForegroundColor': warningForegroundColor,
  'successBackgroundColor': successBackgroundColor,
  'successForegroundColor': successForegroundColor,
  'closeButtonPlacement': closeButtonPlacement,
};
```

Note: the constant is named `gsFontFamily` (not `fontFamily`) to avoid
shadowing the common `fontFamily` parameter name at call sites; the **map
key** exposed to apps is still `'fontFamily'`.

- [ ] **Step 4: Update `AppCallablesSuper.getThemeParams()`**

In `lib/services/app_callables_super.dart`, replace the whole `getThemeParams()` method body with:

```dart
  /*
   * Get the theme parameters. Override in the app's AppCallables to
   * customize; only the keys you return are changed — CreateGsApp merges
   * this map over defaultThemeParams.
   */
  Map<String, dynamic> getThemeParams() {
    return Map<String, dynamic>.from(defaultThemeParams);
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test`
Expected: PASS (including `theme_params_test.dart` and the fixed `genericsuite_test.dart`).

- [ ] **Step 6: Analyze and commit**

```bash
cd packages/genericsuite-mobile
(cd genericsuite_flutter && flutter analyze)
git add genericsuite_flutter/lib/services/theme_config_defaults.dart genericsuite_flutter/lib/services/app_callables_super.dart genericsuite_flutter/test/theme_params_test.dart genericsuite_flutter/test/genericsuite_test.dart
git commit -m "Change: Apple-clean theme tokens (accentColor green, 12px radius, Inter typography token, iOS semantic colors) and defaultThemeParams merge contract [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: `CreateGsApp` — ShadApp root + Material theme from tokens

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/create_gs_app.dart`

**Interfaces:**
- Consumes: `defaultThemeParams` and token constants (Task 7); `shadcn_ui` + `google_fonts` (Task 6).
- Produces: `ThemeData buildGsMaterialTheme(Map<String, dynamic> tp)` (top-level function, exported via the existing `create_gs_app.dart` export) and a `ShadApp.custom` root. `CreateGsApp`'s public constructor is unchanged.

- [ ] **Step 1: Add imports**

At the top of `lib/services/create_gs_app.dart`, add:

```dart
import 'package:google_fonts/google_fonts.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:genericsuite/services/theme_config_defaults.dart';
```

- [ ] **Step 2: Add the theme builder**

Add this top-level function to `create_gs_app.dart` (below the `loginInitialParams` const):

```dart
/*
 * Build the MaterialApp ThemeData from the GenericSuite theme tokens
 * (defaultThemeParams merged with the app's getThemeParams()) [GS-261].
 */
ThemeData buildGsMaterialTheme(Map<String, dynamic> tp) {
  final Color accent = tp['accentColor'] ?? accentColor;
  final double radius = ((tp['borderRadius'] ?? borderRadius) as num)
      .toDouble();
  final Color text = tp['textColor'] ?? textColor;
  final Color separator = tp['separatorColor'] ?? separatorColor;
  final BorderRadius corners = BorderRadius.circular(radius);

  TextTheme baseTextTheme;
  if (tp['textTheme'] != null) {
    baseTextTheme = tp['textTheme'];
  } else if ((tp['fontFamily'] ?? gsFontFamily) == 'Inter') {
    baseTextTheme = GoogleFonts.interTextTheme();
  } else {
    baseTextTheme = Typography.blackCupertino.apply(
      fontFamily: tp['fontFamily'],
    );
  }
  baseTextTheme = baseTextTheme.apply(bodyColor: text, displayColor: text);

  return ThemeData(
    useMaterial3: true,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.light,
        ).copyWith(
          surface: tp['scaffoldBackgroundColor'] ?? scaffoldBackgroundColor,
          error: tp['errorBackgroundColor'] ?? errorBackgroundColor,
        ),
    scaffoldBackgroundColor:
        tp['scaffoldBackgroundColor'] ?? scaffoldBackgroundColor,
    textTheme: baseTextTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: tp['appBarBackgroundColor'] ?? appBarBackgroundColor,
      foregroundColor: tp['appBarForegroundColor'] ?? appBarForegroundColor,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: corners,
        borderSide: BorderSide(color: separator),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: corners,
        borderSide: BorderSide(color: separator),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: corners,
        borderSide: BorderSide(color: accent, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 12,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size(88, 44),
        shape: RoundedRectangleBorder(borderRadius: corners),
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: corners,
        side: BorderSide(color: separator),
      ),
      margin: const EdgeInsets.symmetric(vertical: 4),
    ),
    dividerTheme: DividerThemeData(color: separator, thickness: 0.5),
    listTileTheme: ListTileThemeData(
      iconColor: tp['secondaryTextColor'] ?? secondaryTextColor,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: tp['drawerBackgroundColor'] ?? drawerBackgroundColor,
    ),
  );
}
```

(If `flutter analyze` reports that `cardTheme` expects `CardTheme` instead of `CardThemeData` on the pinned Flutter SDK, use `CardTheme` with the same arguments — that is the only accepted substitution.)

- [ ] **Step 3: Make `ShadApp` own the widget-tree root**

In `CreateGsAppState.build()`, replace the `return MaterialApp(...)` expression so `ShadApp.custom` wraps the existing MaterialApp. The new `build` body:

```dart
  @override
  Widget build(BuildContext context) {
    Map<String, dynamic> appInfo = appCallables.getAppInfo();
    final Map<String, dynamic> tp = {
      ...defaultThemeParams,
      ...appCallables.getThemeParams(),
    };
    return ShadApp.custom(
      themeMode: ThemeMode.light,
      theme: ShadThemeData(
        brightness: Brightness.light,
        colorScheme: const ShadGreenColorScheme.light(),
        radius: BorderRadius.circular(
          ((tp['borderRadius'] ?? borderRadius) as num).toDouble(),
        ),
      ),
      appBuilder: (context) {
        return MaterialApp(
          title: '${appInfo['name']}: ${appInfo['description']}',
          theme: buildGsMaterialTheme(tp),
          home: FutureBuilder(
            // ... keep the existing FutureBuilder exactly as it is today ...
          ),
        );
      },
    );
  }
```

Keep the whole existing `FutureBuilder(...)` block (from `future: initEnvironmentAndGetJwt` down to its closing parenthesis) verbatim — only the surrounding `MaterialApp` theme arguments change (the old `theme: ThemeData(primarySwatch: ..., scaffoldBackgroundColor: ..., appBarTheme: ...)` block is deleted, replaced by `theme: buildGsMaterialTheme(tp)`).

API fallback (only if `flutter analyze` fails on the exact `ShadApp.custom` signature of the resolved shadcn_ui version): open the installed package source with `find ~/.pub-cache -maxdepth 4 -type d -name "shadcn_ui-*"` and read `lib/src/app.dart` to match the constructor — the requirement that must survive any adaptation is: **ShadApp is the root widget, the MaterialApp is built inside it via its builder parameter, and `buildGsMaterialTheme(tp)` provides the Material theme.**

- [ ] **Step 4: Run tests and analyze**

Run: `flutter test && flutter analyze`
Expected: PASS / no issues.

- [ ] **Step 5: Commit**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/lib/services/create_gs_app.dart
git commit -m "Change: ShadApp.custom owns the widget-tree root and CreateGsApp builds the Material theme from GenericSuite tokens [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Widget polish — Shad buttons, AppFrame, form spacing

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/form_field_service.dart`
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/widgets/app_frame.dart`

- [ ] **Step 1: Replace the Save/Cancel buttons with shadcn_ui buttons**

In `lib/services/form_field_service.dart` add the import:

```dart
import 'package:shadcn_ui/shadcn_ui.dart';
```

Replace the Save/Cancel `Center(child: Row(...))` block (the two `ElevatedButton`s) with:

```dart
    formFields.add(
      Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ShadButton(
              child: const Text('Save'),
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  formKey.currentState!.save();
                  widget.saveItem(widget.selectedItem);
                }
              },
            ),
            const SizedBox(width: 20),
            ShadButton.outline(
              child: const Text('Cancel'),
              onPressed: () {
                widget.setEditMode(false);
              },
            ),
          ],
        ),
      ),
    );
```

Also change the form padding from `padding: const EdgeInsets.all(8.0)` to `padding: const EdgeInsets.all(16.0)` in the `ListView` inside `return Form(`.

(If `flutter analyze` rejects `ShadButton`'s `child:` parameter name on the resolved shadcn_ui version — some versions use `text:` — match the installed API; keep one filled primary button and one outline secondary button.)

- [ ] **Step 2: Apple-clean AppFrame**

In `lib/widgets/app_frame.dart`, the AppBar already inherits the new `appBarTheme` (white, near-black, no elevation) from Task 8 — verify no hardcoded colors remain in this file (there are none today; just confirm). Change the title `Text(title!)` to add iOS-style weight:

```dart
        title: title != null
            ? Text(
                title!,
                style: const TextStyle(fontWeight: FontWeight.w600),
              )
            : Image.asset(
                'assets/images/app_logo_horizontal.png',
                fit: BoxFit.contain,
                height: 32,
              ),
```

- [ ] **Step 3: Run tests and analyze**

Run: `flutter test && flutter analyze`
Expected: PASS / no issues. Note: the DataFormBody widget tests from Task 3 pump a plain `MaterialApp`; if `ShadButton` requires a `ShadTheme` ancestor and the tests fail with a missing-theme error, wrap the test harness widget in the minimal Shad wrapper the package README prescribes (e.g. `ShadApp.custom(appBuilder: (context) => MaterialApp(home: ...))`) inside `dataFormApp()` in `test/crud_editor_child_components_test.dart`.

- [ ] **Step 4: Manual smoke check via the template app (best effort)**

```bash
cd packages/genericsuite-mobile/flutter_project_template
flutter pub get && flutter analyze
```
Expected: dependency resolution succeeds against the local library. If the template's `pubspec.yaml` pins `genericsuite` via git ref, this only proves the template itself still analyzes — note the result either way in the task report. Do NOT attempt `flutter run` (needs a device/simulator and backend).

- [ ] **Step 5: Commit**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/lib/services/form_field_service.dart genericsuite_flutter/lib/widgets/app_frame.dart
git commit -m "Change: shadcn_ui Save/Cancel buttons and Apple-clean form/AppBar polish [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: GS Basecamp documentation (haiku sub-agent OK)

**Files:**
- Create: `packages/genericsuite-basecamp/mkdocs_root/en/Mobile-Development/index.md`
- Modify: `packages/genericsuite-basecamp/mkdocs.yml`
- Modify: `packages/genericsuite-basecamp/CHANGELOG.md`

- [ ] **Step 1: Create the Mobile Development docs page**

Create `packages/genericsuite-basecamp/mkdocs_root/en/Mobile-Development/index.md` with exactly this content:

```markdown
# GenericSuite Mobile (Flutter)

[GenericSuite Mobile](https://github.com/tomkat-cr/genericsuite-mobile) brings
the GenericSuite JSON-driven CRUD pattern to Flutter apps: define your
entities in JSON config files and mount the `CrudEditor` widget — no
per-entity Dart code needed for standard CRUD.

Repository layout:

- `genericsuite_flutter/` — the reusable Flutter library (consumed as a Git
  dependency).
- `flutter_project_template/` — a starter app template showing real-world
  usage.

## Installation

Add the library to your app's `pubspec.yaml`:

```yaml
dependencies:
  genericsuite:
    git:
      url: https://github.com/tomkat-cr/genericsuite-mobile.git
      path: genericsuite_flutter
      ref: main
```

## App bootstrap

Subclass `AppCallablesSuper` to inject your app's behavior, then start the
app with `CreateGsApp`:

```dart
void main() {
  runApp(CreateGsApp(appCallables: AppCallables()));
}
```

`CreateGsApp` builds the widget-tree root with `ShadApp`
([shadcn_ui](https://pub.dev/packages/shadcn_ui), the Flutter port of
ShadCN) and derives the `MaterialApp` theme from the GenericSuite theme
tokens (see [Theming](#theming)).

## JSON-driven CRUD

Configuration files live under `assets/`:

- `assets/config/stage.json` — selects the environment (`dev`, `qa`,
  `staging`, `prod`).
- `assets/config/config-{stage}.json` — API base URL and other values.
- `assets/config_dbdef/backend/*.json` — REST endpoint + schema definitions.
- `assets/config_dbdef/frontend/*.json` — field types, labels, form layout.

Mount an editor:

```dart
CrudEditor(
  jsonFileName: 'users.json',
  callbacks: callbacks,
  props: props,
)
```

## Child components (1-N relationships)

The Flutter CRUD Editor handles `childComponents` the same way the
genericsuite-fe (React) CRUD Editor does: the frontend JSON config of a
parent entity lists child component names, and each one renders inside the
parent's edit form.

Parent config (`assets/config_dbdef/frontend/users.json`):

```json
{
    "childComponents": [
        "UsersFoodTimes"
    ]
}
```

On mobile, each child appears as a tappable section at the bottom of the
parent's **edit** form (never on creation). Tapping opens the child editor
full-screen with the parent row passed as `parentData`.

Register a builder for each name in the `callbacks['childComponents']` map:

```dart
Map<String, dynamic> callbacks = {
  "childComponents": {
    "UsersFoodTimes": ({
      required Map<String, dynamic> parentData,
      Map<String, dynamic>? props,
    }) =>
        CrudEditor(
          jsonFileName: 'users_food_times.json',
          callbacks: AppCallables().getUserCallbacks(context),
          props: {...?props, 'parentData': parentData},
        ),
  },
};
```

The child JSON config declares the relationship:

```json
{
    "type": "child_listing",
    "subType": "array",
    "array_name": "food_times",
    "endpointKeyNames": [
        {"parameterName": "user_id", "parentElementName": "_id"}
    ]
}
```

- `subType: "array"` — child rows live inside an array attribute of the
  parent row (`array_name` required). Writes send
  `{parentKey, <array_name>: newValues, <array_name>_old: initialValues}`.
- `subType: "table"` — child rows live in their own table; the parent key is
  merged into each child row.

## Theming

The design language is Apple-clean: white/neutral surfaces, near-black text,
one accent color (default `Colors.green`), 12 px corner radius, and iOS
system semantic colors.

Override `getThemeParams()` in your `AppCallables` to customize — return
only the keys you want to change; they are merged over the library defaults
(`defaultThemeParams` in `theme_config_defaults.dart`):

| Token | Default | Purpose |
| --- | --- | --- |
| `accentColor` | `Colors.green` | The single accent color |
| `borderRadius` | `12.0` | Corner radius (px) for inputs, buttons, cards |
| `fontFamily` | `'Inter'` | Typography; `'Inter'` loads via google_fonts (SF-Pro-like) |
| `textTheme` | `null` | Optional full `TextTheme` override |
| `textColor` | `#111111` | Near-black primary text |
| `secondaryTextColor` | `#6E6E73` | iOS secondary label |
| `separatorColor` | `#D1D1D6` | iOS separator (borders, dividers) |
| `neutralSurfaceColor` | `#F2F2F7` | iOS systemGray6 neutral surface |
| `scaffoldBackgroundColor` | `Colors.white` | Screen background |
| `appBarBackgroundColor` / `appBarForegroundColor` | white / near-black | App bar surfaces |
| `errorBackgroundColor` | `#FF3B30` (systemRed) | Error messages |
| `infoBackgroundColor` | `#007AFF` (systemBlue) | Info messages |
| `warningBackgroundColor` | `#FF9500` (systemOrange) | Warnings |
| `successBackgroundColor` | `#34C759` (systemGreen) | Success messages |

Example:

```dart
class AppCallables extends AppCallablesSuper {
  @override
  Map<String, dynamic> getThemeParams() {
    return {
      'accentColor': Colors.indigo,
      'fontFamily': 'Inter',
    };
  }
}
```

## More information

- Library README:
  [genericsuite_flutter](https://github.com/tomkat-cr/genericsuite-mobile/tree/main/genericsuite_flutter)
- Starter template:
  [flutter_project_template](https://github.com/tomkat-cr/genericsuite-mobile/tree/main/flutter_project_template)
```

- [ ] **Step 2: Add the nav entry**

In `packages/genericsuite-basecamp/mkdocs.yml`, insert after the `- 'Frontend Development':` block (i.e. after the `- 'Deployment': './Frontend-Development/deployment.md'` line) and before `- 'Backend Development':`:

```yaml
  - 'Mobile Development':
    - 'GenericSuite Flutter': './Mobile-Development/index.md'
```

- [ ] **Step 3: Basecamp CHANGELOG entry**

In `packages/genericsuite-basecamp/CHANGELOG.md`, under the topmost `## [Unreleased]` section's `### Added` heading, add:

```markdown
- Mobile Development documentation section: GenericSuite Flutter installation, JSON-driven CRUD, childComponents (1-N relationships), and the Apple-clean theming tokens [GS-261].
```

(If the file has no `[Unreleased]` section, create one at the top matching the file's existing heading style.)

- [ ] **Step 4: Verify and commit**

```bash
cd packages/genericsuite-basecamp
python3 -c "import yaml; yaml.safe_load(open('mkdocs.yml'))" && echo YAML-OK
git add mkdocs.yml mkdocs_root/en/Mobile-Development/index.md CHANGELOG.md
git commit -m "Add: Mobile Development documentation (GenericSuite Flutter, childComponents, theming) [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

(If `yaml` is missing, `pip3 install pyyaml` or verify indentation visually against the neighboring nav entries.)

---

### Task 11: CHANGELOGs + activeContext + final verification (haiku sub-agent OK)

**Files:**
- Modify: `packages/genericsuite-mobile/CHANGELOG.md`
- Modify: `CHANGELOG.md` (superproject root)
- Modify: `docs/activeContext.md` (superproject root)

- [ ] **Step 1: Mobile CHANGELOG**

In `packages/genericsuite-mobile/CHANGELOG.md`, under the topmost `## [Unreleased] - YYYY-MM-DD` section, add these lines under `### Added`:

```markdown
- `childComponents` (1-N relationships) support in the Flutter CRUD Editor: child components declared in the frontend JSON config render as tappable sections in the edit form, open full-screen with the parent row as `parentData`, and support `child_listing` editors with `array` and `table` subtypes (including the `<array_name>`/`<array_name>_old` write payloads), matching the genericsuite-fe CRUD Editor behavior [GS-261].
- Apple-clean theme tokens in `theme_config_defaults.dart` (`accentColor`, `borderRadius` 12px, `fontFamily`/`textTheme` typography tokens with Inter via google_fonts, near-black `textColor`, iOS system semantic colors) plus a `defaultThemeParams` merge contract so apps override only the keys they need [GS-261].
- `shadcn_ui` (flutter-shadcn-ui port) now owns the widget-tree root via `ShadApp.custom`; `CreateGsApp` builds the MaterialApp theme from the GenericSuite tokens; Save/Cancel form buttons use ShadButton [GS-261].
```

And under `### Changed`:

```markdown
- Default accent color changed from blue to green; app bar and drawer default to white surfaces with near-black text; genericsuite_flutter version bumped to 0.5.0 [GS-261].
```

- [ ] **Step 2: Commit the mobile changelog**

```bash
cd packages/genericsuite-mobile
git add CHANGELOG.md
git commit -m "Add: CHANGELOG entries for childComponents support and Apple-clean/shadcn_ui UI enhancement [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 3: Superproject root CHANGELOG**

In the root `CHANGELOG.md`, under `## [Unreleased]` / `### Added`:

```markdown
- `childComponents` (1-N relationships) support in the GS Mobile (Flutter) CRUD Editor, matching the genericsuite-fe behavior, plus a new Mobile Development documentation section in GS Basecamp [GS-261].
- Apple-clean UI for GS Mobile: shadcn_ui-owned widget-tree root, green accent, 12px radius, iOS semantic colors, and Inter typography tokens in the getThemeParams() contract [GS-261].
```

- [ ] **Step 4: Update `docs/activeContext.md`**

In initiatives **#7 (“Finish GS Mobile UI to handle childComponents”)** and **#8 (“Enhance the GS Mobile UI...”)**, change `- **Status**: Planning phase` to `- **Status**: Implemented, testing pending` in both, and append to each a line:

```markdown
- **Progress (2026-07-19)**: Implemented in genericsuite-mobile 0.5.0 (see packages/genericsuite-mobile/CHANGELOG.md) and documented in GS Basecamp Mobile Development section.
```

- [ ] **Step 5: Final verification (superpowers:verification-before-completion)**

```bash
cd packages/genericsuite-mobile/genericsuite_flutter
flutter analyze && flutter test
```
Expected: 0 analyze issues; all tests pass. Paste the actual output in the task report — no success claims without it.

- [ ] **Step 6: Commit at the superproject root**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite
git add CHANGELOG.md docs/activeContext.md
git commit -m "Change: activeContext and CHANGELOG for GS Mobile childComponents and Apple-clean UI [GS-261]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Note: `docs/activeContext.md` already has unrelated local modifications — review `git diff docs/activeContext.md` first and only stage if the pre-existing edits belong in this commit; otherwise use `git add -p` to stage only the #7/#8 status changes.

---

## Self-Review Notes

- **Spec coverage:** childComponents (Tasks 1–5), shadcn_ui root + Apple-clean + typography token (Tasks 6–9), Basecamp docs (Task 10), CHANGELOGs on completion + [GS-261] everywhere (Tasks 10–11, commit templates). Web/ShadCN `ui/src/components/ui/` explicitly declared out of scope (GS-150) in Global Constraints.
- **Type consistency:** `buildChildRowToSave` (Task 1) is consumed with identical named parameters in Task 4; `ChildComponentBuilder`/`buildChildComponentSections` (Task 2) are consumed with identical signatures in Tasks 3, 5, 10; the token constant is `gsFontFamily` while the map key is `'fontFamily'` (called out in Tasks 7 and 8).
- **Known API risk:** exact `ShadApp.custom` / `ShadButton` signatures vary by shadcn_ui version. Tasks 8 and 9 pin the invariant (ShadApp owns the root; `buildGsMaterialTheme(tp)` supplies the Material theme; one filled + one outline button) and give a deterministic recovery path (read the installed package source in `~/.pub-cache`). `flutter analyze` gates every commit.
