# Design: 1-1 Relationships (`select_table`) in the Generic CRUD Editor

**Date:** 2026-07-15
**Status:** Approved
**Packages affected:** `genericsuite-be`, `genericsuite-fe`, `genericsuite-mobile`

## Problem

The Generic CRUD Editor (GCE) listing page shows raw foreign-key IDs for fields
that reference another table. End users need to see the related record's
description (e.g. the user's name instead of `user_id`) in:

1. The listing page (GCE_RFC and GCE_FLUTTER).
2. The form page when in query/read-only state.
3. Create/edit state, as a dropdown populated from the related table.

The `select_table` field type name is already reserved in the backend
(`generic_db_helpers_super.py: quote_value()`) but has no behavior anywhere.

## Decisions

| Decision | Choice |
|---|---|
| Join location | Server-side: backend listing/read endpoints return resolved descriptions as `{field_name}_description` |
| JSON schema | New explicit attributes on the field definition (see below) |
| DynamoDB strategy | Application-level join via `BatchGetItem` (chunked at 100 keys) |
| SQL engines (v1) | Generic `$in` app-join through the existing abstraction; native `LEFT JOIN` deferred as a follow-up optimization |
| Edit mode | Included: `select_table` renders a populated dropdown in create/edit |

## JSON Field Schema

Used identically in backend table definitions, frontend `editorConfig`, and
Flutter asset configs:

```json
{
  "name": "user_id",
  "type": "select_table",
  "related_table": "users",
  "related_key": "_id",
  "description_fields": ["name"],
  "description_separator": " ",
  "related_filter": {}
}
```

- `related_table` (required): name of the related table/collection (and its
  CRUD editor config name for FE/Flutter dropdown population).
- `related_key` (optional, default `"_id"`): key field in the related table
  matched against this field's value.
- `description_fields` (optional, default `["name"]`): fields concatenated to
  build the description.
- `description_separator` (optional, default `" "`).
- `related_filter` (optional): extra MongoDB-syntax filter applied when
  fetching related rows (both for the join and the edit dropdown).

The resolved description is returned as an additional attribute per row:
`{name}_description` (e.g. `user_id_description`). Rows whose FK has no match
get `null`.

## Phase 1 — Backend (`genericsuite-be`)

### 1a. Relationship metadata extraction

New helper in `generic_db_helpers_super.py` that scans the table definition
(`fieldElements`) for `type == "select_table"` fields and returns a list of
relationship descriptors: `{local_field, related_table, related_key,
description_fields, description_separator, related_filter}`.

### 1b. Abstraction API

Add `resolve_relationships(rows: list, relationships: list) -> list` to the
`DbAbstract` contract in `db_abstractor_super.py`, with a default
engine-agnostic implementation:

1. For each relationship, collect the distinct FK values present in the page
   of rows.
2. Fetch related rows with one query per related table:
   `find({related_key: {"$in": [values]}, **related_filter})` with a
   projection limited to `related_key` + `description_fields`.
3. Merge `{local_field}_description` into each row.

Because every engine adapter already accepts MongoDB query syntax, this
single code path covers MongoDB, DynamoDB, PostgreSQL, MySQL, and Supabase.

Engine-specific overrides:

- **MongoDB** (`db_abstractor_mongodb.py`): resolve via a `$lookup` + `$addFields`
  aggregation pipeline so listing/read is a single round-trip. Falls back to
  the default implementation if aggregation is unavailable.
- **DynamoDB** (`db_abstractor_dynamodb.py`): replace the `$in` fetch with
  `BatchGetItem`, chunked at DynamoDB's 100-key limit, with retry of
  `UnprocessedKeys`.
- **SQL engines**: use the default implementation in v1. A native `LEFT JOIN`
  in `build_select_sql()` is explicitly out of scope (touches identifier
  quoting, projections, and iterator classes; the app-join costs one extra
  query per page).

### 1c. Wiring

- `fetch_list()` and `fetch_row()` in `generic_db_helpers.py` call the
  metadata extractor; when relationships exist, resolve them on the fetched
  page (after skip/limit — only the current page is joined, no N+1).
- Listing projections must not strip `{field}_description`: descriptions are
  merged after the projection is applied, so no projection change is needed;
  verify with tests.
- Tables with no `select_table` fields take the existing code path untouched.

### 1d. Error handling

- A failed relationship resolution must not fail the listing: log the error,
  return rows with `{field}_description = null`, and keep
  `{"error": false, ...}` for the main resultset (standard result shape is
  preserved everywhere).
- Invalid `related_table` names are validated against the table definitions
  (no raw user input reaches queries; SQL identifier quoting rules still
  apply).

### 1e. Tests

- Unit tests: metadata extraction; default app-join (match, no-match, empty
  page, multiple relationships); DynamoDB batch chunking.
- Regression: tables without `select_table` produce byte-identical results.

## Phase 2 — Frontend (`genericsuite-fe`)

### 2a. Listing page

In `generic.editor.rfc.selector.jsx: getSelectDescription()`, add a
`select_table` branch:

1. If `dbRow[name + '_description']` exists (upgraded backend), render it.
2. Fallback: client-side cached lookup reusing the `GenericSelectGenerator`
   pattern (`MainSectionContext.fetchOrCache` keyed by `related_table`),
   building the description from `description_fields`.

### 2b. Read-only form

`generic.editor.rfc.formpage.jsx` / `generic.editor.rfc.ui.jsx`: when the
form is in view/delete (read-only) state, render the same description
(server-provided value first, cached client lookup as fallback).

### 2c. Create/edit dropdown

`generic.editor.rfc.ui.jsx`: render a `<select>` populated from the related
table's CRUD API, driven by the JSON attributes (`related_table`,
`related_key`, `description_fields`, `related_filter`), with a
"Select an option" empty item, using `fetchOrCache` for caching. This is the
JSON-driven equivalent of today's hand-written `select_component`.

### 2d. Tests

Jest tests for the new branch in `getSelectDescription`, the dropdown
renderer, and the fallback path; update snapshots per repo convention.

## Phase 3 — Flutter (`genericsuite-mobile/genericsuite_flutter`)

Mirror Phase 2 with the same JSON attributes read from asset configs:

- `crud_editor.dart`: listing shows `{field}_description` (with client-side
  cached fallback).
- `crud_editor_selector.dart` / `select_options_service.dart`: fetch and
  cache related-table options for the dropdown.
- `form_field_service.dart`: read-only state renders the description text;
  create/edit renders a `DropdownButtonFormField` populated from the related
  table.
- Widget tests for both states.

## Phase 4 — Documentation & release

- Document `select_table` in the config JSON documentation (basecamp docs,
  package READMEs, example configs under `src/configs/` in genericsuite-fe
  and the backend config docs).
- CHANGELOG entries in each touched package; branches per submodule off
  `develop`.

## Rollout / compatibility

- Backend-first: FE/Flutter fall back to client-side cached lookup when
  `{field}_description` is absent, so mixed versions degrade gracefully.
- Phase 1 defines the contract; Phases 2 and 3 can proceed in parallel after.
- No breaking changes: new field type is opt-in per JSON config; existing
  `select`, `select_component`, and `suggestion_dropdown` behavior unchanged.

## Out of scope

- Native SQL `LEFT JOIN` optimization (follow-up).
- Sorting/filtering the listing by the joined description (enabled later by
  the MongoDB `$lookup` path, not exposed in v1).
- 1-N / N-N relationships.
- Denormalized description storage.
