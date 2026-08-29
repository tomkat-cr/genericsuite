# GS-24: Sortable Column Headers in the Generic CRUD Editor Listing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users sort the Generic CRUD Editor (GCE) listing by clicking column headers (frontend, genericsuite-fe), with the sort executed server-side via the existing `order=column|direction` query parameter (backend, genericsuite-be), initialized from the `defaultOrder` JSON config property.

**Architecture:** The backend already parses `order=column|asc` end-to-end (`GenericDbHelperSuper.get_sort_config()` with the `defaultOrder` → `primaryKeyName` → `_id` fallback chain) and applies it natively on MongoDB. The backend work is therefore: (a) fix `get_order_direction()` so DynamoDB/SQL/Supabase iterators receive `"asc"`/`"desc"` strings instead of pymongo integer constants (today they ALWAYS sort descending), (b) push the sort into the SQL `ORDER BY` clause for PostgreSQL/MySQL and into the Supabase client query (today they sort in memory AFTER `LIMIT`/`OFFSET`, so only the current page gets sorted), and (c) add missing tests for `get_sort_config`. The frontend work is all new: parse `defaultOrder`, hold sort state in the existing `gceReducer`, render clickable headers with an asc/desc indicator, and send the `order` param on every listing fetch.

**Tech Stack:** React 18 + Jest/jsdom/@testing-library (genericsuite-fe, npm); Python 3.10 + pytest + Poetry (genericsuite-be); MkDocs bilingual docs (genericsuite-basecamp).

## Global Constraints

- Ticket tag for ALL commit messages and CHANGELOG entries: `[GS-24]`.
- Shell: always `bash`.
- Backend result shape (never deviate): `{"error": bool, "error_message": str | None, "resultset": Any}`.
- Backend package manager: `poetry`. Frontend: `npm` (never yarn/pnpm).
- Work inside each submodule under `packages/` — never commit package code at the superproject root.
- Lint before staging any backend change: `poetry run flake8`, `poetry run pylint genericsuite`, `poetry run mypy` (pre-existing warnings are acceptable; new files/lines must be clean).
- Each submodule: verify you are on the `develop` branch before the first commit (`git branch --show-current`; if detached: `git checkout develop && git pull`). Commit style: `Add:|Change:|Fix: <description> [GS-24]`.
- Backend Python style: type hints on all signatures, `snake_case`, lines ≤ 79 chars, debug logs via `_ = DEBUG and log_debug(...)`.
- Frontend style: arrow-function components, class strings live in `src/lib/constants/class_name_constants.jsx`, user-visible strings live in `src/lib/constants/general_constants.jsx`.

## Recommended sub-agent models per task

When executing with subagent-driven development, dispatch:

| Tasks | Suggested model | Why |
|---|---|---|
| 1, 2 | **haiku** or sonnet | Small, fully-specified test/method additions |
| 3, 4 | **sonnet** | Iterator logic changes; needs care with deferred state |
| 5, 9, 11 | **haiku** | Mechanical: run suites, changelog edits, commits |
| 6, 7, 8 | **sonnet** | React state + JSX changes across one large file |
| 10 | **sonnet** | Bilingual docs (Spanish translation quality matters) |

## File Structure (all paths relative to `/Users/carlosramirez/desarrollo/genericsuite/`)

**Backend — `packages/genericsuite-be/`**
- Create: `tests/test_util_generic_db_helpers_sort.py` — tests for `get_sort_config`
- Modify: `genericsuite/util/db_abstractor_dynamodb.py` (class `DynamodbServiceSuper`, line 1251) — `get_order_direction` override
- Modify: `genericsuite/util/db_abstractor_sql.py` (class `SqlService`, line 1224; class `SqlFindIterator`, lines 542-666; `SqlTable.find`, lines 789-815) — `get_order_direction` override + DB-level `ORDER BY`
- Modify: `genericsuite/util/db_abstractor_supabase.py` (`SupabaseFindIterator._load_cursor`, lines 345-360; `SupabaseUtilities.cursor_execute`, lines 262-265) — push sort/limit/offset into the Supabase query
- Modify: `tests/test_db_abstractor_sql.py`, `tests/test_db_abstractor_dynamodb_operators.py`, `tests/test_db_abstractor_supabase_operators.py` — new tests appended
- Modify: `CHANGELOG.md`

**Frontend — `packages/genericsuite-fe/`**
- Modify: `src/lib/services/generic.editor.rfc.common.jsx` — new exported helpers `getDefaultSortParams`, `getToggledSort`
- Modify: `src/lib/services/generic.editor.rfc.service.jsx` — reducer sort state, `order` fetch param, clickable headers
- Modify: `src/lib/constants/class_name_constants.jsx`, `src/lib/constants/general_constants.jsx` — new constants
- Create: `src/lib/services/generic.editor.rfc.sort.test.tsx` — unit tests
- Modify: `CHANGELOG.md`

**Docs — `packages/genericsuite-basecamp/`**
- Modify: `mkdocs_root/en/Configuration-Guide/Generic-CRUD-Editor-Configuration.md` and `mkdocs_root/es/Configuration-Guide/Generic-CRUD-Editor-Configuration.md` — expand `defaultOrder` docs
- Modify: `CHANGELOG.md`

**Superproject root**
- Modify: `CHANGELOG.md`

---

## PART A — Backend (genericsuite-be)

All Task 1-5 commands run from `packages/genericsuite-be/`. The single-file pytest command needs this env prefix (call it `$TESTENV` below — paste it literally each time):

```bash
APP_DB_URI=fake_db_uri APP_DB_ENGINE=MONGODB APP_DB_NAME=mongo APP_NAME=test_app APP_STAGE=test APP_HOST_NAME=localhost APP_SECRET_KEY=fake_secret_key STORAGE_URL_SEED=xyz APP_SUPERADMIN_EMAIL=fake_email GIT_SUBMODULE_LOCAL_PATH=fake_path CLOUD_PROVIDER=aws AWS_REGION=us-east-1 GET_SECRETS_ENABLED=0 CURRENT_FRAMEWORK=fastapi poetry run pytest
```

### Task 1: Characterization tests for `get_sort_config`

The parser already exists (`genericsuite/util/generic_db_helpers_super.py:516-544`) but has zero tests. These tests document its contract; they must pass WITHOUT any production change. If any fails, STOP and report — the contract assumption is wrong.

**Files:**
- Create: `tests/test_util_generic_db_helpers_sort.py`

**Interfaces:**
- Consumes: `GenericDbHelperSuper.get_sort_config(order_param) -> (column_name, direction)`; instance attributes `query_params: dict`, `cnf_db: dict`.
- Produces: nothing used by later tasks (safety net only).

- [ ] **Step 1: Write the test file**

Create `tests/test_util_generic_db_helpers_sort.py` with exactly:

```python
"""
Tests for GenericDbHelperSuper.get_sort_config() — the parser for the
'order=column_name|direction' listing sort parameter [GS-24].
"""
import sys
from unittest.mock import MagicMock

_bson = MagicMock()
_bson.json_util = MagicMock()
_bson.json_util.dumps = lambda x: str(x)
_bson.json_util.ObjectId = str
sys.modules.setdefault("bson", _bson)
sys.modules.setdefault("bson.json_util", _bson.json_util)
sys.modules.setdefault("genericsuite.util.app_logger", MagicMock())
sys.modules.setdefault(
    "genericsuite.util.framework_abs_layer", MagicMock())

_util_mock = MagicMock()
_util_mock.get_default_resultset.return_value = {
    "error": False, "error_message": None, "resultset": {},
    "totalPages": None
}
sys.modules.setdefault("genericsuite.util.utilities", _util_mock)
sys.modules.setdefault("genericsuite.util.db_abstractor", MagicMock())
sys.modules.setdefault(
    "genericsuite.util.db_abstractor_super", MagicMock())
sys.modules.setdefault(
    "genericsuite.util.config_dbdef_helpers", MagicMock())
sys.modules.setdefault(
    "genericsuite.util.datetime_utilities", MagicMock())

from genericsuite.util.generic_db_helpers_super import \
    GenericDbHelperSuper  # noqa: E402


def _make_helper(query_params: dict = None, cnf_db: dict = None):
    """Bare instance without running __init__ (needs no DB)."""
    helper = GenericDbHelperSuper.__new__(GenericDbHelperSuper)
    helper.query_params = query_params or {}
    helper.cnf_db = cnf_db or {}
    return helper


def test_order_param_with_direction():
    helper = _make_helper()
    assert helper.get_sort_config("name|desc") == ("name", "desc")


def test_order_param_without_direction_defaults_asc():
    helper = _make_helper()
    assert helper.get_sort_config("name") == ("name", "asc")


def test_falls_back_to_order_query_param():
    helper = _make_helper(query_params={"order": "update_date|desc"})
    assert helper.get_sort_config(None) == ("update_date", "desc")


def test_falls_back_to_default_order_config():
    helper = _make_helper(cnf_db={"defaultOrder": "config_name|asc"})
    assert helper.get_sort_config(None) == ("config_name", "asc")


def test_falls_back_to_primary_key_name():
    helper = _make_helper(cnf_db={"primaryKeyName": "id"})
    assert helper.get_sort_config(None) == ("id", "asc")


def test_falls_back_to_underscore_id():
    helper = _make_helper()
    assert helper.get_sort_config(None) == ("_id", "asc")


def test_explicit_order_param_wins_over_query_param():
    helper = _make_helper(query_params={"order": "a|asc"})
    assert helper.get_sort_config("b|desc") == ("b", "desc")
```

- [ ] **Step 2: Run the tests — expect ALL PASS (characterization)**

Run: `$TESTENV tests/test_util_generic_db_helpers_sort.py -v`
Expected: 7 passed. If any test fails, STOP — do not change production code to make it pass; report the discrepancy.

- [ ] **Step 3: Commit**

```bash
git add tests/test_util_generic_db_helpers_sort.py
git commit -m "Add: unit tests for get_sort_config() listing sort parameter parsing [GS-24]"
```

### Task 2: Fix `get_order_direction()` for DynamoDB, PostgreSQL, MySQL and Supabase

Bug: `DbAbstract.get_order_direction()` (`genericsuite/util/db_abstractor_super.py:253-263`) returns pymongo integer constants (1/-1). Only MongoDB overrides it. But the DynamoDB/SQL/Supabase find-iterators' `sort(key, direction)` compare `direction != "asc"` — an integer is never `"asc"`, so those engines ALWAYS sort descending. Fix: override on the engine service classes to return the plain string. (MongoDB keeps its pymongo constants; the `$sort`/`.sort()` pymongo paths are untouched.)

**Files:**
- Modify: `genericsuite/util/db_abstractor_dynamodb.py` (class `DynamodbServiceSuper`, starts line 1251)
- Modify: `genericsuite/util/db_abstractor_sql.py` (class `SqlService`, starts line 1224 — covers PostgreSQL, MySQL and Supabase services, which all subclass it)
- Test: `tests/test_db_abstractor_dynamodb_operators.py`, `tests/test_db_abstractor_sql.py`

**Interfaces:**
- Produces: `get_order_direction(direction: str) -> str` returning `"asc"` or `"desc"` on these engines. Task 3 and 4 rely on the iterators receiving these strings.

- [ ] **Step 1: Write the failing tests**

Append to the END of `tests/test_db_abstractor_sql.py` (it already imports `SqlService` at the top):

```python
class TestGetOrderDirection:
    """SQL engines must get 'asc'/'desc' strings, not pymongo ints,
    because SqlFindIterator.sort() compares direction != 'asc' [GS-24].
    """

    def test_sql_get_order_direction_returns_strings(self):
        assert SqlService.get_order_direction(None, "asc") == "asc"
        assert SqlService.get_order_direction(None, "desc") == "desc"
```

Append to the END of `tests/test_db_abstractor_dynamodb_operators.py`:

```python
def test_dynamodb_get_order_direction_returns_strings():
    """DynamoDbFindIterator.sort() compares direction != 'asc', so the
    service must return the plain string, not pymongo ints [GS-24]."""
    from genericsuite.util.db_abstractor_dynamodb import \
        DynamodbServiceSuper
    assert DynamodbServiceSuper.get_order_direction(None, "asc") == "asc"
    assert DynamodbServiceSuper.get_order_direction(
        None, "desc") == "desc"
```

- [ ] **Step 2: Run them — expect FAIL**

Run: `$TESTENV tests/test_db_abstractor_sql.py::TestGetOrderDirection -v` and `$TESTENV tests/test_db_abstractor_dynamodb_operators.py::test_dynamodb_get_order_direction_returns_strings -v`
Expected: FAIL with assertion errors (base class returns 1/-1 integers).

- [ ] **Step 3: Implement the overrides**

Add this method to class `DynamodbServiceSuper` in `genericsuite/util/db_abstractor_dynamodb.py` (class starts at line 1251; add the method right after its first existing method, at class-body indentation):

```python
    def get_order_direction(self, direction: str) -> str:
        """
        Get the order direction for DynamoDB result sorting.

        Args:
            direction (str): "asc" or "desc".

        Returns:
            str: the normalized direction string ("asc" or "desc"),
            as expected by DynamoDbFindIterator.sort() [GS-24].
        """
        return "asc" if direction == "asc" else "desc"
```

Add the same method (identical body, docstring saying "for SQL result sorting" and "SqlFindIterator.sort()") to class `SqlService` in `genericsuite/util/db_abstractor_sql.py` (class starts at line 1224). `PostgresqlService`, `MysqlService` and `SupabaseService` all inherit from `SqlService`, so one override covers all three.

- [ ] **Step 4: Run the tests — expect PASS, then run both full engine test files**

Run: `$TESTENV tests/test_db_abstractor_sql.py tests/test_db_abstractor_dynamodb_operators.py -v`
Expected: all pass (including the pre-existing tests — the change does not affect them because existing helper tests mock `get_order_direction`).

- [ ] **Step 5: Commit**

```bash
git add genericsuite/util/db_abstractor_dynamodb.py genericsuite/util/db_abstractor_sql.py tests/test_db_abstractor_sql.py tests/test_db_abstractor_dynamodb_operators.py
git commit -m "Fix: DynamoDB/PostgreSQL/MySQL/Supabase listing sort always applied descending order because get_order_direction() returned pymongo int constants while find iterators expect 'asc'/'desc' strings [GS-24]"
```

### Task 3: DB-level `ORDER BY` for PostgreSQL/MySQL

Bug: `SqlFindIterator._load_cursor()` (`genericsuite/util/db_abstractor_sql.py:585-595`) appends `OFFSET`/`LIMIT` to the SQL, executes, THEN sorts in memory — so only the current page is sorted, and `OFFSET n LIMIT m` (that emission order) is invalid MySQL syntax anyway. Fix: when a deferred sort exists and the column is a known table column, emit `ORDER BY <quoted_col> ASC|DESC` before `LIMIT`/`OFFSET` (also correcting the clause order to `LIMIT … OFFSET …`, valid on both engines), and skip the in-memory sort. Unknown columns (potential injection vector — the column name comes from a query param) fall back to the old in-memory sort and never reach the SQL string.

**Files:**
- Modify: `genericsuite/util/db_abstractor_sql.py` (`SqlFindIterator.__init__` lines 547-564, `_load_cursor` lines 585-601, `SqlTable.find` lines 789-815)
- Test: `tests/test_db_abstractor_sql.py`

**Interfaces:**
- Consumes: `get_order_direction` strings from Task 2; `SqlUtilities._quote_identifier(name) -> str` (double quotes on Postgres, backticks on MySQL — see existing tests `test_quote_identifier_*`).
- Produces: `SqlFindIterator(cursorOrSql, table_structure, cursor_execute=..., cursor_values=..., quote_identifier=...)` — new optional `quote_identifier` kwarg. `PostgresqlFindIterator`/`MysqlFindIterator` inherit `__init__` unchanged (verify neither defines `__init__` — see `db_abstractor_postgresql.py:40`, `db_abstractor_mysql.py:37`).

- [ ] **Step 1: Write the failing tests**

Append to the END of `tests/test_db_abstractor_sql.py`:

```python
class TestSqlFindIteratorDbLevelSort:
    """Deferred sort must become a SQL ORDER BY placed before
    LIMIT/OFFSET, so the whole result set is ordered — not just the
    fetched page [GS-24]."""

    def test_deferred_sort_appends_order_by_before_limit_offset(self):
        captured = {}

        def _exec(sql, values):
            captured["sql"] = sql
            cursor = MagicMock()
            cursor.fetchall.return_value = [{"id": 1}]
            return cursor

        it = SqlFindIterator(
            'SELECT * FROM "test_table"', {"id": "int"},
            cursor_execute=_exec, cursor_values=[],
            quote_identifier=lambda col: f'"{col}"')
        it.sort("id", "desc").skip(10).limit(5)
        list(it)
        assert captured["sql"] == (
            'SELECT * FROM "test_table"'
            ' ORDER BY "id" DESC LIMIT 5 OFFSET 10')

    def test_unknown_sort_column_falls_back_to_memory_sort(self):
        captured = {}

        def _exec(sql, values):
            captured["sql"] = sql
            cursor = MagicMock()
            cursor.fetchall.return_value = [
                {"id": 2, "name": "b"}, {"id": 1, "name": "a"}]
            return cursor

        it = SqlFindIterator(
            "SELECT * FROM t", {"id": "int"},
            cursor_execute=_exec, cursor_values=[],
            quote_identifier=lambda col: f'"{col}"')
        it.sort("name", "asc")
        results = list(it)
        assert "ORDER BY" not in captured["sql"]
        assert [r["id"] for r in results] == [1, 2]

    def test_no_quote_identifier_falls_back_to_memory_sort(self):
        captured = {}

        def _exec(sql, values):
            captured["sql"] = sql
            cursor = MagicMock()
            cursor.fetchall.return_value = [{"id": 3}, {"id": 1}]
            return cursor

        it = SqlFindIterator(
            "SELECT * FROM t", {"id": "int"},
            cursor_execute=_exec, cursor_values=[])
        it.sort("id", "asc")
        results = list(it)
        assert "ORDER BY" not in captured["sql"]
        assert [r["id"] for r in results] == [1, 3]
```

- [ ] **Step 2: Run them — expect FAIL**

Run: `$TESTENV tests/test_db_abstractor_sql.py::TestSqlFindIteratorDbLevelSort -v`
Expected: first test FAILS — `__init__` rejects the `quote_identifier` kwarg (TypeError) and/or the SQL string mismatches (`OFFSET 10 LIMIT 5`, no ORDER BY).

- [ ] **Step 3: Implement**

In `genericsuite/util/db_abstractor_sql.py`:

(a) `SqlFindIterator.__init__` (lines 547-564): add the kwarg and attribute —

```python
    def __init__(
        self,
        cursorOrSql: Any,
        table_structure: Dict = None,
        cursor_execute: Callable = None,
        cursor_values: Union[List, Dict] = None,
        quote_identifier: Callable = None
    ):
```

and at the end of `__init__`, after `self._defered_limit = None`, add:

```python
        self._quote_identifier_fn = quote_identifier
```

(b) Replace `_load_cursor` (currently lines 585-601) with:

```python
    def _load_cursor(self):
        order_by_in_sql = False
        if self._type == "sql":
            if self._defered_sort and self._quote_identifier_fn:
                column, direction = self._defered_sort
                if self._table_structure is None \
                        or column in self._table_structure:
                    sql_direction = \
                        "ASC" if direction == "asc" else "DESC"
                    quoted_column = self._quote_identifier_fn(column)
                    self._sql += \
                        f" ORDER BY {quoted_column} {sql_direction}"
                    order_by_in_sql = True
            if self._defered_limit:
                self._sql += f" LIMIT {self._defered_limit}"
            if self._defered_skip:
                self._sql += f" OFFSET {self._defered_skip}"
            self._cursor = self._cursor_execute(
                self._sql, self._cursor_values)
        self._results = self._cursor.fetchall()
        if self._defered_sort and not order_by_in_sql:
            self._sort(self._defered_sort[0], self._defered_sort[1])
        self._idx = 0

        _ = DEBUG and log_debug(
            '\n\nSqlFindIterator | _load_cursor() |' +
            f'\nSQL: {self._sql}' +
            f'\nTable Structure: {self._table_structure}' +
            f'\nResults: {self._results}')
```

Note the two behavior changes vs. the old code: `ORDER BY` is emitted first, and `LIMIT` now precedes `OFFSET` (the old `OFFSET n LIMIT m` order is invalid on MySQL).

(c) `SqlTable.find` (lines 789-815), in the `if self.iterator_run_queries:` branch, pass the quoting function through:

```python
            return self.IteratorClass(
                sql, self._table_structure,
                cursor_execute=self.cursor_execute,
                cursor_values=values,
                quote_identifier=self._quote_identifier)
```

Do NOT change the non-`iterator_run_queries` branch (`run_query` cursor path) — it fetches eagerly and the in-memory sort keeps working there.

- [ ] **Step 4: Run the whole SQL test file — expect PASS**

Run: `$TESTENV tests/test_db_abstractor_sql.py -v`
Expected: all pass, including the pre-existing `test_iterator_from_cursor_returns_rows` and `test_iterator_sort_after_iter_loads_results` (cursor-type iterators are untouched). Also run `$TESTENV tests/test_db_abstractor_postgresql_mock.py tests/test_db_abstractor_mysql_mock.py -v` — `PostgresqlFindIterator`/`MysqlFindIterator` must still construct (they inherit the new `__init__` default).

- [ ] **Step 5: Commit**

```bash
git add genericsuite/util/db_abstractor_sql.py tests/test_db_abstractor_sql.py
git commit -m "Fix: PostgreSQL/MySQL listing sort now runs as a SQL ORDER BY over the whole result set instead of an in-memory sort of the already LIMIT/OFFSET-ed page; emit LIMIT before OFFSET for MySQL compatibility [GS-24]"
```

### Task 4: Supabase server-side sort + pagination push-down

Bug: `SupabaseFindIterator._load_cursor()` (`genericsuite/util/db_abstractor_supabase.py:345-360`) ignores the deferred sort/skip/limit and fetches everything, sorting in memory. Meanwhile `cursor_execute()` (lines 191-274) already reads `order_by`, `limit` and `offset` keys from the sql dict and applies them to the Supabase query — but the `order_by` branch (line 265) calls `cursor.order_by(order_by)`, a method that does not exist in supabase-py (the real API is `cursor.order(column, desc=bool)`); it is currently dead code because nothing ever sets `order_by`. Fix: inject the deferred values into `self._sql_dict` before executing, and make the `order_by` branch call the real API with a `{"column": ..., "desc": ...}` dict.

**Files:**
- Modify: `genericsuite/util/db_abstractor_supabase.py` (`SupabaseFindIterator._load_cursor` lines 345-360; `SupabaseUtilities.cursor_execute` order_by branch, lines 262-265)
- Test: `tests/test_db_abstractor_supabase_operators.py`

**Interfaces:**
- Consumes: `SqlFindIterator.sort/skip/limit` deferral fields (`_defered_sort/_defered_skip/_defered_limit`) inherited by `SupabaseFindIterator`; `cursor_execute`'s existing `limit`/`offset` handling (lines 267-274).
- Produces: `sql_dict["order_by"]` in the shape `{"column": str, "desc": bool}` — consumed only by `cursor_execute`.

- [ ] **Step 1: Write the failing test**

Append to the END of `tests/test_db_abstractor_supabase_operators.py` (reuse its existing imports/mocking header; add `from unittest.mock import MagicMock` and the `SupabaseFindIterator` import locally in the test if the file doesn't already import them):

```python
def test_supabase_deferred_sort_and_paging_pushed_into_sql_dict():
    """Deferred sort/skip/limit must reach cursor_execute via the
    sql dict so Supabase orders and pages server-side [GS-24]."""
    from genericsuite.util.db_abstractor_supabase import \
        SupabaseFindIterator
    captured = {}

    def _exec(sql_dict, values):
        captured.update(sql_dict)
        cursor = MagicMock()
        cursor.data = [{"id": 1}]
        return cursor

    it = SupabaseFindIterator(
        {"table_name": "t", "fields": "*", "where": []},
        {"id": "int"},
        cursor_execute=_exec, cursor_values=[])
    it.sort("id", "desc").skip(10).limit(5)
    results = list(it)
    assert captured["order_by"] == {"column": "id", "desc": True}
    assert captured["limit"] == 5
    assert captured["offset"] == 10
    assert results[0]["id"] == 1


def test_supabase_unknown_sort_column_not_pushed_to_query():
    """A sort column not in the table structure must not reach the
    Supabase query (injection guard); fall back to memory sort."""
    from genericsuite.util.db_abstractor_supabase import \
        SupabaseFindIterator
    captured = {}

    def _exec(sql_dict, values):
        captured.update(sql_dict)
        cursor = MagicMock()
        cursor.data = [{"id": 2, "x": "b"}, {"id": 1, "x": "a"}]
        return cursor

    it = SupabaseFindIterator(
        {"table_name": "t", "fields": "*", "where": []},
        {"id": "int"},
        cursor_execute=_exec, cursor_values=[])
    it.sort("x", "asc")
    results = list(it)
    assert "order_by" not in captured
    assert [r["id"] for r in results] == [1, 2]
```

- [ ] **Step 2: Run them — expect FAIL**

Run: `$TESTENV tests/test_db_abstractor_supabase_operators.py -v -k supabase_deferred or supabase_unknown`
(If the `-k` expression syntax fights you, run the whole file.)
Expected: first test FAILS — `captured` has no `order_by`/`limit`/`offset` keys.

- [ ] **Step 3: Implement**

(a) Replace `SupabaseFindIterator._load_cursor` (lines 345-360) with:

```python
    def _load_cursor(self):
        if self._type == "sql":
            if self._defered_sort:
                column, direction = self._defered_sort
                if self._table_structure is None \
                        or column in self._table_structure:
                    self._sql_dict["order_by"] = {
                        "column": column,
                        "desc": direction != "asc",
                    }
                    self._defered_sort = None
            if self._defered_limit:
                self._sql_dict["limit"] = self._defered_limit
                self._defered_limit = None
            if self._defered_skip:
                self._sql_dict["offset"] = self._defered_skip
                self._defered_skip = None
            self._cursor = self._cursor_execute(
                self._sql_dict, self._cursor_values)
        self._results = self._cursor.data
        if self._defered_sort:
            self._sort(self._defered_sort[0], self._defered_sort[1])
        self._idx = 0

        _ = DEBUG and log_debug(
            '\n\nSupabaseFindIterator | _load_cursor() |' +
            f'\nSQL: {self._sql_dict}' +
            f'\nValues: {self._cursor_values}' +
            f'\nTable Structure: {self._table_structure}' +
            f'\nCursor: {self._cursor}' +
            f'\nResults: {self._results}')
```

(b) In `SupabaseUtilities.cursor_execute`, replace the order_by branch (lines 262-265):

```python
            if order_by:
                _ = DEBUG and log_debug(
                    "SupabaseUtilities.cursor_execute"
                    f" | order_by: {order_by}")
                if isinstance(order_by, dict):
                    cursor = cursor.order(
                        order_by["column"],
                        desc=order_by.get("desc", False))
                else:
                    cursor = cursor.order_by(order_by)
```

(Keep the legacy `order_by(...)` else-branch so any external caller passing a string keeps its old behavior.)

- [ ] **Step 4: Run the whole Supabase test file — expect PASS**

Run: `$TESTENV tests/test_db_abstractor_supabase_operators.py -v`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add genericsuite/util/db_abstractor_supabase.py tests/test_db_abstractor_supabase_operators.py
git commit -m "Fix: Supabase listing sort, limit and offset are now pushed into the Supabase query (server-side) instead of fetching all rows and sorting in memory; use the real .order() client API [GS-24]"
```

### Task 5: Backend full verification + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (the `## [Unreleased]` section at the top)

**Interfaces:** none.

- [ ] **Step 1: Run the full suite for all four frameworks**

Run: `make test`
Expected: all four framework runs pass (skips per the table in `CLAUDE.md` are normal, failures are not).

- [ ] **Step 2: Lint the touched files**

Run: `poetry run flake8 genericsuite/util/db_abstractor_sql.py genericsuite/util/db_abstractor_supabase.py genericsuite/util/db_abstractor_dynamodb.py tests/test_util_generic_db_helpers_sort.py`
Expected: no new errors on the changed lines. Fix any that appear.

- [ ] **Step 3: Update `CHANGELOG.md`**

Under `## [Unreleased] - YYYY-MM-DD`:

Under `### Added`:
```markdown
- Unit tests for `get_sort_config()` — the parser of the `order=column_name|direction` listing sort query parameter used by the Generic CRUD Editor sortable column headers [GS-24].
```

Under `### Fixed`:
```markdown
- DynamoDB, PostgreSQL, MySQL and Supabase listing sort always applied descending order: `get_order_direction()` returned pymongo integer constants while the engines' find iterators expect `"asc"`/`"desc"` strings [GS-24].
- PostgreSQL/MySQL listing sort now runs as a SQL `ORDER BY` over the whole result set (before `LIMIT`/`OFFSET`) instead of sorting only the fetched page in memory; `LIMIT` is now emitted before `OFFSET` for MySQL compatibility [GS-24].
- Supabase listing sort, limit and offset are now pushed into the Supabase query (server-side ordering and pagination) instead of fetching all rows [GS-24].
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "Change: CHANGELOG entries for the listing sort fixes and tests [GS-24]"
```

---

## PART B — Frontend (genericsuite-fe)

All Task 6-9 commands run from `packages/genericsuite-fe/`.

### Task 6: Sort helper functions + unit tests

**Files:**
- Modify: `src/lib/services/generic.editor.rfc.common.jsx` (add two exports after `getColumns`, which ends at line 76)
- Create: `src/lib/services/generic.editor.rfc.sort.test.tsx`

**Interfaces:**
- Consumes: the editor object built by `getEditoObj` — `editor.defaultOrder` (optional string, `"col"` or `"col|asc"`/`"col|desc"`), `editor.primaryKeyName` (always set: `getColumns` sets it from the primary-key field, and `getEditoObj` line 89-91 falls back to `'id'`).
- Produces (Tasks 7-8 use these exact signatures):
  - `getDefaultSortParams(editor) -> { sortColumn: string, sortDirection: 'asc'|'desc' }`
  - `getToggledSort(currentColumn, currentDirection, clickedColumn) -> { column: string, direction: 'asc'|'desc' }`

- [ ] **Step 1: Write the failing tests**

Create `src/lib/services/generic.editor.rfc.sort.test.tsx`:

```tsx
import {
    getDefaultSortParams,
    getToggledSort,
} from './generic.editor.rfc.common.jsx';

describe('getDefaultSortParams', () => {
    it('parses a piped defaultOrder', () => {
        expect(getDefaultSortParams({ defaultOrder: 'date|desc' }))
            .toEqual({ sortColumn: 'date', sortDirection: 'desc' });
    });
    it('defaults direction to asc when no pipe', () => {
        expect(getDefaultSortParams({ defaultOrder: 'config_name' }))
            .toEqual({ sortColumn: 'config_name', sortDirection: 'asc' });
    });
    it('falls back to primaryKeyName', () => {
        expect(getDefaultSortParams({ primaryKeyName: 'id' }))
            .toEqual({ sortColumn: 'id', sortDirection: 'asc' });
    });
    it('falls back to _id when nothing is configured', () => {
        expect(getDefaultSortParams({}))
            .toEqual({ sortColumn: '_id', sortDirection: 'asc' });
    });
    it('normalizes an invalid direction to asc', () => {
        expect(getDefaultSortParams({ defaultOrder: 'name|bogus' }))
            .toEqual({ sortColumn: 'name', sortDirection: 'asc' });
    });
});

describe('getToggledSort', () => {
    it('sorts a new column ascending', () => {
        expect(getToggledSort('a', 'asc', 'b'))
            .toEqual({ column: 'b', direction: 'asc' });
    });
    it('toggles the current column from asc to desc', () => {
        expect(getToggledSort('a', 'asc', 'a'))
            .toEqual({ column: 'a', direction: 'desc' });
    });
    it('toggles the current column from desc back to asc', () => {
        expect(getToggledSort('a', 'desc', 'a'))
            .toEqual({ column: 'a', direction: 'asc' });
    });
});
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `npx jest src/lib/services/generic.editor.rfc.sort.test.tsx`
Expected: FAIL — `getDefaultSortParams is not a function` (not exported yet).

- [ ] **Step 3: Implement the helpers**

In `src/lib/services/generic.editor.rfc.common.jsx`, add after the `getColumns` function (after line 76):

```jsx
// Listing sort [GS-24]

export const getDefaultSortParams = (editor) => {
    // defaultOrder format: "column_name" or "column_name|asc|desc".
    // Fallback chain mirrors the backend get_sort_config():
    // defaultOrder -> primaryKeyName -> "_id"
    let defaultOrder = editor?.defaultOrder || editor?.primaryKeyName || '_id';
    if (!defaultOrder.includes('|')) {
        defaultOrder += '|asc';
    }
    const [sortColumn, sortDirection] = defaultOrder.split('|');
    return {
        sortColumn,
        sortDirection: sortDirection === 'desc' ? 'desc' : 'asc',
    };
};

export const getToggledSort = (currentColumn, currentDirection, clickedColumn) => ({
    column: clickedColumn,
    direction: (currentColumn === clickedColumn && currentDirection === 'asc') ? 'desc' : 'asc',
});
```

- [ ] **Step 4: Run it — expect PASS**

Run: `npx jest src/lib/services/generic.editor.rfc.sort.test.tsx`
Expected: 8 passed.

- [ ] **Step 5: Commit**

```bash
git add src/lib/services/generic.editor.rfc.common.jsx src/lib/services/generic.editor.rfc.sort.test.tsx
git commit -m "Add: getDefaultSortParams() and getToggledSort() helpers to parse the defaultOrder JSON config property and toggle column sorting in the GCE listing [GS-24]"
```

### Task 7: Sort state in `gceReducer` + `order` param on every listing fetch

**Files:**
- Modify: `src/lib/services/generic.editor.rfc.service.jsx` (initialState lines 108-118, reducer lines 120-168, destructure/dispatch lines 190-210, listing effect lines 253-305, imports lines 22-25)
- Test: `src/lib/services/generic.editor.rfc.sort.test.tsx` (append)

**Interfaces:**
- Consumes: `getDefaultSortParams` from Task 6.
- Produces: reducer action `{ type: 'SET_SORT', payload: { column, direction } }` (also resets `currentPage` to 1); state fields `sortColumn`/`sortDirection` (both `null` = "use editor default"); dispatch helper `setSort(payload)`; exported `gceReducer` (adds `export` keyword so the reducer is unit-testable). The fetch now sends `order=<column>|<direction>` — `dbApiService.paramsToUrlQuery` (`src/lib/services/db.service.jsx:58-64`) forwards it verbatim, no change needed there.

- [ ] **Step 1: Write the failing reducer test**

Append to `src/lib/services/generic.editor.rfc.sort.test.tsx` — the module mock MUST be added at the very top of the file (before all imports), because importing the service pulls in `react-markdown` transitively:

At the very top of the file, before the existing import, add:

```tsx
jest.mock('react-markdown', () => ({ __esModule: true, default: jest.fn(() => null) }));
```

Then append at the bottom:

```tsx
import { gceReducer } from './generic.editor.rfc.service.jsx';

describe('gceReducer SET_SORT', () => {
    it('stores the sort and resets pagination to page 1', () => {
        const state = { currentPage: 5, sortColumn: null, sortDirection: null };
        const newState = gceReducer(state, {
            type: 'SET_SORT',
            payload: { column: 'name', direction: 'desc' },
        });
        expect(newState.sortColumn).toBe('name');
        expect(newState.sortDirection).toBe('desc');
        expect(newState.currentPage).toBe(1);
    });
});
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `npx jest src/lib/services/generic.editor.rfc.sort.test.tsx`
Expected: FAIL — `gceReducer` is not exported (undefined).

- [ ] **Step 3: Implement**

All edits in `src/lib/services/generic.editor.rfc.service.jsx`:

(a) Import the helpers — change lines 22-25 to:

```jsx
import {
  getDefaultSortParams,
  getEditoObj,
  getToggledSort,
  setEditorParameters,
} from './generic.editor.rfc.common.jsx';
```

(b) `initialState` (lines 108-118) — add two fields after `searchText: "",`:

```jsx
  searchText: "",
  sortColumn: null,
  sortDirection: null,
```

(c) Export the reducer and add the action — change line 120 from `function gceReducer(state, action) {` to `export function gceReducer(state, action) {`, and add a case after `SET_SEARCH_TEXT` (line 139):

```jsx
    case 'SET_SORT':
      return {
        ...state,
        sortColumn: action.payload.column,
        sortDirection: action.payload.direction,
        currentPage: 1,
      };
```

(d) Destructure (lines 190-200) — add `sortColumn, sortDirection` after `searchText`:

```jsx
    searchText,
    sortColumn,
    sortDirection
```

(e) Dispatch helpers (after line 210, `setSearchText`):

```jsx
  const setSort = (p) => dispatch({ type: 'SET_SORT', payload: p });
```

(f) Listing effect — replace lines 257-260:

```jsx
      const sortDefaults = getDefaultSortParams(editor);
      let accessKeysListing = {
        page: currentPage,
        limit: rowsPerPage,
        order: `${sortColumn ?? sortDefaults.sortColumn}|${sortDirection ?? sortDefaults.sortDirection}`,
      }
```

and the dependency array (line 305):

```jsx
  }, [currentPage, rowsPerPage, editor, formMode, searchFilters, sortColumn, sortDirection]);
```

(g) Click handler — add after `goToNewPage` (lines 327-330):

```jsx
  const handleSortColumn = (columnName) => {
    const sortDefaults = getDefaultSortParams(editor);
    setInfoMsg('');
    setSort(getToggledSort(
      sortColumn ?? sortDefaults.sortColumn,
      sortDirection ?? sortDefaults.sortDirection,
      columnName
    ));
  }
```

- [ ] **Step 4: Run the sort tests and full suite — expect PASS**

Run: `npx jest src/lib/services/generic.editor.rfc.sort.test.tsx` then `npm test`
Expected: sort tests pass; full suite green (the existing `UsersConfig` snapshot only captures the wait-animation state, so it is unaffected).

- [ ] **Step 5: Commit**

```bash
git add src/lib/services/generic.editor.rfc.service.jsx src/lib/services/generic.editor.rfc.sort.test.tsx
git commit -m "Add: listing sort state (SET_SORT) to the GCE reducer and send the order=column|direction query parameter on every listing fetch, initialized from the defaultOrder JSON config property [GS-24]"
```

### Task 8: Clickable column headers with sort indicator

**Files:**
- Modify: `src/lib/constants/general_constants.jsx` — 3 message constants
- Modify: `src/lib/constants/class_name_constants.jsx` — 3 class constants (after line 201, `APP_LISTING_TABLE_HRD_ACTIONS_COL_CLASS`)
- Modify: `src/lib/services/generic.editor.rfc.service.jsx` — header JSX (lines 537-548), pre-return sort consts, imports

**Interfaces:**
- Consumes: `handleSortColumn` from Task 7; `sortColumn`/`sortDirection` state; `getDefaultSortParams`; `GsIcons` (already imported at line 8) with the existing `arrow-down-small` icon (a chevron pointing DOWN, `IconsLib.jsx:145-162`). IMPORTANT: `GsIcons` builds the class as `ML2_ICON_CLASS + className` with NO separating space (`IconsLib.jsx:150`), so the icon class constants below start with a literal leading space.
- Produces: nothing consumed later.

- [ ] **Step 1: Add the message constants**

In `src/lib/constants/general_constants.jsx`, next to the other `MSG_*` exports, add:

```jsx
export const MSG_SORT_BY = "Sort by";
export const MSG_SORTED_ASC = "Sorted ascending";
export const MSG_SORTED_DESC = "Sorted descending";
```

- [ ] **Step 2: Add the class constants**

In `src/lib/constants/class_name_constants.jsx`, after line 201 (`APP_LISTING_TABLE_HRD_ACTIONS_COL_CLASS`), add:

```jsx
export const APP_LISTING_TABLE_HDR_SORT_BUTTON_CLASS = "flex items-center cursor-pointer appListingTableHdrSortButtonClass";
// Leading space required: GsIcons concatenates ML2_ICON_CLASS + className without a separator [GS-24]
export const APP_LISTING_TABLE_HDR_SORT_ICON_ASC_CLASS = " rotate-180 appListingTableHdrSortIconAscClass";
export const APP_LISTING_TABLE_HDR_SORT_ICON_DESC_CLASS = " appListingTableHdrSortIconDescClass";
```

(`arrow-down-small` points down = descending; `rotate-180` flips it up for ascending.)

- [ ] **Step 3: Wire the header JSX**

In `src/lib/services/generic.editor.rfc.service.jsx`:

(a) Add the new constants to the existing import blocks — `MSG_SORT_BY`, `MSG_SORTED_ASC`, `MSG_SORTED_DESC` into the `../constants/general_constants.jsx` import (lines 13-20 or 90-103, wherever `MSG_*` live — keep alphabetical order), and `APP_LISTING_TABLE_HDR_SORT_BUTTON_CLASS`, `APP_LISTING_TABLE_HDR_SORT_ICON_ASC_CLASS`, `APP_LISTING_TABLE_HDR_SORT_ICON_DESC_CLASS` into the `../constants/class_name_constants.jsx` import (lines 51-89, alphabetical).

(b) Immediately BEFORE the final `return (` of `GenericCrudEditorMain` (line 470, after the `if (formMode[0] !== ACTION_LIST)` block ends at line 468 — `editor` is guaranteed non-null here), add:

```jsx
  const sortDefaults = getDefaultSortParams(editor);
  const currentSortColumn = sortColumn ?? sortDefaults.sortColumn;
  const currentSortDirection = sortDirection ?? sortDefaults.sortDirection;
```

(c) Replace the header cells map (lines 537-548) with:

```jsx
                  {Object.keys(editor.fieldElements).map(
                    (key) =>
                      editor.fieldElements[key].listing && (
                        <th
                          // scope="col"
                          key={`${editor.baseUrl}_${key}_thead_th`}
                          className={APP_LISTING_TABLE_HDR_TH_CLASS}
                        >
                          <button
                            type="button"
                            key={`${editor.baseUrl}_${key}_thead_th_sort_button`}
                            className={APP_LISTING_TABLE_HDR_SORT_BUTTON_CLASS}
                            onClick={() => handleSortColumn(editor.fieldElements[key].name)}
                            title={`${MSG_SORT_BY} ${editor.fieldElements[key].label}`}
                          >
                            {editor.fieldElements[key].label}
                            {currentSortColumn === editor.fieldElements[key].name && (
                              <GsIcons
                                icon="arrow-down-small"
                                className={currentSortDirection === 'asc' ? APP_LISTING_TABLE_HDR_SORT_ICON_ASC_CLASS : APP_LISTING_TABLE_HDR_SORT_ICON_DESC_CLASS}
                                alt={currentSortDirection === 'asc' ? MSG_SORTED_ASC : MSG_SORTED_DESC}
                              />
                            )}
                          </button>
                        </th>
                      )
                  )}
```

- [ ] **Step 4: Run the full test suite and the library build**

Run: `npm test` then `npm run build`
Expected: all tests pass (if any snapshot legitimately changed, inspect the diff — it must only show the new `<button>` header markup — then regenerate with `npx jest -u` and re-run `npm test`); build completes with no errors.

- [ ] **Step 5: Commit**

```bash
git add src/lib/services/generic.editor.rfc.service.jsx src/lib/constants/class_name_constants.jsx src/lib/constants/general_constants.jsx
git commit -m "Add: clickable column headers with asc/desc indicator icon in the GCE listing page to sort by any listed column [GS-24]"
```

### Task 9: Frontend verification + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]` section)

**Interfaces:** none.

- [ ] **Step 1: Full verification**

Run: `npm test && npm run build`
Expected: both green.

- [ ] **Step 2: Update `CHANGELOG.md`**

Under `## [Unreleased] - YYYY-MM-DD` → `### Added`:

```markdown
- Sortable column headers in the Generic CRUD Editor listing page: clicking a header sorts the listing by that column (a second click toggles ascending/descending), sending the `order=column_name|direction` query parameter to the backend so sorting happens in the database. The initial sort comes from the `defaultOrder` JSON config property (e.g. `"defaultOrder": "config_name|asc"`), falling back to `primaryKeyName` and then `_id` [GS-24].
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "Change: CHANGELOG entry for the sortable listing column headers [GS-24]"
```

---

## PART C — Documentation

### Task 10: GS Basecamp docs (EN + ES)

Commands run from `packages/genericsuite-basecamp/`.

**Files:**
- Modify: `mkdocs_root/en/Configuration-Guide/Generic-CRUD-Editor-Configuration.md` (lines 76-77, the `defaultOrder` bullet under `### General Configuration`)
- Modify: `mkdocs_root/es/Configuration-Guide/Generic-CRUD-Editor-Configuration.md` (same bullet, lines ~76-77)
- Modify: `CHANGELOG.md`

**Interfaces:** none.

- [ ] **Step 1: Update the EN `defaultOrder` documentation**

In the EN file, the current bullet (lines 76-77) is:

```markdown
* **defaultOrder**: The default order specifies the sorting criteria for data retrieved from the database in the listing page.
	+ Example: `defaultOrder": "update_date|desc` sorts data by `update_date` in descending order.
```

(Note the existing example has a malformed backtick/quote — fix it.) Replace those two lines with:

```markdown
* **defaultOrder**: The default sorting criteria for the data retrieved from the database in the listing page, with the format `column_name|direction`, where `direction` is `asc` or `desc` (defaults to `asc` when omitted). If not specified, the sort falls back to the `primaryKeyName` column and then to `_id`. Users can change the sorting at any time by clicking a column header in the listing page: the first click sorts by that column ascending, and a second click on the same column toggles to descending; an arrow indicator shows the current sort column and direction. The selected sort is sent to the backend as the `order=column_name|direction` query parameter, so the sorting is applied by the database engine (server-side), not in the browser [GS-24].
	+ Example: `"defaultOrder": "update_date|desc"` sorts data by `update_date` in descending order.
```

Keep the tab indentation of the `+ Example:` line exactly as the surrounding bullets use it.

- [ ] **Step 2: Update the ES `defaultOrder` documentation**

In the ES file, find the `* **defaultOrder**:` bullet (same position under its `### General Configuration`-equivalent heading) and replace it and its `+ Example:`/`+ Ejemplo:` line with:

```markdown
* **defaultOrder**: El criterio de ordenamiento predeterminado para los datos recuperados de la base de datos en la página de listado, con el formato `column_name|direction`, donde `direction` es `asc` o `desc` (por defecto `asc` si se omite). Si no se especifica, el ordenamiento recurre a la columna `primaryKeyName` y luego a `_id`. Los usuarios pueden cambiar el ordenamiento en cualquier momento haciendo clic en el encabezado de una columna en la página de listado: el primer clic ordena por esa columna de forma ascendente, y un segundo clic en la misma columna cambia a descendente; una flecha indica la columna y dirección de ordenamiento actual. El ordenamiento seleccionado se envía al backend como el parámetro de consulta `order=column_name|direction`, de modo que el ordenamiento lo aplica el motor de base de datos (del lado del servidor), no el navegador [GS-24].
	+ Ejemplo: `"defaultOrder": "update_date|desc"` ordena los datos por `update_date` en orden descendente.
```

(Match whichever label the ES file already uses for examples — `+ Ejemplo:` if the surrounding bullets use Spanish, `+ Example:` otherwise.)

- [ ] **Step 3: Update the basecamp `CHANGELOG.md`**

Under `## [Unreleased] - YYYY-MM-DD` → `### Changed`:

```markdown
- Expand the `defaultOrder` documentation in the Generic CRUD Editor Configuration guide (EN/ES): sortable column headers in the listing page, the `order=column_name|direction` backend query parameter, and the `primaryKeyName`/`_id` fallback chain [GS-24].
```

- [ ] **Step 4: Verify the docs build (optional but preferred)**

If `mkdocs` is available (`poetry run mkdocs build 2>/dev/null || mkdocs build`), run it and expect a successful build. If mkdocs is not installed locally, skip — the edit is prose-only.

- [ ] **Step 5: Commit**

```bash
git add mkdocs_root/en/Configuration-Guide/Generic-CRUD-Editor-Configuration.md mkdocs_root/es/Configuration-Guide/Generic-CRUD-Editor-Configuration.md CHANGELOG.md
git commit -m "Change: document sortable listing column headers and the order query parameter in the defaultOrder section of the Generic CRUD Editor Configuration guide (EN/ES) [GS-24]"
```

### Task 11: Superproject CHANGELOG

Commands run from the superproject root `/Users/carlosramirez/desarrollo/genericsuite/`.

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]` section)

**Interfaces:** none.

- [ ] **Step 1: Update the root `CHANGELOG.md`**

Under `## [Unreleased] - YYYY-MM-DD` → `### Added`:

```markdown
- Sortable column headers in the Generic CRUD Editor listing page, across genericsuite-fe (clickable headers with asc/desc indicator, `order` query parameter, `defaultOrder` JSON config) and genericsuite-be (server-side sorting fixes for DynamoDB, PostgreSQL, MySQL and Supabase), documented in genericsuite-basecamp [GS-24].
```

- [ ] **Step 2: Commit ONLY the changelog (not the submodule pointer bumps)**

```bash
git add CHANGELOG.md
git commit -m "Change: CHANGELOG entry for the GCE sortable listing column headers [GS-24]"
```

Leave the `packages/*` submodule pointer updates uncommitted at the superproject level — the repo owner bumps those during the release process.

---

## Out of scope (deliberate)

- `packages/genericsuite-mobile` (GCE_FLUTTER) sortable headers — separate ticket/plan.
- `packages/genericsuite-skills/skills/config-builder/SKILL.md` and the doc copies under `packages/genericsuite-basecamp-app/assets/` — they mirror basecamp docs and get refreshed by their own sync process.
- The MongoDB `$lookup` aggregation path and `fetch_array_rows` in-memory path already sort correctly — no changes.
- The GET like-search endpoint path does not need to pass `order_param` explicitly: `get_sort_config()` falls back to `self.query_params.get('order')`, which is populated from the request in both listing paths, and `fetch_list` already excludes `order` from the listing filters (`generic_db_helpers.py:103`).

## Verification summary (run after all tasks)

```bash
cd packages/genericsuite-be && make test
cd ../genericsuite-fe && npm test && npm run build
```

Both must be fully green before declaring GS-24 complete.
