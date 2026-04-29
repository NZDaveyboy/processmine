# processmine

Production-grade process mining in R and Python. Shared event-log schema, cross-language Parquet I/O, process discovery, conformance checking, performance analysis, and a Python ML layer for anomaly detection, concept drift, and next-activity prediction.

---

## Install

### R package

```r
# from a local clone
devtools::install("path/to/processmine/R")

# or from GitHub
remotes::install_github("NZDaveyboy/processmine", subdir = "R")
```

**Dependencies**: `arrow >= 16.0`, `jsonlite`, `xml2`, `tibble`, `rlang`  
**Optional**: `reticulate` (bridge to Python ML layer)

### Python package

```bash
# base (anomaly detection + drift)
pip install -e "./python"

# with LSTM prediction
pip install -e "./python[ml]"

# with PM4Py alignment conformance
pip install -e "./python[pm4py]"

# everything
pip install -e "./python[ml,pm4py]"
```

**Requires**: Python 3.11+

---

## Quick start

### R

```r
library(processmine)

# Load and validate
log <- read_xes("data/sample_logs/bpi2012_sample.xes")

# Discover process model
dfg  <- discover_dfg(log)
hnet <- discover_heuristics(log, dependency_threshold = 0.9)

# Conformance
conf <- conformance_tokenreplay(log, hnet)
conf$summary

# Performance
throughput  <- performance_throughput(log, unit = "hours")
bottlenecks <- performance_bottlenecks(log)
sla         <- performance_sla(log, list(limit = 48, unit = "hours"))

# Variants
v <- variants(log)
r <- rare_paths(log, min_support = 0.05)

# Train/test split (by case, not by row)
splits <- train_test_split_by_case(log, test_size = 0.2, random_state = 42)
train  <- splits$train
test   <- splits$test

# Save / load
write_eventlog_parquet(log, "log.parquet")
log2 <- read_eventlog_parquet("log.parquet")
```

### Python

```python
from processmine_ml import (
    read_xes, write_eventlog_parquet, read_eventlog_parquet,
    extract_case_features, detect_anomalies,
    extract_case_stream, detect_drift,
    NextActivityPredictor, train_test_split_by_case,
)

log = read_xes("data/sample_logs/bpi2012_sample.xes")

# Anomaly detection
features  = extract_case_features(log)
anomalies = detect_anomalies(log, contamination=0.05)

# Concept drift
drift = detect_drift(log, metric="throughput", delta=0.002)

# Train/test split then LSTM prediction
train, test = train_test_split_by_case(log, test_size=0.2, random_state=42)

predictor = NextActivityPredictor()
predictor.fit(train, epochs=25, hidden_size=64, num_layers=2)
predictor.predict(["Create Order", "Approve Order"], top_k=3)
predictor.evaluate(test)

# Persist
predictor.save("predictor.pt")
predictor2 = NextActivityPredictor.load("predictor.pt")
```

### R → Python bridge

```r
library(processmine)

# Anomaly detection via Python Isolation Forest
anomalies <- bridge_anomalies(log, contamination = 0.05)

# Concept drift via ADWIN
drift <- bridge_drift(log, metric = "throughput")

# LSTM prediction (requires pip install processmine-ml[ml])
predictor <- bridge_fit_predictor(log, epochs = 25)
preds     <- bridge_predict(predictor, c("Create Order", "Approve Order"))
metrics   <- bridge_evaluate(predictor, log)

# Alignment-based conformance (requires pip install processmine-ml[pm4py])
alignment <- bridge_conformance_alignment(log)
```

---

## Capabilities

### R package

| Capability | Function | Notes |
|---|---|---|
| Schema validation | `validate_eventlog()` | Enforces all v1 schema invariants |
| Read XES | `read_xes()` | Standard XES key mappings |
| Parquet I/O | `write_eventlog_parquet()` / `read_eventlog_parquet()` | UTC timestamps, schema version guard |
| Process discovery | `discover_dfg()` | Directly-Follows Graph with edge counts |
| Process discovery | `discover_heuristics()` | Heuristics miner with dependency threshold |
| Conformance | `conformance_tokenreplay()` | Token replay; per-case fitness |
| Performance | `performance_throughput()` | Configurable time units |
| Performance | `performance_bottlenecks()` | Mean transition duration per edge |
| Performance | `performance_sla()` | SLA compliance per case |
| Variants | `variants()` | All unique activity sequences + frequency |
| Variants | `rare_paths()` | Variants below a support threshold |
| Splitting | `train_test_split_by_case()` | Case-level train/test split |
| Bridge | `bridge_anomalies()` | Isolation Forest via reticulate |
| Bridge | `bridge_drift()` | ADWIN drift detection via reticulate |
| Bridge | `bridge_fit_predictor()` / `bridge_predict()` / `bridge_evaluate()` | LSTM via reticulate |
| Bridge | `bridge_conformance_alignment()` | PM4Py alignment conformance |

### Python package

| Capability | Function | Notes |
|---|---|---|
| Schema validation | `validate_eventlog()` | Mirrors R validator |
| Read XES | `read_xes()` | stdlib ElementTree parser |
| Parquet I/O | `write_eventlog_parquet()` / `read_eventlog_parquet()` | UTC timestamps, schema version guard |
| Feature extraction | `extract_case_features()` | Throughput, event count, diversity, entropy |
| Anomaly detection | `detect_anomalies()` | Isolation Forest; configurable contamination |
| Drift detection | `extract_case_stream()` / `detect_drift()` | ADWIN on throughput, event count, activity freq |
| Next-activity prediction | `NextActivityPredictor` | LSTM; fit / predict / evaluate / save / load |
| Alignment conformance | `conformance_alignments()` | PM4Py inductive miner + alignment (optional dep) |
| Splitting | `train_test_split_by_case()` | Case-level train/test split |

---

## Event-log schema

All functions consume and produce a single canonical DataFrame/tibble.

| Column | Type | Required | Notes |
|---|---|---|---|
| `case_id` | string | yes | |
| `activity` | string | yes | |
| `timestamp` | timestamp[us, UTC] | yes | |
| `start_timestamp` | timestamp[us, UTC] | no | |
| `resource` | string | no | |
| `lifecycle` | string | no | `start`, `complete`, `schedule`, `withdraw`, `suspend`, `resume` |
| `case_attrs` | map / dict | no | Arbitrary case-level key-value pairs |
| `event_attrs` | map / dict | no | Arbitrary event-level key-value pairs |

Parquet files carry `schema_version = "1.0"` metadata. Readers enforce a major-version guard.

---

## Notebooks

| Notebook | Description |
|---|---|
| `notebooks/01_process_analysis.Rmd` | R pipeline: XES → discovery → conformance → performance → variants → Parquet |
| `notebooks/02_ml_analysis.ipynb` | Python ML: features → anomaly detection → ADWIN drift → LSTM prediction |

---

## CI

```
test-r       R CMD check (R 4.4)
test-python  ruff + mypy + pytest (Python 3.11)
notebooks    papermill (Python notebook headless)
roundtrip    R bridge tests + R notebook render
```

---

## Documentation

- [`docs/user_guide.md`](docs/user_guide.md) — full usage guide: installation, data ingestion, all capabilities, end-to-end example, troubleshooting
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — schema reference, cross-language contract, design decisions

---

## License

MIT © Dave Mason
