# Processmine — Architecture

This document is the canonical reference for the event-log schema and the design decisions behind it. Read it before any change that crosses the language boundary or touches the schema. All other docs defer to this one.

---

## Why two languages

R owns the classical process mining stack. The `bupaverse` — `bupaR`, `edeaR`, `processmapR`, `heuristicsmineR` — is the most complete and numerically stable ecosystem for discovery, conformance, and performance analysis. Replicating it in Python would waste months for no gain.

Python owns machine learning. Isolation forests, autoencoders, ADWIN drift detection, LSTM next-activity prediction — all dramatically easier in `scikit-learn` and `pytorch`. There is no real R equivalent for this work.

The two packages share data through Parquet files on disk. There is no in-memory bridge between them in Milestone 1. `R/bridge.R` (Milestone 2+) will use `reticulate` for the one case where R needs to call a Python algorithm directly (inductive miner).

---

## Repository layout

```
processmine/
├── R/                          R package — primary user surface
│   ├── DESCRIPTION
│   ├── NAMESPACE
│   ├── R/
│   │   └── io.R                read_xes, validate_eventlog,
│   │                           write_eventlog_parquet, read_eventlog_parquet
│   └── tests/testthat/
│       ├── fixtures/tiny.xes   3-case XES fixture used by tests
│       └── test-io.R
│
├── python/
│   ├── pyproject.toml
│   └── processmine_ml/         Python package — ML only
│       ├── __init__.py
│       └── io.py               equivalent four functions
│
├── scripts/
│   ├── roundtrip_check.R       cross-language schema correctness test
│   └── _roundtrip_py.py        Python leg of the round-trip
│
├── data/sample_logs/           BPI Challenge + synthetic logs
├── Makefile
├── renv.lock
└── .github/workflows/test.yml
```

---

## Event-log schema (v1, canonical)

This is the contract between R and Python. Both validators enforce it identically. Neither side may relax an invariant without updating both.

| Column | Parquet physical type | R in-memory type | Python in-memory type | Required |
|---|---|---|---|---|
| `case_id` | `string` | `character` | `str` | yes |
| `activity` | `string` | `character` | `str` | yes |
| `timestamp` | `timestamp[us, UTC]` | `POSIXct` tz=UTC | `datetime64[us, UTC]` | yes |
| `start_timestamp` | `timestamp[us, UTC]` | `POSIXct` tz=UTC | `datetime64[us, UTC]` | no |
| `resource` | `string` | `character` | `str` | no |
| `lifecycle` | `string` | `character` | `str` | no |
| `case_attrs` | `string` (JSON) | named `character` vector | `dict[str, str]` | no |
| `event_attrs` | `string` (JSON) | named `character` vector | `dict[str, str]` | no |

**Invariants enforced at validation:**

- `case_id`, `activity`, `timestamp` are non-null in every row.
- All timestamps carry `tz = UTC`. Local time is presentation only.
- `timestamp >= start_timestamp` wherever both are non-NA.
- `lifecycle`, when present, is one of: `start`, `complete`, `schedule`, `withdraw`, `suspend`, `resume`.
- Parquet file metadata includes `schema_version = "1.0"`. Unknown major versions are rejected at read time.

**`case_attrs` / `event_attrs` encoding:**

The logical type is `map<string, string>`. The physical Parquet type is `string` (JSON-serialised). On write, each dict/named-vector is serialised with keys sorted. On read, it is deserialised back to the native type. This avoids Arrow map-type API differences between R 4.4 and Python 3.11 while remaining lossless.

**Timestamp precision:**

Arrow writes `timestamp[us]` (microseconds), not nanoseconds, even though the schema annotation says `ns`. This is deliberate: PM4Py 2.7.x rejects nanosecond Parquet timestamps. The precision is sufficient for all process mining work.

---

## Version matrix

| Component | Pinned version |
|---|---|
| R | 4.4.x |
| arrow (R) | ≥ 16.0.0 |
| jsonlite (R) | any (CRAN stable) |
| xml2 (R) | any (CRAN stable) |
| Python | 3.11 |
| pyarrow | ≥ 16.0.0 |
| pandas | ≥ 2.2 |

Do not bump `arrow` / `pyarrow` without re-running `make roundtrip`. The Parquet timestamp encoding changed between Arrow 15 and 16.

---

## I/O layer — how it works

### Reading XES (R)

```r
library(processmine)

log <- read_xes("data/sample_logs/bpi2012_sample.xes")
# Returns a validated tibble:
# # A tibble: 262,200 × 7
#   case_id  activity   timestamp           resource lifecycle case_attrs event_attrs
#   <chr>    <chr>      <dttm>              <chr>    <chr>     <list>     <list>
```

XES key mapping applied at read time:

| XES attribute | Schema column |
|---|---|
| trace `concept:name` | `case_id` |
| event `concept:name` | `activity` |
| event `time:timestamp` | `timestamp` |
| event `org:resource` | `resource` |
| event `lifecycle:transition` | `lifecycle` |
| all other trace attributes | `case_attrs` |
| all other event attributes | `event_attrs` |

### Reading XES (Python)

```python
from processmine_ml import read_xes

log = read_xes("data/sample_logs/bpi2012_sample.xes")
# Returns a validated DataFrame:
#    case_id   activity                  timestamp resource  lifecycle case_attrs event_attrs
# 0  case-1    submit   2012-01-08 08:00:00+00:00    alice   complete  {...}      {...}
```

### Validation

Both languages validate on read and write. Call explicitly if you construct a log in memory:

```r
# R
validate_eventlog(my_log)           # throws on violation, returns log invisibly
```

```python
# Python
from processmine_ml import validate_eventlog
validate_eventlog(df)               # raises ValueError on violation, returns df
```

Common rejection reasons and their messages:

| Violation | R message | Python message |
|---|---|---|
| Missing required column | `Missing required column(s): case_id` | same |
| NA in required column | `Column 'activity' contains NA values` | `contains Null/NA values` |
| Non-UTC timestamp | `must have tz = UTC (got 'America/New_York')` | `must have tz=UTC` |
| `start_timestamp` after `timestamp` | `start_timestamp must be <= timestamp` | same |
| Invalid lifecycle value | `Invalid lifecycle value(s): INVALID` | same |
| Unknown schema version | `Unsupported schema version '2.0'` | same |

### Writing Parquet (R → Python)

```r
# R writes
write_eventlog_parquet(log, "output/daily.parquet")
```

```python
# Python reads the same file
from processmine_ml import read_eventlog_parquet
df = read_eventlog_parquet("output/daily.parquet")
```

### Writing Parquet (Python → R)

```python
# Python writes
from processmine_ml import write_eventlog_parquet
write_eventlog_parquet(df, "output/scored.parquet")
```

```r
# R reads
back <- read_eventlog_parquet("output/scored.parquet")
```

---

## Round-trip test

`make roundtrip` is the single most important correctness check. It runs `scripts/roundtrip_check.R`, which:

1. Builds a synthetic fixture — 10 cases, 3 activities, UTC timestamps, `start_timestamp`, `resource`, `lifecycle`, `case_attrs`, `event_attrs`.
2. Validates it in R.
3. Writes it to a temp Parquet file (`tmp1`).
4. Invokes `scripts/_roundtrip_py.py tmp1 tmp2` — Python reads `tmp1`, validates, writes `tmp2`.
5. R reads `tmp2`.
6. Asserts column-level equality on all 8 schema columns. `case_attrs` and `event_attrs` are normalised (keys sorted, serialised to `key=value` strings) before comparison.
7. Prints `*** ROUNDTRIP PASS ***` or stops with a diff.

```
$ make roundtrip
Fixture rows: 26
Fixture cases: 10
[OK] R validate_eventlog passed
[OK] R write_eventlog_parquet -> /tmp/Rtmp.../file....parquet
[OK] Python read/write complete
[OK] R read_eventlog_parquet from Python output

Column-level equality checks:
  [=] case_id              OK
  [=] activity             OK
  [=] timestamp            OK
  [=] start_timestamp      OK
  [=] resource             OK
  [=] lifecycle            OK
  [=] case_attrs           OK
  [=] event_attrs          OK

*** ROUNDTRIP PASS ***
```

If it fails, the diff printed by `stopifnot_equal` shows which column diverged and what the mismatch is.

---

## Makefile targets

```
make test-r        # devtools::test("R") — R unit tests
make check-r       # devtools::check("R") — full R CMD check
make style-r       # styler::style_pkg("R")

make test-py       # pytest python/
make lint-py       # ruff check + mypy
make format-py     # ruff format

make roundtrip     # scripts/roundtrip_check.R
make test          # test-r + test-py + roundtrip
```

---

## CI (`.github/workflows/test.yml`)

Three jobs, all required to merge to `main`:

| Job | What it runs | Depends on |
|---|---|---|
| `test-r` | `roxygen2::roxygenise` → `R CMD check --no-manual --as-cran` | — |
| `test-python` | `pip install -e ./python[dev]` → `ruff` → `mypy` → `pytest --cov` | — |
| `roundtrip` | `Rscript scripts/roundtrip_check.R` (both R and Python env installed) | `test-r`, `test-python` |

The `roundtrip` job only runs after both language jobs pass. A regression in either language that breaks the schema contract will be caught here even if each language's own tests pass.

---

## Extending the schema

Never change the schema in place. The process:

1. Update this document — section "Event-log schema".
2. Update `R/R/io.R::validate_eventlog` and `python/processmine_ml/io.py::validate_eventlog` identically.
3. Update `_PARQUET_SCHEMA` in `io.py` and the corresponding Arrow field construction in `write_eventlog_parquet` in `io.R`.
4. Bump `schema_version` in both `SCHEMA_VERSION` constants if the change is breaking (new required column, removed column, type change). Minor additions of optional columns do not require a version bump.
5. Update `scripts/roundtrip_check.R` to exercise the new column.
6. Run `make test`. The roundtrip must pass before merging.

---

## Known constraints

**`case_attrs` / `event_attrs` are JSON strings, not Arrow map type.** Arrow's map type has different in-memory representations in R (list of data frames) and Python (list of tuples pre-pyarrow-13, dict post). The JSON string approach is lossless, roundtrips cleanly, and is easily inspectable. Migration to native map type is a future non-breaking schema change.

**Timestamps are microseconds, not nanoseconds.** PM4Py 2.7.x reads Parquet and rejects nanosecond timestamps. The schema annotation says `timestamp[ns, UTC]` as a logical precision target; the physical file uses `us`.

**`reticulate` / `torch` thread conflict on macOS.** Set `OMP_NUM_THREADS=1` in `.Renviron` for local dev. The devcontainer sets this automatically.

**Alignment conformance is slow.** For logs with more than ~100k cases, optimal alignments via PM4Py can take hours. All alignment APIs will take a per-trace timeout defaulting to 30s. Token replay is the default; alignments are opt-in.
