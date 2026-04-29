# Processmine — Capability Status

Track per-capability progress. Update this file when a capability is added, changed, or removed.

## Legend

| Symbol | Meaning |
|---|---|
| ✓ | Implemented and tested |
| ~ | Partial / in progress |
| ✗ | Not started |

---

## R package (`R/`)

### Schema & I/O (Milestone 1)

| Capability | File | Status | Notes |
|---|---|---|---|
| `validate_eventlog()` | `io.R` | ✓ | Enforces all v1 schema invariants |
| `read_xes()` | `io.R` | ✓ | XES standard key mappings, case/event attrs |
| `write_eventlog_parquet()` | `io.R` | ✓ | JSON-encoded attrs, schema_version metadata |
| `read_eventlog_parquet()` | `io.R` | ✓ | Version guard, UTC restoration |
| Cross-language round-trip | `scripts/roundtrip_check.R` | ✓ | R → Parquet → Python → Parquet → R, all 8 columns |

### Process Discovery (Milestone 2)

| Capability | File | Status | Notes |
|---|---|---|---|
| `discover_dfg()` | `discover.R` | ✓ | Directly-Follows Graph with edge counts and frequency |
| `discover_heuristics()` | `discover.R` | ✓ | Heuristics miner with dependency threshold filter |

### Conformance Checking (Milestone 2)

| Capability | File | Status | Notes |
|---|---|---|---|
| `conformance_tokenreplay()` | `conformance.R` | ✓ | Token replay against DFG or heuristics net; per-case fitness |

### Performance Analysis (Milestone 2)

| Capability | File | Status | Notes |
|---|---|---|---|
| `performance_throughput()` | `performance.R` | ✓ | Per-case throughput time in configurable units |
| `performance_bottlenecks()` | `performance.R` | ✓ | Mean transition duration aggregated by edge |
| `performance_sla()` | `performance.R` | ✓ | SLA compliance check per case |

### Variant Analysis (Milestone 2)

| Capability | File | Status | Notes |
|---|---|---|---|
| `variants()` | `variants.R` | ✓ | All unique activity sequences with frequency |
| `rare_paths()` | `variants.R` | ✓ | Variants below a support threshold |

### Planned (Milestone 3+)

| Capability | Status | Notes |
|---|---|---|
| Alignment-based conformance | ✗ | Opt-in; wraps PM4Py via bridge.R; per-trace timeout |
| LSTM next-activity prediction | ✗ | Python only |
| Isolation forest anomaly detection | ✗ | Python only |
| ADWIN concept drift detection | ✗ | Python only |

---

## Python package (`python/processmine_ml/`)

### Schema & I/O (Milestone 1)

| Capability | File | Status | Notes |
|---|---|---|---|
| `validate_eventlog()` | `io.py` | ✓ | Mirrors R validator |
| `read_xes()` | `io.py` | ✓ | stdlib ElementTree parser |
| `write_eventlog_parquet()` | `io.py` | ✓ | JSON-encoded attrs |
| `read_eventlog_parquet()` | `io.py` | ✓ | Version guard |

### ML (Milestone 3)

| Capability | File | Status | Notes |
|---|---|---|---|
| `extract_case_features()` | `anomaly.py` | ✓ | Throughput, event count, activity/resource diversity, resource entropy |
| `detect_anomalies()` | `anomaly.py` | ✓ | Isolation Forest; configurable contamination, feature subset, random state |
| `extract_case_stream()` | `drift.py` | ✓ | Time-ordered per-case metric stream |
| `detect_drift()` | `drift.py` | ✓ | ADWIN on throughput, event count, activity frequency |
| `NextActivityPredictor` | `prediction.py` | ✓ | LSTM; fit/predict/evaluate; optional dep `pip install processmine-ml[ml]` |

---

## CI

| Job | Status |
|---|---|
| `test-r` (R CMD check) | ✓ passing |
| `test-python` (ruff + mypy + pytest) | ✓ passing |
| `roundtrip` | ✓ passing |

---

## Sample data

| File | Description | Status |
|---|---|---|
| `data/sample_logs/bpi2012_sample.xes` | Synthetic order-to-cash, 15 cases | ✓ |
