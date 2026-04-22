# Processmine — Project Plan

A production-grade process mining library built in R (primary) and Python (ML). Designed to be developed with Claude Code.

---

## 1. What this is

Processmine is a dual-language library for extracting insights from event logs. R handles the mature process mining domain — discovery, conformance checking, and performance analysis — using the `bupaverse` ecosystem. Python handles the machine-learning surface — anomaly detection, concept drift, and predictive monitoring — using `pm4py`, `scikit-learn`, and `pytorch`.

Both languages share a single canonical event-log schema and interoperate via Parquet files. There is no implicit in-memory conversion between the two; every cross-language call writes to disk and reads back, which keeps the contract explicit and timezone-safe.

The deliverable is a properly structured, installable package with tests, documentation, and example notebooks — not a one-off script. The user-facing surface is a Jupyter notebook (for Python flows) or R Markdown notebook (for R flows). The packages underneath are importable and reusable in any R or Python environment.

---

## 2. Why both languages

Each ecosystem dominates a different part of process mining.

**R owns the classical process mining stack.** The `bupaverse` — `bupaR`, `edeaR`, `processmapR`, `heuristicsmineR`, `petrinetR` — is the most complete, best-documented, and most numerically stable ecosystem for process discovery, conformance, and performance. Replicating it in Python would waste months for no gain.

**Python owns machine learning.** Anomaly detection with isolation forests or autoencoders, concept drift with ADWIN or Page-Hinkley, trace embeddings, and next-activity prediction with LSTMs or gradient boosting are all dramatically easier and better supported in Python. `scikit-learn` and `pytorch` have no real R equivalent for this work.

Trying to do ML in R or trying to do classical process mining in Python both result in worse code. The split is not ideological; it reflects where each ecosystem is actually strong.

---

## 3. Architecture at a glance

```
   R Package (primary)                     Python Package (ML)
   ------------------                      --------------------
   R/                                      python/processmine_ml/
   ├── io.R          load / validate       ├── io.py       load / validate
   ├── discover.R    discovery algos       ├── anomaly.py  isolation forest, AE
   ├── conformance.R replay + alignments   ├── drift.py    ADWIN, Page-Hinkley
   ├── performance.R throughput, SLA       ├── prediction.py next-activity, time
   ├── variants.R    variant analysis      └── embeddings.py activity2vec
   └── bridge.R      reticulate -> Python

                          shared contract
                   ┌──────────────────────────┐
                   │  event-log schema v1     │
                   │  (Parquet + validators)  │
                   └──────────────────────────┘
```

The bridge is one-directional. R calls Python via `reticulate`; Python never calls R. Data crosses the boundary only as Parquet files on disk, which preserves types and timezones losslessly.

---

## 4. Event log schema (canonical, v1)

The schema is the contract between the two languages. Both validators enforce it identically.

| Column | Type | Required | Notes |
|---|---|---|---|
| `case_id` | string | yes | unique identifier of a process instance |
| `activity` | string | yes | activity / event name |
| `timestamp` | timestamp\[ns, UTC\] | yes | event completion time, UTC enforced |
| `start_timestamp` | timestamp\[ns, UTC\] | no | event start time, enables duration analysis |
| `resource` | string | no | resource / actor performing the activity |
| `lifecycle` | enum | no | `start`, `complete`, `schedule`, `withdraw`, `suspend`, `resume` |
| `case_attrs` | map\<string, string\> | no | case-level attributes |
| `event_attrs` | map\<string, string\> | no | event-level attributes |

**Invariants enforced at validation:**

- All timestamps have `tz = UTC`.
- `timestamp >= start_timestamp` where both are present.
- `case_id`, `activity`, and `timestamp` are non-null.
- Events within a case are sorted by `timestamp` ascending; ties broken by file order.
- String columns are UTF-8.
- Parquet metadata includes `schema_version = "1.0"`; unknown major versions are rejected.

---

## 5. Capabilities and scope

### Process discovery (R)

- `discover_dfg(log, noise_threshold = 0)` — directly-follows graph.
- `discover_heuristics(log, dependency_threshold = 0.9)` — heuristics miner.
- `discover_inductive(log, noise_threshold = 0.2)` — inductive miner, delegated to PM4Py via the bridge because no R implementation is as solid.

Returns a `processmine_model` object that can be plotted, exported to BPMN, or passed to conformance.

### Conformance checking (R)

- `conformance_tokenreplay(log, model)` — default, scales well, per-case fitness and global fitness / precision.
- `conformance_alignments(log, model, timeout = 30)` — optimal alignments via PM4Py. Opt-in because it is computationally expensive — avoid for logs with >100k cases unless time permits.

Both return a `processmine_conformance` object with `$summary`, `$per_case`, and `$diagnostics`.

### Performance analysis (R)

- `performance_throughput(log, unit = "hours")` — case durations, percentiles.
- `performance_bottlenecks(log, method = "handover")` — identify slow transitions.
- `performance_sla(log, sla_spec)` — custom SLA breaches, with `sla_spec` as a named list of activity to max duration.

### Variant and anomaly analysis (mixed)

- R: `variants(log)`, `rare_paths(log, min_support = 0.01)`.
- Python: `detect_isolation_forest(log_path, contamination = 0.05)` — per-case anomaly scores.
- Python: `detect_autoencoder(log_path, embedding_dim = 64)` — trace-level reconstruction error.

### Concept drift (Python)

- `detect_drift_adwin(log_path, window = "1w")` — adaptive window over variant frequencies.
- `detect_drift_pagehinkley(log_path)` — Page-Hinkley on fitness time series.

### Predictive monitoring (Python)

- `predict_next_activity(log_path, model = "lstm")` — next-activity classifier.
- `predict_remaining_time(log_path, model = "xgb")` — regression on remaining case duration.

---

## 6. Repository layout

```
processmine/
├── R/                          R package: the primary user surface
│   ├── DESCRIPTION
│   ├── NAMESPACE
│   ├── R/                      one file per capability
│   │   ├── io.R
│   │   ├── discover.R
│   │   ├── conformance.R
│   │   ├── performance.R
│   │   ├── variants.R
│   │   └── bridge.R
│   ├── tests/testthat/
│   └── vignettes/
│
├── python/
│   └── processmine_ml/         Python package: ML only
│       ├── __init__.py
│       ├── io.py
│       ├── anomaly.py
│       ├── drift.py
│       ├── prediction.py
│       └── embeddings.py
│
├── notebooks/                  the interactive surface
│   ├── 01_discovery.Rmd
│   ├── 02_conformance.Rmd
│   ├── 03_performance.Rmd
│   ├── 04_anomaly.ipynb
│   └── 05_drift.ipynb
│
├── data/sample_logs/           BPI Challenge + synthetic
├── scripts/
│   └── roundtrip_check.R       cross-language schema correctness test
├── docs/
│   ├── status.md               capability progress tracker
│   └── decisions.md            architecture decision log
│
├── CLAUDE.md                   guidance for Claude Code sessions
├── ARCHITECTURE.md             design + schema reference
├── README.md
├── Makefile
├── renv.lock                   R lockfile
├── pyproject.toml              Python package config
└── .gitignore
```

---

## 7. Setup

**R side** (R 4.4+):

```bash
Rscript -e "install.packages('renv'); renv::restore()"
```

**Python side** (Python 3.11):

```bash
pip install -e "./python[dev]"
```

**Verify both work together:**

```bash
make roundtrip
```

This loads a sample log in R, converts to Parquet, reads it in Python, writes it back, and confirms the round trip is lossless. If this passes, the schema contract holds and cross-language calls are safe.

---

## 8. Version matrix

Pinned deliberately. Bump only with a full test run.

| Component | Version |
|---|---|
| R | 4.4.x |
| bupaR | 0.5.4 |
| edeaR | 0.9.4 |
| processmapR | 0.5.3 |
| heuristicsmineR | 0.3.0 |
| reticulate | 1.38.0 |
| arrow (R) | 16.0.0 |
| Python | 3.11 |
| pm4py | 2.7.11 |
| pandas | 2.2.x |
| pyarrow | 16.0.0 |
| scikit-learn | 1.5.x |
| torch | 2.3.x |

---

## 9. Development workflow with Claude Code

Claude Code is well-suited to this project because the work decomposes cleanly into self-contained capabilities, each with a numerically checkable correctness criterion. The recommended workflow:

1. **Start every session with `CLAUDE.md`.** It sits at the repo root and is read automatically. It defines the schema contract, the language split, and the key commands.
2. **Use plan mode before each capability.** Discovery, conformance, performance, and each ML module have non-obvious algorithmic choices. Use `/plan` to lay out the approach, confirm the tests, then implement.
3. **Route tasks by language.** State up front whether a task is R-only, Python-only, or crosses the bridge. Crossing is rare and always goes through `R/bridge.R`.
4. **Tests first.** Every capability should start from a fixture-based test with a known-true number. Write the assertion, then the implementation. Process mining is one of the few domains where this is genuinely easy — the reference datasets have been replayed thousands of times and the expected outputs are public.
5. **Hooks.** On save, run `styler` + `testthat` for changed R files; `ruff` + `pytest -k <changed>` for changed Python files. Keeps the package clean without overhead.
6. **Commit discipline.** One capability per PR. Every PR must pass `make test` (which includes `make roundtrip`).

### Subagents

Consider two dedicated subagents:

- **R agent** — lives in `R/`, knows `bupaverse` and `devtools`, runs `devtools::check()` as its verification step.
- **Python agent** — lives in `python/`, knows `pm4py` and `pytorch`, runs `pytest` and `mypy` as its verification step.

Isolating context per language keeps each agent focused and reduces the chance of one language's conventions leaking into the other.

---

## 10. Roadmap (proposed milestones)

**Milestone 1 — Foundation (1 week).** Schema + both validators + Parquet round-trip test + sample data pipeline. Nothing else.

**Milestone 2 — R core (2 weeks).** Discovery (DFG, heuristics, inductive via bridge) + token replay conformance + basic performance metrics. Three working R Markdown notebooks.

**Milestone 3 — Python ML core (2 weeks).** Isolation forest anomaly detection + ADWIN drift detection + next-activity prediction. Two working Jupyter notebooks.

**Milestone 4 — Polish (1 week).** Alignments conformance, autoencoder anomaly, remaining-time prediction, SLA analysis, variants.

**Milestone 5 — Production readiness (1 week).** CI (GitHub Actions for both languages), pkgdown site, Python docs site, tagged 0.1.0 release.

Total: ~7 weeks of focused effort. Aggressive but achievable with Claude Code driving most of the implementation against fixture-based tests.

---

## 11. Known risks and mitigations

- **Timezone drift.** XES files often declare timestamps in local time. The loader converts at read time and stamps UTC; everything downstream assumes UTC. Tests include a log with mixed local timezones to ensure correctness.
- **bupaR factor levels.** `bupaR` stores activity as a factor with implicit ordering. Always convert to string at the Parquet boundary to avoid silent reordering on round-trip.
- **PM4Py API changes.** PM4Py has shifted its API several times. Pin to 2.7.11 and wrap all PM4Py calls in a single adapter module (`bridge.R` + `python/processmine_ml/_pm4py_adapter.py`) so an upgrade touches one place.
- **Alignment blow-ups.** For models with parallelism and logs >10k cases, alignments can take hours. All alignment-based APIs take a per-trace timeout with a sensible default (30s).
- **reticulate + torch thread fights on macOS.** `reticulate` and `torch` can conflict over OpenMP thread pools. Set `OMP_NUM_THREADS=1` in `.Renviron` for dev; document tuning for production.
- **Large Parquet files.** Arrow writes nanosecond timestamps by default; older PM4Py versions expect microseconds. Pin pyarrow >= 16 and set `coerce_timestamps="us"` when writing for PM4Py consumption.

---

## 12. Suggested first move

Rather than scaffolding every module, build the **schema + I/O layer in both languages first**, with the round-trip test passing on a real BPI Challenge log. Everything else hangs off that contract. It's a single afternoon of work and de-risks the entire project. Once the schema is proven correct and lossless, every subsequent capability is self-contained and can be developed in isolation.

---

## 13. Building in GitHub

The repo is designed to live on GitHub from day one. The `.github/` and `.devcontainer/` directories hold everything needed for automated testing, documentation deployment, and zero-setup development. Intended home: `github.com/nzdaveyboy/processmine`.

### Continuous integration

`.github/workflows/test.yml` runs on every push and pull request against `main`:

- **`test-r`** — sets up R 4.4, restores dependencies, runs `R CMD check` via `rcmdcheck`.
- **`test-python`** — sets up Python 3.11, installs the package with dev extras, runs `ruff`, `mypy`, and `pytest` with coverage uploaded to Codecov.
- **`roundtrip`** — depends on both above; sets up both environments and runs `scripts/roundtrip_check.R` to verify the schema contract holds across languages.

Only green builds merge to `main`. The round-trip check is the most important guard because a regression there silently breaks every cross-language capability. Make it a required status check in branch protection.

### Release automation

`.github/workflows/release.yml` triggers on version tags (`v*.*.*`):

- Builds the Python wheel and sdist and publishes to PyPI via trusted publishing (OIDC, no API tokens to manage).
- Builds the R `pkgdown` site and deploys to GitHub Pages.
- Generates a GitHub release with auto-generated notes; release candidates (`-rc`, `-beta`, `-alpha` in the tag) are marked as pre-release automatically.

Publishing the R package itself is handled separately via `nzdaveyboy.r-universe.dev`, which polls the repo and builds binaries — no workflow needed on this side.

### Codespaces / dev container

`.devcontainer/Dockerfile` builds on `rocker/r-ver:4.4.0` and adds Python 3.11 via the deadsnakes PPA, plus the system libraries that `arrow`, `pm4py`, and `ragg` need. `devcontainer.json` wires in the R and Python VS Code extensions, sets `radian` as the R REPL, `ruff` as the Python formatter, and `OMP_NUM_THREADS=1` so reticulate and torch don't fight over thread pools.

Opening the repo in Codespaces gives a working environment in roughly 90 seconds — no local R install, no Python venv. Useful for onboarding collaborators, running the ML notebooks on a machine with real RAM, and for Claude Code sessions that you want running in a reproducible cloud environment.

### Issues and Projects

Each capability in `docs/status.md` becomes a GitHub issue. Group them into a Projects board with columns for the five milestones in section 10. PRs auto-link to issues via `Closes #N`, which keeps the board in sync without manual bookkeeping.

### Claude Code and GitHub

Three modes of operation:

1. **Local Claude Code against a cloned repo.** Normal workflow. Claude Code reads `CLAUDE.md` on each session; you push when ready.
2. **Claude Code in a Codespace.** Spin up the devcontainer, run Claude Code inside it. Useful when you need a reproducible environment or more resources than your laptop.
3. **Claude GitHub app.** Install the official Anthropic GitHub app on the repo. It can respond to `@claude` mentions in issues and PRs — draft fixes, review code, suggest refactors — and is particularly useful for the "one issue per capability" model where each issue has a well-scoped deliverable.

### Branch protection (recommended settings)

- `main` requires pull request before merging, with at least one approval (self-approval is fine for solo projects, but keep the gate).
- Required status checks: `test-r`, `test-python`, `roundtrip`.
- Require branches to be up to date before merging.
- Require signed commits if you have GPG or SSH commit signing set up.

### Secrets to configure before first release

- PyPI trusted publisher: configure at `pypi.org/manage/account/publishing/` pointing at `nzdaveyboy/processmine`, workflow `release.yml`, environment `pypi`. No secret needed on GitHub.
- GitHub Pages: enable in repo settings, source `gh-pages` branch.
- Codecov: add `CODECOV_TOKEN` (only needed for private repos).

---

## 14. Licence

MIT. Event log samples used for testing (BPI Challenge logs) are available under CC BY 4.0 from the 4TU.ResearchData repository.
