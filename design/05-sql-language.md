# 05. SQL Language Specification

This document defines the SQL dialect of HaskDB: the grammar, the type
system, which expressions are legal in which clause, the semantics of
subqueries, and the semantics of aggregates. Anything not listed here is
not supported and must be rejected with a syntax/feature error.

## 5.1 Lexical rules

- Keywords are case-insensitive. Identifiers are case-insensitive for
  ASCII letters and are stored lower-cased *(supplementary
  specification, PostgreSQL-like)*. Double-quoted identifiers are not
  supported.
- String literals use single quotes; a quote inside is escaped by
  doubling (`'it''s'`). The literal's content must be valid UTF-8 and,
  when stored into a VARCHAR column, at most 1024 bytes.
- Numeric literals: integers (`123`, `-45`) and floating point
  (`1.5`, `1e10`, `-2.5E-3`). Integer literals must fit in INT64.
- Boolean literals: `TRUE`, `FALSE`.
- Comments: `--` to end of line *(supplementary specification)*.
- Statement terminator: `;` (handled by the wire layer for multi-
  statement strings, see 09).

## 5.2 Grammar (EBNF)

```
statement      ::= select_stmt | insert_stmt | update_stmt
                 | delete_stmt | create_table_stmt | create_index_stmt

select_stmt    ::= SELECT select_list FROM from_list
                   [ WHERE predicate ]
                   [ GROUP BY col_ref_list ]
                   [ ORDER BY order_list ]

select_list    ::= '*' | select_item (',' select_item)*
select_item    ::= col_ref [ [AS] ident ]
                 | literal [ [AS] ident ]
                 | agg_call [ [AS] ident ]

agg_call       ::= COUNT '(' '*' ')'
                 | COUNT '(' col_ref ')'
                 | (SUM|AVG|MIN|MAX) '(' col_ref ')'

from_list      ::= from_item (',' from_item)*
from_item      ::= table_name [ [AS] ident ]
                 | '(' select_stmt ')' [AS] ident        -- derived table

insert_stmt    ::= INSERT INTO table_name [ '(' ident_list ')' ]
                   VALUES '(' literal_list ')' (',' '(' literal_list ')')*

update_stmt    ::= UPDATE table_name SET assign (',' assign)*
                   [ WHERE predicate ]
assign         ::= ident '=' ( literal | col_ref )

delete_stmt    ::= DELETE FROM table_name [ WHERE predicate ]

create_table   ::= CREATE TABLE table_name
                   '(' col_def (',' col_def)* ')'
col_def        ::= ident type_name
type_name      ::= INT64 | FLOAT64 | VARCHAR | BOOLEAN
                   -- PostgreSQL-compatible aliases (see 5.3):
                   | BIGINT | INT8 | DOUBLE PRECISION | BOOL

create_index   ::= CREATE INDEX index_name ON table_name '(' ident ')'

order_list     ::= order_item (',' order_item)*
order_item     ::= ( col_ref | ordinal | output_name ) [ ASC | DESC ]
ordinal        ::= unsigned_integer          -- 1-based select-list position

predicate      ::= or_expr
or_expr        ::= and_expr ( OR and_expr )*
and_expr       ::= not_expr ( AND not_expr )*
not_expr       ::= [ NOT ] primary_pred
primary_pred   ::= '(' predicate ')'
                 | operand comp_op operand
                 | operand IS ...            -- NOT SUPPORTED (no NULL)
                 | EXISTS '(' select_stmt ')'
operand        ::= col_ref | literal
                 | '(' select_stmt ')'                    -- scalar subquery
                 | col_ref [NOT] IN '(' select_stmt ')'   -- IN subquery
comp_op        ::= '=' | '<>' | '<' | '<=' | '>' | '>='
```

Notes on the grammar:

- There is **no arithmetic anywhere in the grammar**: no `+ - * /`
  operators exist in any clause. This is a direct consequence of the
  requirements (arithmetic in the SELECT list is unsupported, and
  expressions exist mainly for WHERE predicates). Aggregate functions
  internally compute sums/averages, but users cannot write arithmetic.
- `IN` with a literal list (`IN (1,2,3)`) is **not** in the grammar;
  only `IN (subquery)`. *(Supplementary specification; flagged as
  decision D-18 whether to add it.)*
- `INSERT INTO ... SELECT` is **not** in the grammar (decision D-18).
- Joins written with explicit `JOIN` keywords are syntax errors by
  construction (the keyword is not in the grammar).

## 5.3 Type system

| SQL type | Haskell repr. | PostgreSQL wire type (OID) | Notes |
|----------|---------------|----------------------------|-------|
| INT64 | `Int64` | `int8` (20) | also accepted: `BIGINT`, `INT8` *(supplementary — PostgreSQL compatibility was requested for Integer)* |
| FLOAT64 | `Double` | `float8` (701) | `DOUBLE PRECISION` accepted |
| VARCHAR | `Text`/`ByteString` (UTF-8) | `varchar` (1043) | no length specifier in DDL; max 1024 **bytes** |
| BOOLEAN | `Bool` | `bool` (16) | `BOOL` accepted as alias |

Rules:

- No implicit type coercion except: an integer literal may be used
  where FLOAT64 is expected (it is converted to `Double`)
  *(supplementary specification)*. All other cross-type comparisons or
  assignments are errors (`22P02`/`42804` family, see 09 §9.6).
- Comparisons require both operands to have the same type (after the
  integer→float literal rule above).
- VARCHAR length is measured in UTF-8 **bytes**, not characters. A
  value longer than 1024 bytes is an error (`22001`) on INSERT/UPDATE
  and at literal-to-column assignment time.
- Assigning a value to a column of a different type is an error, except
  integer literal → FLOAT64 column.

## 5.4 Comparison and ordering semantics

- INT64, FLOAT64: numeric comparison. FLOAT64 NaN: NaN is not
  producible by any supported operation (no arithmetic; literals like
  `'NaN'` are not FLOAT64 literals and are rejected at parse of numeric
  literals) *(supplementary specification)*; `Infinity` literals are
  likewise rejected. Hence comparisons never meet NaN.
- VARCHAR: byte-wise lexicographic comparison of the UTF-8 encoding
  (no locale, no collation).
- BOOLEAN: only `=` and `<>` are defined; `<, <=, >, >=` on BOOLEAN
  operands are a type error *(supplementary specification)* — except
  inside `ORDER BY`, where false < true ordering applies (04 §4.2).

## 5.5 Expressions per clause (normative)

The requirements mandate that the design state exactly which
expressions each clause allows:

| Clause | Allowed | Not allowed |
|--------|---------|-------------|
| SELECT list | column references; literals; aggregate calls (only if the query is an aggregate query, §5.7); `*` | arithmetic, non-aggregate function calls, subqueries in the SELECT list, `CASE`, casts |
| WHERE | full predicate grammar (§5.2): column refs, literals, comparisons, AND/OR/NOT, parentheses, `EXISTS`, `IN (subquery)`, scalar subqueries as operands | aggregate calls, arithmetic |
| GROUP BY | column references only | expressions, ordinals |
| ORDER BY | output column name, select-list ordinal, or a column reference that appears in the select list; optional ASC/DESC per key | arbitrary expressions, arithmetic |
| UPDATE SET | literal or column reference (of the same table) | arithmetic, subqueries |
| INSERT VALUES | literals only | column references, expressions, subqueries |
| HAVING | — | clause does not exist |

A scalar subquery used as a WHERE operand takes the place of a literal:
its single result value must have the type expected by the comparison.

## 5.6 Subqueries

### Supported forms

1. **Derived table** in FROM: `(SELECT ...) [AS] alias`. The alias is
   **required** *(supplementary specification — PostgreSQL requires it
   too when the subquery has no usable name; requiring it always keeps
   name resolution simple and unambiguous)*. Its columns are named by
   the subquery's output column names (explicit `AS` names, or the
   underlying column name for plain column references; a literal or
   aggregate without `AS` gets the generated name `?column?`).
2. **EXISTS (subquery)**: true iff the subquery returns at least one
   row. The subquery's select list is irrelevant to the result
   (conventionally one writes `SELECT 1`, which is legal because
   literals are allowed in the select list, §5.5).
3. **col [NOT] IN (subquery)**: the subquery must return exactly one
   column, of a type comparable to `col`. True iff `col` equals at
   least one returned value. An empty subquery result makes `IN` false
   and `NOT IN` true. (With no NULLs, `NOT IN` has none of the usual
   three-valued-logic surprises.)
4. **Scalar subquery** `(SELECT ...)` as an operand in WHERE: the
   subquery must return exactly one column. If it returns **zero
   rows**, the result is an error (`scalar subquery returned no rows`,
   SQLSTATE `21000`-family — exact code in 09 §9.6)
   *(supplementary specification: with NULL unsupported, an empty
   scalar subquery cannot yield a value, so an error is the only
   consistent semantics)*. If it returns more than one row, it is an
   error (`21000`, "more than one row") — same as PostgreSQL.

### Correlation ban

A subquery must not reference any column of an outer query. The
analyzer resolves names from the innermost scope outward; **a reference
that would resolve to an outer scope is a hard error**
(`correlated subqueries are not supported`, SQLSTATE `0A000`), not a
silent inner-scope miss. There is no runtime mechanism for outer tuple
references anywhere in the executor.

### Nesting

Subqueries may nest (a subquery's own FROM/WHERE may contain further
subqueries), each level uncorrelated with all outer levels.

## 5.7 Aggregates and GROUP BY

- Aggregate functions: `COUNT(*)`, `COUNT(col)`, `SUM(col)`,
  `AVG(col)`, `MIN(col)`, `MAX(col)`.
- `COUNT(*)` counts all rows of the group. `COUNT(col)` counts all rows
  of the group too — since NULL does not exist, `COUNT(col)` and
  `COUNT(*)` always agree *(specified behaviour; stated explicitly as
  required)*. `COUNT(col)` still requires `col` to exist and be
  resolvable.
- Argument types:
  - `SUM`: INT64 or FLOAT64 argument. Result type: INT64 for INT64
    input — **overflow behaviour is decision D-09** (error vs.
    promotion); FLOAT64 for FLOAT64 input.
  - `AVG`: INT64 or FLOAT64 argument; result is always FLOAT64.
  - `MIN`/`MAX`: any supported type; result is that type; ordering per
    §5.4.
  - `COUNT`: result INT64.
- A query is an **aggregate query** if it has a GROUP BY clause or any
  aggregate call in the select list. In an aggregate query, every
  non-aggregate select item must be a grouping column ( PostgreSQL's
  rule); violations are an error (`42803`).
- Without GROUP BY, an aggregate query produces exactly one group over
  all input rows (possibly empty input, §5.8).
- GROUP BY groups on equality of the grouping columns (per §5.4
  equality). Output rows of a grouped query are produced in no
  guaranteed order unless ORDER BY is given.

## 5.8 Aggregates over empty input *(decision-linked)*

- `COUNT` over an empty input (or empty group set) is `0` — unambiguous.
- `SUM`, `AVG`, `MIN`, `MAX` over an empty input have no natural value
  in a NULL-free system. **This is decision item D-09.** Candidate
  semantics: (a) runtime error; (b) `SUM` = 0 and error for the rest.
  The provisional assumption in the executor design (08) is (a):
  an aggregate query with no GROUP BY over empty input raises an
  error for SUM/AVG/MIN/MAX. With GROUP BY, empty input simply
  produces zero groups and zero rows, which is unambiguous.

## 5.9 ORDER BY and sorting

- ORDER BY sorts the query's full result. All result rows are
  materialised in memory and sorted there; **no external sort exists**.
- If the materialised result exceeds the sort memory limit, the query
  fails with an error (`sort memory limit exceeded`, SQLSTATE `54000`)
  and the statement is rolled back. The limit is a configuration value;
  its default and configurability are decision item **D-08**. There is
  no spill path by design.
- Sort keys are evaluated per §5.5. Multi-key sorts compare keys left
  to right; ASC is default; the sort is **stable** *(supplementary
  specification)* so results are deterministic for equal keys.
- `LIMIT` does not exist; a query always returns its full result.

## 5.10 DDL semantics

- `CREATE TABLE name (col type, ...)`: at least one column; duplicate
  column names are an error; an existing table name is an error
  (`42P07`). No primary keys, no constraints, no defaults — none of
  these exist in the type/DDL system.
- `CREATE INDEX name ON table (col)`: `col` must exist; index names
  share one namespace with table names *(supplementary specification,
  PostgreSQL-like: relations and indexes live in one namespace)*; a
  duplicate name is an error. Multiple indexes on the same column are
  allowed (they are useless but harmless).
- DDL is transactional (03 §3.6).

## 5.11 Reserved words

The keyword set is exactly the words appearing in §5.2 plus
`BEGIN COMMIT ROLLBACK` (session commands, 09 §9.5), `TRUE FALSE ASC
DESC AS ON` (ON is reserved even though JOIN syntax is unsupported, to
give a clear error). Using a keyword as an identifier is a syntax
error.
