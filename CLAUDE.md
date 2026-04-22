# Processmine

Production-grade process mining library. R (`bupaverse`) handles discovery, conformance, and performance analysis; Python (`pm4py`, `scikit-learn`, `pytorch`) handles ML — anomaly detection, concept drift, predictive monitoring. Both languages share a single event-log schema and round-trip losslessly via Parquet.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full design and canonical schema. Read it before any change that crosses the language boundary or touches the schema.

## Repository layout

```
processmine/
├── R/                        R package: the primary user surface
│   ├── DESCRIPTION
│   ├── R/                    one file per capability
│   └── tests/testthat/
├── python/
│   └── processmine_ml/       Python package: ML only
├── notebooks/
│   ├── *.Rmd                 R flows (discovery, conformance, performance)
│   └── *.ipynb               Python flows (anomaly, drift, prediction)
├── data/sample_logs/         BPI Challenge + synthetic
├── docs/status.md            capability progress tracker
├── CLAUDE.md                 this file
├── ARCHITECTURE.md           design + schema contract
└── Makefile
```

## Commands

```bash
# R
make test-r           # devtools::test("R")
make check-r          # devtools::check("R") — full R CMD check
make style-r          # styler::style_pkg("R")

# Python
make test-py          # pytest python/
make lint-py          # ruff check + mypy
make format-py        # ruff format

# Cross-language correctness
make roundtrip        # load XES -> R eventlog -> Parquet -> Python -> Parquet -> R; assert lossless
make test             # all of the above
```

`make roundtrip` is the single most important check. If it passes, the schema contract holds.

## Conventions

1. **Schema is the contract.** The event-log schema in `ARCHITECTURE.md` is canonical. To change it: update the doc, update both validators (`R/io.R::validate_eventlog`, `python/processmine_ml/io.py::validate_eventlog`), update `make roundtrip`, and bump the schema version. Never in place.
2. **Tests first.** Process mining has numerically-checkable truth — replay fitness on a known log equals a known number. Write the testthat / pytest assertion against a fixture log before the implementation.
3. **UTC at the boundary.** All timestamps are `POSIXct` with `tz = "UTC"` (R) and `pd.Timestamp` with `tz="UTC"` (Python) at every read/write. Local time is presentation only.
4. **Pin versions.** `renv.lock` and `pyproject.toml` must match the version matrix in `ARCHITECTURE.md`. Do not bump `bupaR`, `pm4py`, or `reticulate` without rerunning the full test suite including `make roundtrip`.
5. **No cross-language imports in library code.** R calls Python only through `R/bridge.R`. Python never calls R. Keeps the dependency graph a DAG.
6. **One capability per file.** `discover.R` for discovery, `conformance.R` for conformance, etc. Same on the Python side. Helps agents work in narrow scope.

## Working in this repo with Claude Code

- **Use plan mode** before starting a new capability (discovery, conformance, performance, or any ML module). Each has meaningful algorithmic choices; plan before writing.
- **Route by language.** State up front whether the task is R-only, Python-only, or crosses the bridge. Crossing the bridge is rare and always goes through `R/bridge.R`.
- **Default fixture** is `data/sample_logs/bpi2012_sample.xes` (~1k cases, fast). Use the full log only for tests that specifically need scale — mark them `@slow` or `skip_on_cran()`.
- **Alignment conformance is slow** and does not scale past ~100k cases. Default user-facing APIs to token replay; expose alignments as opt-in with a documented cost.
- **Before committing:** `make test`. Before PR: `make check-r` and `mypy` — they catch issues local tests miss.

## Current status

Track per-capability progress in `docs/status.md`. As of repo creation: scaffold only.
