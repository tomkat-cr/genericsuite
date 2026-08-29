# `select_table` 1-1 Relationships Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show related-record descriptions for `select_table` fields in the Generic CRUD Editor listing/read-only pages (server-side join across all 5 DB engines) and render an editable dropdown in create/edit — in genericsuite-be, genericsuite-fe (GCE_RFC), and genericsuite-mobile (GCE_FLUTTER).

**Architecture:** The backend resolves each `select_table` field into a `{field}_description` attribute per row at listing/read time. A generic resolver (one `find({key: {"$in": [...]}})` per related table per page) works on all engines because every abstractor translates MongoDB query syntax; DynamoDB gets a `BatchGetItem` fast path and MongoDB gets a `$lookup` aggregation fast path, both with fallback to the generic resolver. FE and Flutter render the server-provided description with a client-side cached lookup fallback, and populate edit dropdowns from the related table's CRUD API.

**Tech Stack:** Python 3.10+/Poetry/pytest (be), React/Formik/Jest (fe), Flutter/Dart (mobile).

**Spec:** `docs/superpowers/specs/2026-07-15-select-table-relationships-design.md`

## Global Constraints

- Every backend function returns `{"error": bool, "error_message": str | None, "resultset": Any}` — never deviate.
- Backend error messages carry a bracketed code, e.g. `[RR1]`. Debug logs use `_ = DEBUG and log_debug(...)` with module-level `DEBUG = False`.
- Work inside each submodule under `packages/`, on branch `feature/select-table-relationships` off `develop` (create it in each package before its first task).
- FE: never raw `console.log`; use `console_debug_log` gated by `const debug = false;`. Constants in ALL_CAPS in constants files.
- Backend catch-all excepts need `# pylint: disable=broad-except`.
- A failed relationship resolution must NOT fail the listing/read: log the error, set `{field}_description = null`, keep `error: false`.
- JSON field attributes (identical across be/fe/flutter): `related_table` (required), `related_key` (default `"_id"`), `description_fields` (default `["name"]`), `description_separator` (default `" "`), `related_filter` (default `{}`).
- Backend single-test-run env prefix (from packages/genericsuite-be/CLAUDE.md), used in every backend "Run" step below as `$GSBE_ENV`:
  ```bash
  export GSBE_ENV='APP_DB_URI=fake_db_uri APP_DB_ENGINE=MONGODB APP_DB_NAME=mongo APP_NAME=test_app APP_STAGE=test APP_HOST_NAME=localhost APP_SECRET_KEY=fake_secret_key STORAGE_URL_SEED=xyz APP_SUPERADMIN_EMAIL=fake_email GIT_SUBMODULE_LOCAL_PATH=fake_path CLOUD_PROVIDER=aws AWS_REGION=us-east-1 GET_SECRETS_ENABLED=0 CURRENT_FRAMEWORK=fastapi'
  ```
  Invoke as: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/<file>.py -v`

---

### Task 1: Backend — relationship metadata extraction + description builder

**Files:**
- Modify: `packages/genericsuite-be/genericsuite/util/generic_db_helpers_super.py` (add two methods to `GenericDbHelperSuper`)
- Test: `packages/genericsuite-be/tests/test_select_table_relationships.py` (create)

**Interfaces:**
- Consumes: `self.cnf_db['fieldElements']` (already loaded in `__init__`).
- Produces: `get_select_table_relationships(self) -> list[dict]` returning descriptors `{'local_field', 'related_table', 'related_key', 'description_fields', 'description_separator', 'related_filter'}`; `build_relationship_description(self, related_row: dict, relationship: dict) -> str`. Tasks 2, 3, 4, 6 rely on these exact names.

- [ ] **Step 1: Write the failing tests**

```python
"""
Tests for select_table 1-1 relationship resolution (GenericDbHelperSuper).
"""
from genericsuite.util.generic_db_helpers_super import GenericDbHelperSuper


def make_helper(field_elements: list) -> GenericDbHelperSuper:
    """Build a helper without touching DB/config loading."""
    helper = GenericDbHelperSuper.__new__(GenericDbHelperSuper)
    helper.cnf_db = {'fieldElements': field_elements}
    helper.error_message = None
    helper.table_name = 'test_table'
    return helper


def test_get_select_table_relationships_defaults():
    helper = make_helper([
        {'name': 'user_id', 'type': 'select_table', 'related_table': 'users'},
        {'name': 'title', 'type': 'text'},
    ])
    rels = helper.get_select_table_relationships()
    assert rels == [{
        'local_field': 'user_id',
        'related_table': 'users',
        'related_key': '_id',
        'description_fields': ['name'],
        'description_separator': ' ',
        'related_filter': {},
    }]


def test_get_select_table_relationships_explicit_attrs():
    helper = make_helper([{
        'name': 'category_id', 'type': 'select_table',
        'related_table': 'categories', 'related_key': 'code',
        'description_fields': ['code', 'label'],
        'description_separator': ' - ',
        'related_filter': {'active': True},
    }])
    rels = helper.get_select_table_relationships()
    assert rels[0]['related_key'] == 'code'
    assert rels[0]['description_fields'] == ['code', 'label']
    assert rels[0]['description_separator'] == ' - '
    assert rels[0]['related_filter'] == {'active': True}


def test_get_select_table_relationships_skips_missing_related_table():
    helper = make_helper([
        {'name': 'user_id', 'type': 'select_table'},  # no related_table
    ])
    assert helper.get_select_table_relationships() == []


def test_get_select_table_relationships_no_field_elements():
    helper = make_helper([])
    assert helper.get_select_table_relationships() == []


def test_build_relationship_description():
    helper = make_helper([])
    rel = {'description_fields': ['firstname', 'lastname'],
           'description_separator': ' '}
    assert helper.build_relationship_description(
        {'firstname': 'John', 'lastname': 'Doe'}, rel) == 'John Doe'


def test_build_relationship_description_skips_missing_fields():
    helper = make_helper([])
    rel = {'description_fields': ['firstname', 'lastname'],
           'description_separator': ' '}
    assert helper.build_relationship_description(
        {'firstname': 'John'}, rel) == 'John'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/test_select_table_relationships.py -v`
Expected: FAIL — `AttributeError: ... has no attribute 'get_select_table_relationships'`

- [ ] **Step 3: Implement the two methods**

Add to `GenericDbHelperSuper` in `generic_db_helpers_super.py` (after `listing_projection_exclusions`, before `add_mandatory_filters`):

```python
    def get_select_table_relationships(self) -> list:
        """
        Scans the table definition for 'select_table' fields and returns
        the 1-1 relationship descriptors.

        Returns:
            list: one dict per select_table field with keys:
                local_field, related_table, related_key,
                description_fields, description_separator, related_filter.
        """
        relationships = []
        for field in self.cnf_db.get('fieldElements', []):
            if field.get('type') != 'select_table':
                continue
            if not field.get('related_table'):
                log_error(
                    "GET_SELECT_TABLE_RELATIONSHIPS | field"
                    f" '{field.get('name')}' has type select_table but no"
                    " related_table attribute [GSTR1]")
                continue
            relationships.append({
                'local_field': field['name'],
                'related_table': field['related_table'],
                'related_key': field.get('related_key', '_id'),
                'description_fields': field.get(
                    'description_fields', ['name']),
                'description_separator': field.get(
                    'description_separator', ' '),
                'related_filter': field.get('related_filter', {}),
            })
        return relationships

    def build_relationship_description(
        self,
        related_row: dict,
        relationship: dict,
    ) -> str:
        """
        Builds the description string for a related row by joining the
        relationship's description_fields with description_separator.
        """
        parts = [
            str(related_row[field])
            for field in relationship['description_fields']
            if related_row.get(field) is not None
        ]
        return relationship['description_separator'].join(parts)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/test_select_table_relationships.py -v`
Expected: 6 PASS

- [ ] **Step 5: Lint and commit**

```bash
cd packages/genericsuite-be
poetry run flake8 genericsuite/util/generic_db_helpers_super.py tests/test_select_table_relationships.py
git add genericsuite/util/generic_db_helpers_super.py tests/test_select_table_relationships.py
git commit -m "Add: select_table relationship metadata extraction and description builder [GS-select-table]"
```

---

### Task 2: Backend — generic engine-agnostic relationship resolver

**Files:**
- Modify: `packages/genericsuite-be/genericsuite/util/generic_db_helpers_super.py`
- Test: `packages/genericsuite-be/tests/test_select_table_relationships.py` (extend)

**Interfaces:**
- Consumes: Task 1's `get_select_table_relationships()` / `build_relationship_description()`; module-level `db` (already imported in this file: `from genericsuite.util.db_abstractor import db`); `ObjectId` (already imported).
- Produces: `resolve_relationships(self, rows: list, relationships: list = None) -> list` — mutates/returns rows with `{local_field}_description: str | None` added. `_fetch_related_rows(self, rel: dict, query_values: list, projection: dict) -> list` — internal fetch hook that Task 5 extends for DynamoDB. Tasks 3, 4, 5 rely on these exact names.

- [ ] **Step 1: Write the failing tests** (append to `tests/test_select_table_relationships.py`)

```python
from unittest.mock import MagicMock, patch

REL_USERS = {
    'local_field': 'user_id', 'related_table': 'users',
    'related_key': '_id', 'description_fields': ['name'],
    'description_separator': ' ', 'related_filter': {},
}


def test_resolve_relationships_merges_descriptions():
    helper = make_helper([])
    fake_users_table = MagicMock()
    fake_users_table.find.return_value = [
        {'_id': 'aaa', 'name': 'John Doe'},
        {'_id': 'bbb', 'name': 'Jane Roe'},
    ]
    fake_db = {'users': fake_users_table}
    rows = [{'user_id': 'aaa'}, {'user_id': 'bbb'}, {'user_id': 'zzz'}]
    with patch('genericsuite.util.generic_db_helpers_super.db', fake_db):
        result = helper.resolve_relationships(rows, [REL_USERS])
    assert result[0]['user_id_description'] == 'John Doe'
    assert result[1]['user_id_description'] == 'Jane Roe'
    assert result[2]['user_id_description'] is None  # no match
    # One single $in query for the whole page (no N+1)
    assert fake_users_table.find.call_count == 1
    query_arg = fake_users_table.find.call_args[0][0]
    assert '$in' in query_arg['_id']


def test_resolve_relationships_null_fk():
    helper = make_helper([])
    fake_db = {'users': MagicMock()}
    rows = [{'user_id': None}, {'title': 'no fk attr'}]
    with patch('genericsuite.util.generic_db_helpers_super.db', fake_db):
        result = helper.resolve_relationships(rows, [REL_USERS])
    assert result[0]['user_id_description'] is None
    assert result[1]['user_id_description'] is None
    fake_db['users'].find.assert_not_called()


def test_resolve_relationships_empty_inputs():
    helper = make_helper([])
    assert helper.resolve_relationships([], [REL_USERS]) == []
    rows = [{'user_id': 'aaa'}]
    assert helper.resolve_relationships(rows, []) == rows


def test_resolve_relationships_db_error_does_not_fail():
    helper = make_helper([])
    fake_users_table = MagicMock()
    fake_users_table.find.side_effect = Exception('boom')
    fake_db = {'users': fake_users_table}
    rows = [{'user_id': 'aaa'}]
    with patch('genericsuite.util.generic_db_helpers_super.db', fake_db):
        result = helper.resolve_relationships(rows, [REL_USERS])
    assert result[0]['user_id_description'] is None


def test_resolve_relationships_applies_related_filter_and_projection():
    helper = make_helper([])
    rel = dict(REL_USERS, related_filter={'active': True},
               description_fields=['firstname', 'lastname'])
    fake_users_table = MagicMock()
    fake_users_table.find.return_value = []
    fake_db = {'users': fake_users_table}
    with patch('genericsuite.util.generic_db_helpers_super.db', fake_db):
        helper.resolve_relationships([{'user_id': 'aaa'}], [rel])
    query_arg, projection_arg = fake_users_table.find.call_args[0]
    assert query_arg['active'] is True
    assert projection_arg == {'firstname': 1, 'lastname': 1, '_id': 1}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/test_select_table_relationships.py -v`
Expected: new tests FAIL with `AttributeError: ... 'resolve_relationships'`; Task 1 tests still PASS.

- [ ] **Step 3: Implement the resolver** (add to `GenericDbHelperSuper`, right after `build_relationship_description`)

```python
    def _fetch_related_rows(
        self,
        rel: dict,
        query_values: list,
        projection: dict,
    ) -> list:
        """
        Fetches the related rows for one relationship. Engine-agnostic:
        every DB abstractor translates the MongoDb $in operator.
        """
        query = {rel['related_key']: {'$in': query_values}}
        query.update(rel['related_filter'])
        return list(db[rel['related_table']].find(query, projection))

    def resolve_relationships(
        self,
        rows: list,
        relationships: list = None,
    ) -> list:
        """
        Resolves select_table 1-1 relationships for a page of rows,
        adding a '{field}_description' attribute per relationship.
        Errors never propagate: on failure the description is None.
        """
        if relationships is None:
            relationships = self.get_select_table_relationships()
        if not rows or not relationships:
            return rows
        for rel in relationships:
            desc_attr = f"{rel['local_field']}_description"
            fk_values = {
                str(row[rel['local_field']]) for row in rows
                if row.get(rel['local_field']) is not None
            }
            if not fk_values:
                for row in rows:
                    row[desc_attr] = None
                continue
            query_values = list(fk_values)
            if rel['related_key'] == '_id':
                # Send both ObjectId and raw string forms: MongoDb stores
                # ObjectId, SQL/DynamoDb abstractors normalize to string.
                for value in list(fk_values):
                    try:
                        query_values.append(ObjectId(value))
                    except Exception:  # pylint: disable=broad-except
                        pass
            projection = {
                field: 1 for field in rel['description_fields']}
            projection[rel['related_key']] = 1
            try:
                related_rows = self._fetch_related_rows(
                    rel, query_values, projection)
            except Exception as err:  # pylint: disable=broad-except
                log_error(
                    "RESOLVE_RELATIONSHIPS | table:"
                    f" {rel['related_table']} | error [RR1]: {err}")
                related_rows = []
            desc_map = {
                str(related_row.get(rel['related_key'])):
                    self.build_relationship_description(related_row, rel)
                for related_row in related_rows
            }
            for row in rows:
                fk_value = row.get(rel['local_field'])
                row[desc_attr] = (
                    desc_map.get(str(fk_value))
                    if fk_value is not None else None)
        return rows
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/test_select_table_relationships.py -v`
Expected: 11 PASS

- [ ] **Step 5: Lint and commit**

```bash
cd packages/genericsuite-be
poetry run flake8 genericsuite/util/generic_db_helpers_super.py tests/test_select_table_relationships.py
git add genericsuite/util/generic_db_helpers_super.py tests/test_select_table_relationships.py
git commit -m "Add: engine-agnostic select_table relationship resolver via \$in queries [GS-select-table]"
```

---

### Task 3: Backend — wire resolver into `fetch_list()`

**Files:**
- Modify: `packages/genericsuite-be/genericsuite/util/generic_db_helpers.py` (inside `fetch_list`, the `try:` block currently ending with `resultset['resultset'] = dumps(db_result)`)
- Test: `packages/genericsuite-be/tests/test_select_table_relationships.py` (extend)

**Interfaces:**
- Consumes: Task 2's `resolve_relationships(rows, relationships)` and Task 1's `get_select_table_relationships()`.
- Produces: `fetch_list()` resultset rows carry `{field}_description`; tables without `select_table` fields keep the identical code path/output.

- [ ] **Step 1: Write the failing test** (append)

```python
from bson.json_util import loads

from genericsuite.util.generic_db_helpers import GenericDbHelper


def make_full_helper(field_elements, main_rows):
    """GenericDbHelper wired with a fake main table, bypassing __init__."""
    helper = GenericDbHelper.__new__(GenericDbHelper)
    helper.cnf_db = {'fieldElements': field_elements}
    helper.error_message = None
    helper.table_name = 'main_table'
    helper.name = 'Main'
    helper.title = 'Mains'
    helper.mandatory_filters = {}
    helper.query_params = {'only_listing_cols': '0'}
    helper.table_type = 'main_table'
    helper.sub_type = ''
    fake_cursor = MagicMock()
    fake_cursor.sort.return_value = fake_cursor
    fake_cursor.skip.return_value = fake_cursor
    fake_cursor.limit.return_value = fake_cursor
    fake_cursor.__iter__ = lambda self_: iter(main_rows)
    helper.table_obj = MagicMock()
    helper.table_obj.find.return_value = fake_cursor
    helper.table_obj.count_documents.return_value = len(main_rows)
    return helper


def test_fetch_list_resolves_select_table_descriptions():
    helper = make_full_helper(
        [{'name': 'user_id', 'type': 'select_table',
          'related_table': 'users', 'listing': True}],
        [{'_id': '1', 'user_id': 'aaa'}],
    )
    fake_users_table = MagicMock()
    fake_users_table.find.return_value = [{'_id': 'aaa', 'name': 'John Doe'}]
    with patch('genericsuite.util.generic_db_helpers_super.db',
               {'users': fake_users_table}):
        result = helper.fetch_list(skip=0, limit=10)
    assert result['error'] is False
    rows = loads(result['resultset'])
    assert rows[0]['user_id_description'] == 'John Doe'


def test_fetch_list_without_relationships_unchanged():
    helper = make_full_helper(
        [{'name': 'title', 'type': 'text', 'listing': True}],
        [{'_id': '1', 'title': 'Hello'}],
    )
    result = helper.fetch_list(skip=0, limit=10)
    assert result['error'] is False
    rows = loads(result['resultset'])
    assert rows == [{'_id': '1', 'title': 'Hello'}]
```

Note: if `run_specific_func` / `put_total_pages_in_resultset` need more attributes on the fake helper (e.g. `helper.specific_funcs = {}` or similar), read their implementations in `generic_db_helpers_super.py` and stub the minimum — keep the tests DB-free.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/test_select_table_relationships.py -v -k fetch_list`
Expected: FAIL — `user_id_description` KeyError (resolver not wired).

- [ ] **Step 3: Wire the resolver**

In `fetch_list()` (`generic_db_helpers.py`), replace:

```python
            resultset['resultset'] = dumps(db_result)
```

with:

```python
            rows = list(db_result)
            relationships = self.get_select_table_relationships()
            if relationships:
                rows = self.resolve_relationships(rows, relationships)
            resultset['resultset'] = dumps(rows)
```

(The replacement goes after the existing `skip`/`limit` lines so only the current page is resolved.)

- [ ] **Step 4: Run the full backend test suite**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/ -v`
Expected: all PASS (new + existing; skips per framework are OK).

- [ ] **Step 5: Lint and commit**

```bash
cd packages/genericsuite-be
poetry run flake8 genericsuite/util/generic_db_helpers.py tests/test_select_table_relationships.py
git add genericsuite/util/generic_db_helpers.py tests/test_select_table_relationships.py
git commit -m "Change: fetch_list resolves select_table relationship descriptions per page [GS-select-table]"
```

---

### Task 4: Backend — wire resolver into `fetch_row()`

**Files:**
- Modify: `packages/genericsuite-be/genericsuite/util/generic_db_helpers.py:215-216` (the `try:` block with `resultset['resultset'] = dumps(db_row['resultset'])`)
- Test: `packages/genericsuite-be/tests/test_select_table_relationships.py` (extend)

**Interfaces:**
- Consumes: Task 2's `resolve_relationships`.
- Produces: `fetch_row()` resultset row carries `{field}_description`.

- [ ] **Step 1: Write the failing test** (append)

```python
def test_fetch_row_resolves_select_table_descriptions():
    helper = make_full_helper(
        [{'name': 'user_id', 'type': 'select_table',
          'related_table': 'users'}],
        [],
    )
    helper.fetch_row_raw = MagicMock(return_value={
        'error': False, 'error_message': None,
        'resultset': {'_id': '1', 'user_id': 'aaa'},
    })
    fake_users_table = MagicMock()
    fake_users_table.find.return_value = [{'_id': 'aaa', 'name': 'John Doe'}]
    with patch('genericsuite.util.generic_db_helpers_super.db',
               {'users': fake_users_table}):
        result = helper.fetch_row('1')
    assert result['error'] is False
    row = loads(result['resultset'])
    assert row['user_id_description'] == 'John Doe'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/test_select_table_relationships.py -v -k fetch_row`
Expected: FAIL — `user_id_description` KeyError.

- [ ] **Step 3: Wire the resolver**

In `fetch_row()`, replace:

```python
        try:
            resultset['resultset'] = dumps(db_row['resultset'])
```

with:

```python
        try:
            row = db_row['resultset']
            relationships = self.get_select_table_relationships()
            if relationships:
                row = self.resolve_relationships([row], relationships)[0]
            resultset['resultset'] = dumps(row)
```

- [ ] **Step 4: Run tests**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/ -v`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd packages/genericsuite-be
poetry run flake8 genericsuite/util/generic_db_helpers.py tests/test_select_table_relationships.py
git add genericsuite/util/generic_db_helpers.py tests/test_select_table_relationships.py
git commit -m "Change: fetch_row resolves select_table relationship descriptions [GS-select-table]"
```

---

### Task 5: Backend — DynamoDB `BatchGetItem` fast path

**Files:**
- Modify: `packages/genericsuite-be/genericsuite/util/db_abstractor_dynamodb.py` (add `batch_get` to `DynamoDbTableAbstract`, class starts at line 225)
- Modify: `packages/genericsuite-be/genericsuite/util/generic_db_helpers_super.py` (`_fetch_related_rows` dispatch)
- Test: `packages/genericsuite-be/tests/test_select_table_relationships.py` (extend)

**Interfaces:**
- Consumes: `DynamoDbTableAbstract.get_table_name()`, `get_key_schema()`, `self._db_conection` (boto3 DynamoDB ServiceResource — `batch_get_item` accepts native Python values).
- Produces: `DynamoDbTableAbstract.batch_get(self, values: list, key_name: str = '_id') -> list`. `_fetch_related_rows` uses it when `APP_DB_ENGINE == 'DYNAMODB'`, `related_key == '_id'`, and `related_filter` is empty; any exception falls back to the `$in` find.

- [ ] **Step 1: Write the failing tests** (append)

```python
import os


def test_fetch_related_rows_dynamodb_uses_batch_get():
    helper = make_helper([])
    fake_users_table = MagicMock()
    fake_users_table.batch_get.return_value = [
        {'_id': 'aaa', 'name': 'John Doe'}]
    with patch('genericsuite.util.generic_db_helpers_super.db',
               {'users': fake_users_table}), \
            patch.dict(os.environ, {'APP_DB_ENGINE': 'DYNAMODB'}):
        rows = helper._fetch_related_rows(
            REL_USERS, ['aaa'], {'name': 1, '_id': 1})
    assert rows == [{'_id': 'aaa', 'name': 'John Doe'}]
    fake_users_table.find.assert_not_called()


def test_fetch_related_rows_dynamodb_falls_back_on_error():
    helper = make_helper([])
    fake_users_table = MagicMock()
    fake_users_table.batch_get.side_effect = Exception('boom')
    fake_users_table.find.return_value = [{'_id': 'aaa', 'name': 'John Doe'}]
    with patch('genericsuite.util.generic_db_helpers_super.db',
               {'users': fake_users_table}), \
            patch.dict(os.environ, {'APP_DB_ENGINE': 'DYNAMODB'}):
        rows = helper._fetch_related_rows(
            REL_USERS, ['aaa'], {'name': 1, '_id': 1})
    assert rows == [{'_id': 'aaa', 'name': 'John Doe'}]
    fake_users_table.find.assert_called_once()


def test_dynamodb_batch_get_chunks_and_retries_unprocessed():
    from genericsuite.util.db_abstractor_dynamodb import (
        DynamoDbTableAbstract)
    table = DynamoDbTableAbstract.__new__(DynamoDbTableAbstract)
    table._prefix = ''
    table._table_name = 'users'
    table._key_schema = [{'AttributeName': '_id', 'KeyType': 'HASH'}]
    table._attribute_definitions = []
    table._global_secondary_indexes = []
    conn = MagicMock()
    # First call returns one item + unprocessed keys; retry returns rest.
    conn.batch_get_item.side_effect = [
        {'Responses': {'users': [{'_id': 'aaa', 'name': 'John'}]},
         'UnprocessedKeys': {'users': {'Keys': [{'_id': 'bbb'}]}}},
        {'Responses': {'users': [{'_id': 'bbb', 'name': 'Jane'}]},
         'UnprocessedKeys': {}},
    ]
    table._db_conection = conn
    result = table.batch_get(['aaa', 'bbb'])
    assert len(result) == 2
    assert conn.batch_get_item.call_count == 2
    # 150 keys -> chunked into 100 + 50 (2 more calls, no retries)
    conn.batch_get_item.side_effect = [
        {'Responses': {'users': []}, 'UnprocessedKeys': {}},
        {'Responses': {'users': []}, 'UnprocessedKeys': {}},
    ]
    conn.batch_get_item.reset_mock()
    table.batch_get([str(i) for i in range(150)])
    assert conn.batch_get_item.call_count == 2
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/test_select_table_relationships.py -v -k "batch_get or dynamodb"`
Expected: FAIL — no `batch_get` attribute / dispatch.

- [ ] **Step 3: Implement `batch_get`** (add to `DynamoDbTableAbstract` after `find_one`)

```python
    def batch_get(self, values: list, key_name: str = '_id') -> list:
        """
        Fetches multiple items by primary key using BatchGetItem,
        chunked at DynamoDb's 100-key limit, retrying UnprocessedKeys.

        Args:
            values (list): primary key values to fetch.
            key_name (str): logical key name expected by the caller.

        Returns:
            list: the fetched items.
        """
        table_name = self.get_table_name()
        partition_key = self.get_key_schema()[0]['AttributeName']
        results = []
        for i in range(0, len(values), 100):
            chunk = values[i:i + 100]
            request_items = {
                table_name: {
                    'Keys': [{partition_key: str(value)}
                             for value in chunk],
                }
            }
            while request_items:
                response = self._db_conection.batch_get_item(
                    RequestItems=request_items)
                results.extend(
                    response.get('Responses', {}).get(table_name, []))
                request_items = response.get('UnprocessedKeys') or None
        if partition_key != key_name:
            for item in results:
                item.setdefault(key_name, item.get(partition_key))
        return results
```

- [ ] **Step 4: Add the dispatch in `_fetch_related_rows`** (`generic_db_helpers_super.py`) — replace the method body with:

```python
    def _fetch_related_rows(
        self,
        rel: dict,
        query_values: list,
        projection: dict,
    ) -> list:
        """
        Fetches the related rows for one relationship. Engine-agnostic
        default ($in find); DynamoDb uses a BatchGetItem fast path.
        """
        db_engine = os.environ.get('APP_DB_ENGINE', '').upper()
        if db_engine == 'DYNAMODB' and rel['related_key'] == '_id' \
                and not rel['related_filter']:
            try:
                return db[rel['related_table']].batch_get(
                    [str(value) for value in query_values])
            except Exception as err:  # pylint: disable=broad-except
                log_error(
                    "FETCH_RELATED_ROWS | batch_get fallback to find"
                    f" [FRR1]: {err}")
        query = {rel['related_key']: {'$in': query_values}}
        query.update(rel['related_filter'])
        return list(db[rel['related_table']].find(query, projection))
```

- [ ] **Step 5: Run the full suite, lint, commit**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/ -v`
Expected: all PASS.

```bash
cd packages/genericsuite-be
poetry run flake8 genericsuite/util/db_abstractor_dynamodb.py genericsuite/util/generic_db_helpers_super.py tests/test_select_table_relationships.py
git add genericsuite/util/db_abstractor_dynamodb.py genericsuite/util/generic_db_helpers_super.py tests/test_select_table_relationships.py
git commit -m "Add: DynamoDB BatchGetItem fast path for select_table relationships [GS-select-table]"
```

---

### Task 6: Backend — MongoDB `$lookup` fast path in `fetch_list`

**Files:**
- Modify: `packages/genericsuite-be/genericsuite/util/generic_db_helpers.py` (`fetch_list` try-block; new private method)
- Test: `packages/genericsuite-be/tests/test_select_table_relationships.py` (extend)

**Interfaces:**
- Consumes: Tasks 1-3; `self.table_obj.aggregate(pipeline)` (native pymongo collection under MONGODB); `get_order_direction` (already imported in `generic_db_helpers.py`).
- Produces: `_fetch_list_mongodb_lookup(self, listing_filter, projection, column_name, direction, skip, limit, relationships) -> list` — single-round-trip listing with descriptions. Any exception falls back to the default path from Task 3.

- [ ] **Step 1: Write the failing tests** (append)

```python
def test_fetch_list_mongodb_uses_lookup_pipeline():
    helper = make_full_helper(
        [{'name': 'user_id', 'type': 'select_table',
          'related_table': 'users', 'listing': True}],
        [],
    )
    helper.table_obj.aggregate.return_value = [
        {'_id': '1', 'user_id': 'aaa',
         '_rel_user_id': [{'_id': 'aaa', 'name': 'John Doe'}]},
        {'_id': '2', 'user_id': 'zzz', '_rel_user_id': []},
    ]
    with patch.dict(os.environ, {'APP_DB_ENGINE': 'MONGODB'}):
        result = helper.fetch_list(skip=0, limit=10)
    assert result['error'] is False
    rows = loads(result['resultset'])
    assert rows[0]['user_id_description'] == 'John Doe'
    assert rows[1]['user_id_description'] is None
    assert '_rel_user_id' not in rows[0]
    pipeline = helper.table_obj.aggregate.call_args[0][0]
    stages = [list(stage.keys())[0] for stage in pipeline]
    assert '$lookup' in stages
    assert stages.index('$skip' if '$skip' in stages else '$sort') \
        < stages.index('$lookup')  # join happens after pagination
    helper.table_obj.find.assert_not_called()


def test_fetch_list_mongodb_lookup_falls_back_on_error():
    helper = make_full_helper(
        [{'name': 'user_id', 'type': 'select_table',
          'related_table': 'users', 'listing': True}],
        [{'_id': '1', 'user_id': 'aaa'}],
    )
    helper.table_obj.aggregate.side_effect = Exception('no aggregate')
    fake_users_table = MagicMock()
    fake_users_table.find.return_value = [{'_id': 'aaa', 'name': 'John Doe'}]
    with patch('genericsuite.util.generic_db_helpers_super.db',
               {'users': fake_users_table}), \
            patch.dict(os.environ, {'APP_DB_ENGINE': 'MONGODB'}):
        result = helper.fetch_list(skip=0, limit=10)
    assert result['error'] is False
    rows = loads(result['resultset'])
    assert rows[0]['user_id_description'] == 'John Doe'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/test_select_table_relationships.py -v -k lookup`
Expected: FAIL — `aggregate` never called / attribute missing.

- [ ] **Step 3: Implement**

Add to `GenericDbHelper` (in `generic_db_helpers.py`, after `fetch_list`) — note `import os` at top of file if not present:

```python
    def _fetch_list_mongodb_lookup(
        self,
        listing_filter: dict,
        projection: dict,
        column_name: str,
        direction: str,
        skip: int,
        limit: int,
        relationships: list,
    ) -> list:
        """
        MongoDb-only listing with $lookup joins, single round-trip.
        Pagination stages come BEFORE $lookup so only the current page
        is joined. FK values stored as strings are converted to
        ObjectId inside the lookup sub-pipeline when related_key is _id.
        """
        pipeline = [
            {'$match': listing_filter},
            {'$sort': {column_name: get_order_direction(direction)}},
        ]
        if skip > 0:
            pipeline.append({'$skip': int(skip)})
        if limit > 0:
            pipeline.append({'$limit': int(limit)})
        if projection:
            pipeline.append({'$project': projection})
        for rel in relationships:
            as_name = f"_rel_{rel['local_field']}"
            if rel['related_key'] == '_id':
                fk_expr = {'$convert': {
                    'input': '$$fk_value', 'to': 'objectId',
                    'onError': '$$fk_value', 'onNull': None}}
            else:
                fk_expr = '$$fk_value'
            sub_pipeline = [{'$match': {'$expr': {
                '$eq': [f"${rel['related_key']}", fk_expr]}}}]
            if rel['related_filter']:
                sub_pipeline.append({'$match': rel['related_filter']})
            pipeline.append({'$lookup': {
                'from': rel['related_table'],
                'let': {'fk_value': f"${rel['local_field']}"},
                'pipeline': sub_pipeline,
                'as': as_name,
            }})
        rows = list(self.table_obj.aggregate(pipeline))
        for row in rows:
            for rel in relationships:
                related = row.pop(f"_rel_{rel['local_field']}", [])
                row[f"{rel['local_field']}_description"] = (
                    self.build_relationship_description(related[0], rel)
                    if related else None)
        return rows
```

Then in `fetch_list()`, replace the Task 3 block:

```python
            rows = list(db_result)
            relationships = self.get_select_table_relationships()
            if relationships:
                rows = self.resolve_relationships(rows, relationships)
            resultset['resultset'] = dumps(rows)
```

with (and hoist `relationships = self.get_select_table_relationships()` to just before the `try:`, replacing the `db_result = self.table_obj.find(...)` block as shown):

```python
        relationships = self.get_select_table_relationships()
        try:
            rows = None
            if relationships and \
                    os.environ.get('APP_DB_ENGINE', '').upper() \
                    == 'MONGODB':
                try:
                    rows = self._fetch_list_mongodb_lookup(
                        listing_filter, projection, column_name,
                        direction, skip, limit, relationships)
                except Exception as err:  # pylint: disable=broad-except
                    log_error(
                        "FETCH_LIST | $lookup fallback to default"
                        f" resolver [FLML1]: {err}")
                    rows = None
            if rows is None:
                db_result = (
                    self.table_obj.find(
                        listing_filter, projection
                    )
                    .sort(
                        column_name,
                        get_order_direction(direction)
                    )
                )
                if skip > 0:
                    db_result = db_result.skip(int(skip))
                if limit > 0:
                    db_result = db_result.limit(int(limit))
                rows = list(db_result)
                if relationships:
                    rows = self.resolve_relationships(
                        rows, relationships)
            resultset['resultset'] = dumps(rows)
```

(Keep the existing `except` clause of that `try:` unchanged.)

- [ ] **Step 4: Run the full suite** — note existing tests run with `APP_DB_ENGINE=MONGODB`, so any test exercising `fetch_list` on a table WITHOUT select_table fields must still pass through `find` (they do: the aggregation path requires `relationships` non-empty).

Run: `cd packages/genericsuite-be && env $GSBE_ENV poetry run pytest tests/ -v`
Expected: all PASS. Also run all four frameworks: `cd packages/genericsuite-be && make test` → all PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd packages/genericsuite-be
poetry run flake8 genericsuite/util/generic_db_helpers.py tests/test_select_table_relationships.py
git add genericsuite/util/generic_db_helpers.py tests/test_select_table_relationships.py
git commit -m "Add: MongoDB \$lookup single-round-trip fast path for select_table listings [GS-select-table]"
```

---

### Task 7: Backend — CHANGELOG + final verification

**Files:**
- Modify: `packages/genericsuite-be/CHANGELOG.md` (new Unreleased entry, follow the file's existing format)

- [ ] **Step 1: Add CHANGELOG entry** under the unreleased/next-version section:

```markdown
### Added
- `select_table` field type: 1-1 relationship resolution in listings and reads. New JSON field attributes `related_table`, `related_key`, `description_fields`, `description_separator`, `related_filter`; rows now include `{field}_description`. Engine-agnostic `$in` resolver for all DB engines, with DynamoDB BatchGetItem and MongoDB `$lookup` fast paths [GS-select-table].
```

- [ ] **Step 2: Full verification**

Run: `cd packages/genericsuite-be && make test`
Expected: PASS for all four frameworks.

- [ ] **Step 3: Commit**

```bash
cd packages/genericsuite-be
git add CHANGELOG.md
git commit -m "Change: CHANGELOG entry for select_table relationships [GS-select-table]"
```

---

### Task 8: Frontend — listing + read-only description (`getSelectDescription` branch)

**Files:**
- Modify: `packages/genericsuite-fe/src/lib/services/generic.editor.rfc.selector.jsx`
- Test: `packages/genericsuite-fe/src/lib/services/generic.editor.rfc.selector.test.tsx` (create)

**Interfaces:**
- Consumes: `MainSectionContext.fetchOrCache`, `dbApiService` (`getAll(filter)`, `convertId(id)`), `buildDescription` (exists in this file).
- Produces: `getSelectDescription(currentObj, dbRow)` handles `currentObj.type === 'select_table'`; exported `SelectTableDescription` component and `useRelatedTableRows(currentObj)` hook. Task 9 reuses the hook.

- [ ] **Step 1: Write the failing tests**

```tsx
import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import {
  getSelectDescription,
  SelectTableDescription,
} from './generic.editor.rfc.selector.jsx';
import { MainSectionContext } from './generic.editor.rfc.provider.jsx';

jest.mock('./db.service.jsx', () => ({
  dbApiService: jest.fn().mockImplementation(() => ({
    getAll: () =>
      Promise.resolve({
        resultset: [
          { _id: 'aaa', firstname: 'John', lastname: 'Doe' },
          { _id: 'bbb', firstname: 'Jane', lastname: 'Roe' },
        ],
      }),
    convertId: (id: any) => (id && id.$oid ? id.$oid : String(id)),
  })),
}));

const providerValue: any = {
  fetchOrCache: (_key: string, fn: () => Promise<any>) => fn(),
  debugCache: () => {},
};

describe('getSelectDescription - select_table', () => {
  const currentObj = {
    name: 'user_id',
    type: 'select_table',
    related_table: 'users',
    description_fields: ['firstname', 'lastname'],
  };

  it('returns the backend-resolved description when present', () => {
    const dbRow = { user_id: 'aaa', user_id_description: 'John Doe' };
    expect(getSelectDescription(currentObj, dbRow)).toBe('John Doe');
  });

  it('falls back to client-side lookup when description is absent', async () => {
    const dbRow = { user_id: 'aaa' };
    const element = getSelectDescription(currentObj, dbRow);
    render(
      <MainSectionContext.Provider value={providerValue}>
        {element}
      </MainSectionContext.Provider>
    );
    await waitFor(() =>
      expect(screen.getByText('John Doe')).toBeInTheDocument()
    );
  });

  it('renders empty for a null FK value', async () => {
    const { container } = render(
      <MainSectionContext.Provider value={providerValue}>
        <SelectTableDescription currentObj={currentObj} dbRow={{}} />
      </MainSectionContext.Provider>
    );
    await waitFor(() => expect(container.textContent).toBe(''));
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/genericsuite-fe && npx jest src/lib/services/generic.editor.rfc.selector.test.tsx`
Expected: FAIL — `SelectTableDescription` not exported / no select_table branch.

- [ ] **Step 3: Implement**

In `generic.editor.rfc.selector.jsx`, add after `buildDescription`:

```jsx
export const useRelatedTableRows = (currentObj) => {
  /*
   * Fetches (with cache) the related table rows for a select_table field.
   * Returns { rows, errorState, convertKey } where convertKey normalizes
   * the related_key value of a row to a comparable string.
   */
  const [errorState, setErrorState] = useState(null);
  const [rows, setRows] = useState(null);
  const { fetchOrCache } = useContext(MainSectionContext);
  const relatedTable = currentObj.related_table;
  const relatedKey = currentObj.related_key || '_id';
  const dbFilter = currentObj.related_filter || {};

  useEffect(() => {
    if (!relatedTable) {
      setErrorState('select_table: missing related_table attribute');
      return;
    }
    const dbService = new dbApiService({ url: relatedTable });
    fetchOrCache(`select_table_${relatedTable}`, () => dbService.getAll(dbFilter))
      .then(
        data => setRows(data),
        error => setErrorState(error)
      );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [relatedTable, fetchOrCache]);

  const convertKey = (row) => {
    const dbService = new dbApiService({ url: relatedTable });
    return relatedKey === '_id'
      ? dbService.convertId(row[relatedKey])
      : String(row[relatedKey]);
  };

  return { rows, errorState, convertKey };
};

export const buildSelectTableDescription = (row, currentObj) => {
  const descriptionFields = currentObj.description_fields || ['name'];
  const separator = typeof currentObj.description_separator !== 'undefined'
    ? currentObj.description_separator : ' ';
  return descriptionFields
    .map((field) => row[field])
    .filter((value) => value !== null && typeof value !== 'undefined')
    .join(separator);
};

export const SelectTableDescription = ({ currentObj, dbRow }) => {
  /*
   * Client-side fallback: shows the related record description for a
   * select_table field when the backend didn't provide
   * `{name}_description` (older backend versions).
   */
  const { rows, errorState, convertKey } = useRelatedTableRows(currentObj);

  if (errorState) {
    return errorState.toString();
  }
  if (rows === null) {
    return '';
  }
  const fkValue = dbRow[currentObj.name];
  if (fkValue === null || typeof fkValue === 'undefined') {
    return '';
  }
  const match = rows.resultset.find(
    (row) => convertKey(row) === String(fkValue)
  );
  if (!match) {
    return '';
  }
  return buildSelectTableDescription(match, currentObj);
};
```

In `getSelectDescription`, add BEFORE the `select_component` branch:

```jsx
  // Related table select (1-1 relationship)
  if (currentObj.type === 'select_table') {
    const descAttr = currentObj.name + '_description';
    if (typeof dbRow[descAttr] !== 'undefined' && dbRow[descAttr] !== null) {
      return dbRow[descAttr];
    }
    return (
      <SelectTableDescription
        currentObj={currentObj}
        dbRow={dbRow}
      />
    );
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/genericsuite-fe && npx jest src/lib/services/generic.editor.rfc.selector.test.tsx`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
cd packages/genericsuite-fe
git add src/lib/services/generic.editor.rfc.selector.jsx src/lib/services/generic.editor.rfc.selector.test.tsx
git commit -m "Add: select_table listing/read-only description with server-side value and client-side cached fallback [GS-select-table]"
```

---

### Task 9: Frontend — form page `select_table` field (edit dropdown + read-only)

**Files:**
- Modify: `packages/genericsuite-fe/src/lib/services/generic.editor.rfc.selector.jsx` (add `SelectTableOptions`)
- Modify: `packages/genericsuite-fe/src/lib/services/generic.editor.rfc.formpage.jsx` (new `case 'select_table':` in the `switch (currentObj.type)` at line ~416)
- Test: `packages/genericsuite-fe/src/lib/services/generic.editor.rfc.selector.test.tsx` (extend)

**Interfaces:**
- Consumes: Task 8's `useRelatedTableRows` + `buildSelectTableDescription`; `MSG_SELECT_AN_OPTION` (already imported in selector.jsx); in formpage: `Field` (Formik), `readOnlyfield`, `fieldClass`, `idName`, `runCalculation`, `getSelectDescription` (add to the existing import from `./generic.editor.rfc.selector.jsx`).
- Produces: exported `SelectTableOptions` component rendering `<option>` elements.

- [ ] **Step 1: Write the failing test** (append to the selector test file)

```tsx
import { SelectTableOptions } from './generic.editor.rfc.selector.jsx';

describe('SelectTableOptions', () => {
  const currentObj = {
    name: 'user_id',
    type: 'select_table',
    related_table: 'users',
    description_fields: ['firstname', 'lastname'],
  };

  it('renders a Select-an-option item plus one option per related row', async () => {
    render(
      <MainSectionContext.Provider value={providerValue}>
        <select>
          <SelectTableOptions currentObj={currentObj} />
        </select>
      </MainSectionContext.Provider>
    );
    await waitFor(() =>
      expect(screen.getByText('John Doe')).toBeInTheDocument()
    );
    const options = screen.getAllByRole('option');
    expect(options).toHaveLength(3); // placeholder + 2 rows
    expect((options[1] as HTMLOptionElement).value).toBe('aaa');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/genericsuite-fe && npx jest src/lib/services/generic.editor.rfc.selector.test.tsx`
Expected: FAIL — `SelectTableOptions` not exported.

- [ ] **Step 3: Implement `SelectTableOptions`** (in selector.jsx, after `SelectTableDescription`)

```jsx
export const SelectTableOptions = ({ currentObj }) => {
  /*
   * Options generator for a select_table field's editable dropdown.
   * Fetches (with cache) the related table rows and renders one
   * <option> per row, plus the "Select an option" placeholder.
   */
  const { rows, errorState, convertKey } = useRelatedTableRows(currentObj);

  if (errorState) {
    return (
      <option value="">{errorState.toString()}</option>
    );
  }
  if (rows === null) {
    return null;
  }
  return [
    <option key="_placeholder" value="">{MSG_SELECT_AN_OPTION}</option>,
    ...rows.resultset.map((row) => {
      const keyValue = convertKey(row);
      return (
        <option key={keyValue} value={keyValue}>
          {buildSelectTableDescription(row, currentObj)}
        </option>
      );
    }),
  ];
};
```

- [ ] **Step 4: Add the formpage case**

In `generic.editor.rfc.formpage.jsx`: extend the existing import from `'./generic.editor.rfc.selector.jsx'` with `SelectTableOptions, getSelectDescription` (check what's already imported — `putSelectOptionsFromArray` is), then add before `case 'select':`:

```jsx
        case 'select_table':
            if (readOnlyfield) {
                elementInput = (
                    <div
                        id={idName}
                        className={fieldClass}
                    >
                        {getSelectDescription(currentObj, dbRow)}
                    </div>
                );
            } else {
                elementInput = (
                    <Field
                        name={idName}
                        id={idName}
                        as="select"
                        required={currentObj.required}
                        className={fieldClass}
                        onBlur={runCalculation}
                    >
                        <SelectTableOptions
                            currentObj={currentObj}
                        />
                    </Field>
                );
            }
            break;
```

- [ ] **Step 5: Run full FE verification**

Run: `cd packages/genericsuite-fe && npm test`
Expected: PASS (regenerate snapshots only if a snapshot diff is an intentional consequence: `UPDATE_SNAPSHOTS=1 npm test`).
Run: `cd packages/genericsuite-fe && npm run build`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
cd packages/genericsuite-fe
git add src/lib/services/generic.editor.rfc.selector.jsx src/lib/services/generic.editor.rfc.formpage.jsx src/lib/services/generic.editor.rfc.selector.test.tsx
git commit -m "Add: select_table form field - editable dropdown from related table, description in read-only [GS-select-table]"
```

---

### Task 10: Frontend — CHANGELOG

**Files:**
- Modify: `packages/genericsuite-fe/CHANGELOG.md`

- [ ] **Step 1: Add entry** (unreleased section, existing format):

```markdown
### Added
- `select_table` field type in the Generic CRUD Editor: listing and read-only form show the related record description (`{field}_description` from the backend, with client-side cached fallback); create/edit renders a dropdown populated from the related table. New JSON attributes: `related_table`, `related_key`, `description_fields`, `description_separator`, `related_filter` [GS-select-table].
```

- [ ] **Step 2: Commit**

```bash
cd packages/genericsuite-fe
git add CHANGELOG.md
git commit -m "Change: CHANGELOG entry for select_table field type [GS-select-table]"
```

---

### Task 11: Flutter — `getSelectDescription` select_table branch

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/crud_editor_selector.dart`
- Test: `packages/genericsuite-mobile/genericsuite_flutter/test/select_table_test.dart` (create)

**Interfaces:**
- Consumes: existing `getSelectDescription({currentObj, dbRow, constants, selectFieldsOptionsPromises})` and `getSelectOptionLabel` in this file.
- Produces: `select_table` branch — returns `dbRow['{name}_description']` when present, else looks up `selectFieldsOptionsPromises[fieldName]['promiseResult']` (a `Map<String, String>` of id→description prefetched by Task 12). Also exported helper `buildSelectTableDescriptionMap(List<dynamic> rows, Map<String, dynamic> currentObj) -> Map<String, dynamic>` used by Task 12.

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:genericsuite/services/crud_editor_selector.dart';

void main() {
  final currentObj = {
    'name': 'user_id',
    'type': 'select_table',
    'related_table': 'users',
    'description_fields': ['firstname', 'lastname'],
  };

  test('select_table uses backend-resolved description when present', () {
    final result = getSelectDescription(
      currentObj: currentObj,
      dbRow: {'user_id': 'aaa', 'user_id_description': 'John Doe'},
      constants: {},
      selectFieldsOptionsPromises: {},
    );
    expect(result, 'John Doe');
  });

  test('select_table falls back to prefetched options map', () {
    final result = getSelectDescription(
      currentObj: currentObj,
      dbRow: {'user_id': 'aaa'},
      constants: {},
      selectFieldsOptionsPromises: {
        'user_id': {'promiseResult': {'aaa': 'John Doe'}},
      },
    );
    expect(result, 'John Doe');
  });

  test('select_table returns null for null FK', () {
    final result = getSelectDescription(
      currentObj: currentObj,
      dbRow: {},
      constants: {},
      selectFieldsOptionsPromises: {},
    );
    expect(result, null);
  });

  test('buildSelectTableDescriptionMap builds id->description map', () {
    final map = buildSelectTableDescriptionMap(
      [
        {'_id': 'aaa', 'firstname': 'John', 'lastname': 'Doe'},
        {'_id': 'bbb', 'firstname': 'Jane'},
      ],
      currentObj,
    );
    expect(map, {'aaa': 'John Doe', 'bbb': 'Jane'});
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/genericsuite-mobile/genericsuite_flutter && flutter test test/select_table_test.dart`
Expected: FAIL — `buildSelectTableDescriptionMap` undefined; select_table falls through to plain value.

- [ ] **Step 3: Implement**

In `crud_editor_selector.dart`, add after `buildDescription`:

```dart
/// Builds an id -> description map from related-table rows for a
/// select_table field, honoring description_fields / separator /
/// related_key attributes.
Map<String, dynamic> buildSelectTableDescriptionMap(
  List<dynamic> rows,
  Map<String, dynamic> currentObj,
) {
  final String relatedKey = currentObj['related_key'] ?? '_id';
  final List<dynamic> descriptionFields =
      currentObj['description_fields'] ?? const ['name'];
  final String separator = currentObj['description_separator'] ?? ' ';
  final Map<String, dynamic> result = {};
  for (var row in rows) {
    final key = row[relatedKey]?.toString();
    if (key == null) {
      continue;
    }
    result[key] = descriptionFields
        .map((field) => row[field])
        .where((value) => value != null)
        .join(separator);
  }
  return result;
}
```

In `getSelectDescription`, add BEFORE the `'select'` branch (after the `value` declaration):

```dart
  // Related table select (1-1 relationship)
  if (currentObj['type'] == 'select_table') {
    final descAttr = '${fieldName}_description';
    if (dbRow[descAttr] != null) {
      return dbRow[descAttr];
    }
    if (value == null) {
      return null;
    }
    final Map<String, dynamic>? optionsMap =
        selectFieldsOptionsPromises[fieldName]?['promiseResult'];
    return optionsMap?[value.toString()];
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/genericsuite-mobile/genericsuite_flutter && flutter test test/select_table_test.dart`
Expected: 4 PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd packages/genericsuite-mobile/genericsuite_flutter
dart analyze lib/services/crud_editor_selector.dart test/select_table_test.dart
cd ..
git add genericsuite_flutter/lib/services/crud_editor_selector.dart genericsuite_flutter/test/select_table_test.dart
git commit -m "Add: select_table description resolution in Flutter CRUD editor selector [GS-select-table]"
```

---

### Task 12: Flutter — prefetch select_table options + listing description

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/crud_editor.dart` (`_getSelectFieldsOptions` at ~line 100, its call at line 503, `_buildListingLine`/`_getColumnName` at ~line 1533)
- Test: `packages/genericsuite-mobile/genericsuite_flutter/test/select_table_test.dart` (extend, function-level tests only — widget-level fetch is exercised in Task 13's widget test)

**Interfaces:**
- Consumes: Task 11's `buildSelectTableDescriptionMap`; existing `genericSelectGenerator` + `SelectCache` in `crud_editor_selector.dart`; `listingFieldElements`.
- Produces: `editorConfig['selectFieldsOptionsPromises'][fieldName]['promiseResult']` populated for each select_table field (id→description map); listing lines show descriptions.

- [ ] **Step 1: Extend `_getSelectFieldsOptions` to async and handle select_table**

Replace the method with:

```dart
  /*
   * Get the select fields options for field types 'select_component'
   * (with dataPopulator attribute) and 'select_table' (fetched from
   * the related table's CRUD API, cached in SelectCache).
   */
  Future<Map<String, dynamic>> _getSelectFieldsOptions() async {
    Map<String, dynamic> response = {};
    for (var currentObj in editorConfig['fieldElements']) {
      if (currentObj['type'] == 'select_component' &&
          currentObj.containsKey('dataPopulator')) {
        response[currentObj['name']] = {
          'promiseResult':
              callbacks['dataPopulators'][currentObj['dataPopulator']],
        };
        continue;
      }
      if (currentObj['type'] == 'select_table' &&
          currentObj['related_table'] != null) {
        final rows = await genericSelectGenerator(
          dbApiUrl: currentObj['related_table'],
          selectName: 'select_table_${currentObj['related_table']}',
          dbFilter: currentObj['related_filter'] != null
              ? Map<String, dynamic>.from(currentObj['related_filter'])
              : null,
          descriptionFields:
              currentObj['description_fields'] ?? const ['name'],
        );
        // genericSelectGenerator returns a String on error, or the
        // formatted id->description Map on success.
        response[currentObj['name']] = {
          'promiseResult': rows is Map<String, dynamic> ? rows : {},
        };
        continue;
      }
    }
    return response;
  }
```

NOTE for implementer: `genericSelectGenerator`'s formatted map builds descriptions via `buildDescription` (space-joined). If the field declares a custom `description_separator` or `related_key`, fetch the raw cached rows instead: after the `genericSelectGenerator` call, `SelectCache.get('select_table_${currentObj['related_table']}')` holds the raw row list — pass it through `buildSelectTableDescriptionMap(rawRows, currentObj)` and use that as `promiseResult`. Implement it that way (it covers both default and custom attributes with one code path).

Then update the caller at line ~503 (`_loadEditorConfig`): change

```dart
    editorConfig['selectFieldsOptionsPromises'] = _getSelectFieldsOptions();
```

to

```dart
    editorConfig['selectFieldsOptionsPromises'] =
        await _getSelectFieldsOptions();
```

and make the enclosing function `async` (propagate `await` at its call sites — `_loadEditorConfig` is already called from async flows; verify with `dart analyze`).

- [ ] **Step 2: Show descriptions in listing lines**

In `_buildListingLine` (~line 1540), replace the loop body:

```dart
    for (int i = colStart; i < colEnd + 1; i++) {
      line += '${item[_getColumnName(i)]} ';
    }
```

with:

```dart
    for (int i = colStart; i < colEnd + 1; i++) {
      String name = _getColumnName(i);
      if (i < listingFieldElements.length &&
          listingFieldElements[i]['type'] == 'select_table') {
        line += '${item['${name}_description'] ??
            _selectTableFallbackDescription(name, item) ?? item[name]} ';
      } else {
        line += '${item[name]} ';
      }
    }
```

and add the private helper to the same class:

```dart
  /*
   * Client-side fallback for select_table listing descriptions when
   * the backend didn't provide '{name}_description'.
   */
  String? _selectTableFallbackDescription(
    String name,
    Map<String, dynamic> item,
  ) {
    final options =
        editorConfig['selectFieldsOptionsPromises']?[name]?['promiseResult'];
    final value = item[name];
    if (options == null || value == null) {
      return null;
    }
    return options[value.toString()];
  }
```

- [ ] **Step 3: Verify**

Run: `cd packages/genericsuite-mobile/genericsuite_flutter && dart analyze && flutter test`
Expected: analyze clean, all tests PASS.

- [ ] **Step 4: Commit**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/lib/services/crud_editor.dart
git commit -m "Add: select_table options prefetch and listing descriptions in Flutter CRUD editor [GS-select-table]"
```

---

### Task 13: Flutter — form field `select_table` (read-only + editable dropdown)

**Files:**
- Modify: `packages/genericsuite-mobile/genericsuite_flutter/lib/services/form_field_service.dart` (new case in the field-type switch, next to `case 'select_component':` at ~line 489)
- Test: `packages/genericsuite-mobile/genericsuite_flutter/test/select_table_form_test.dart` (create)

**Interfaces:**
- Consumes: `widget.editorConfig['selectFieldsOptionsPromises'][fieldName]['promiseResult']` (Task 12), `getSelectOptionLabel`, `putSelectOptionsFromArray` (both already used by the `select` case), `widget.selectedItem`, `readOnly`.
- Produces: `select_table` renders `TextFormField(readOnly: true)` with the description in read-only state, `DropdownButtonFormField<String>` in edit state.

- [ ] **Step 1: Write the failing widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genericsuite/services/form_field_service.dart';

// Build the minimal widget-under-test the same way existing form tests do:
// if there is no existing form_field_service test to copy setup from,
// instantiate the form fields widget with:
//   editorConfig: {
//     'fieldElements': [
//       {'name': 'user_id', 'type': 'select_table',
//        'related_table': 'users', 'label': 'User'},
//     ],
//     'selectFieldsOptionsPromises': {
//       'user_id': {'promiseResult': {'aaa': 'John Doe', 'bbb': 'Jane Roe'}},
//     },
//   },
//   selectedItem: {'user_id': 'aaa', 'user_id_description': 'John Doe'},
//   constants: {}, callbacks: {}, props: {},
// once with action/read-only mode, once with edit mode.

void main() {
  testWidgets('select_table read-only shows description text',
      (tester) async {
    // pump the form in read-only mode (see setup note above)
    // expect(find.text('John Doe'), findsOneWidget);
    // expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets('select_table edit mode shows dropdown with options',
      (tester) async {
    // pump the form in edit mode
    // expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    // await tester.tap(find.byType(DropdownButtonFormField<String>));
    // await tester.pumpAndSettle();
    // expect(find.text('Jane Roe'), findsWidgets);
  });
}
```

Implementer: fill in the pump/setup by mirroring how `FormFieldService`'s widget class (line ~161, with `selectedItem`, `editorConfig`, `constants`, `callbacks` members) is instantiated elsewhere in the package (grep for its class name in `lib/views/`); wrap in `MaterialApp(home: Scaffold(...))`. The assertions above are the required behavior.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/genericsuite-mobile/genericsuite_flutter && flutter test test/select_table_form_test.dart`
Expected: FAIL — select_table renders as default text field.

- [ ] **Step 3: Implement the case** (add after `case 'select_component':`'s `break;`)

```dart
        case 'select_table':
          Map<String, dynamic> selectElements = Map<String, dynamic>.from(
            widget.editorConfig['selectFieldsOptionsPromises']?[fieldName]
                    ?['promiseResult'] ??
                {},
          );
          if (readOnly) {
            final String descAttr = '${fieldName}_description';
            final String descriptionText =
                widget.selectedItem[descAttr]?.toString() ??
                    getSelectOptionLabel(
                        selectElements, fieldElementValue);
            formFields.add(
              TextFormField(
                key: ValueKey(fieldName),
                controller: TextEditingController(text: descriptionText),
                decoration: InputDecoration(
                  labelText: fieldElement['label'],
                ),
                readOnly: true,
              ),
            );
          } else {
            formFields.add(
              DropdownButtonFormField<String>(
                key: ValueKey(fieldName),
                isExpanded: true,
                initialValue: fieldElementValue,
                decoration: InputDecoration(
                  labelText: fieldElement['label'],
                ),
                items: putSelectOptionsFromArray(
                  selectElements: selectElements,
                ),
                onChanged: (value) {
                  widget.selectedItem[fieldName] = value!;
                },
                onSaved: (value) =>
                    widget.selectedItem[fieldName] = value!,
              ),
            );
          }
          break;
```

- [ ] **Step 4: Run all Flutter tests**

Run: `cd packages/genericsuite-mobile/genericsuite_flutter && dart analyze && flutter test`
Expected: analyze clean, all PASS.

- [ ] **Step 5: Commit**

```bash
cd packages/genericsuite-mobile
git add genericsuite_flutter/lib/services/form_field_service.dart genericsuite_flutter/test/select_table_form_test.dart
git commit -m "Add: select_table form field with read-only description and editable dropdown in Flutter [GS-select-table]"
```

---

### Task 14: Flutter — CHANGELOG + final verification

**Files:**
- Modify: `packages/genericsuite-mobile/CHANGELOG.md`

- [ ] **Step 1: Add entry** (unreleased section, existing format):

```markdown
### Added
- `select_table` field type in the Flutter CRUD editor: listing and read-only form show the related record description (backend `{field}_description` with client-side cached fallback); create/edit renders a dropdown populated from the related table [GS-select-table].
```

- [ ] **Step 2: Verify and commit**

```bash
cd packages/genericsuite-mobile/genericsuite_flutter && flutter test && cd ..
git add CHANGELOG.md
git commit -m "Change: CHANGELOG entry for select_table field type [GS-select-table]"
```

---

### Task 15: Documentation — basecamp field-type docs + superproject changelog

**Files:**
- Modify: the Generic CRUD Editor configuration docs in `packages/genericsuite-basecamp` (locate with `grep -rn "select_component" packages/genericsuite-basecamp/docs --include="*.md" -l` and edit the frontend-config field-types page found there)
- Modify: `CHANGELOG.md` (superproject root, unreleased section)

- [ ] **Step 1: Document the field type** — in the basecamp field-types page, add a `select_table` section next to `select_component`, documenting: purpose (1-1 relationship, shows related record description in listing/read-only, dropdown in create/edit), the five JSON attributes with defaults (`related_table` required; `related_key` `"_id"`; `description_fields` `["name"]`; `description_separator` `" "`; `related_filter` `{}`), the `{field}_description` response attribute, and this example:

```json
{
  "name": "user_id",
  "type": "select_table",
  "label": "User",
  "related_table": "users",
  "description_fields": ["firstname", "lastname"],
  "listing": true,
  "required": true
}
```

- [ ] **Step 2: Superproject CHANGELOG** — add under the unreleased section:

```markdown
### Added
- 1-1 relationships in the Generic CRUD Editor via the `select_table` field type, across genericsuite-be (all 5 DB engines), genericsuite-fe (GCE_RFC) and genericsuite-mobile (GCE_FLUTTER) [GS-select-table].
```

- [ ] **Step 3: Commit** (basecamp inside its submodule on `feature/select-table-relationships`; superproject at root)

```bash
cd packages/genericsuite-basecamp
git checkout -b feature/select-table-relationships develop 2>/dev/null || git checkout feature/select-table-relationships
git add -A docs && git commit -m "Add: select_table field type documentation [GS-select-table]"
cd ../..
git add CHANGELOG.md
git commit -m "Change: CHANGELOG entry for select_table 1-1 relationships [GS-select-table]" -- CHANGELOG.md
```
