# Processmine — User Guide

This guide walks through every capability in processmine, from installation to a complete end-to-end analysis. Use the table of contents to jump to the section you need.

---

## Table of contents

1. [Installation](#1-installation)
2. [Data ingestion](#2-data-ingestion)
   - [From CSV](#21-from-csv)
   - [From XES](#22-from-xes)
   - [From Parquet](#23-from-parquet)
   - [Saving to Parquet](#24-saving-to-parquet)
3. [Process discovery](#3-process-discovery)
4. [Conformance checking](#4-conformance-checking)
5. [Performance analysis](#5-performance-analysis)
6. [Variant analysis](#6-variant-analysis)
7. [Train/test splitting](#7-traintest-splitting)
8. [Python ML — anomaly detection](#8-python-ml--anomaly-detection)
9. [Python ML — concept drift](#9-python-ml--concept-drift)
10. [Python ML — next-activity prediction](#10-python-ml--next-activity-prediction)
11. [R → Python bridge](#11-r--python-bridge)
12. [End-to-end example](#12-end-to-end-example)
13. [Schema reference](#13-schema-reference)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Installation

### R package

**From a local clone:**
```r
devtools::install("path/to/processmine/R")
```

**From GitHub:**
```r
remotes::install_github("NZDaveyboy/processmine", subdir = "R")
```

**Dependencies installed automatically:** `arrow`, `jsonlite`, `xml2`, `tibble`, `rlang`

**To use the Python bridge** (section 11), also install `reticulate`:
```r
install.packages("reticulate")
```

### Python package

Clone the repo, then:

```bash
# Core package (anomaly detection + drift)
pip install -e "./python"

# Add LSTM prediction
pip install -e "./python[ml]"

# Add PM4Py alignment conformance
pip install -e "./python[pm4py]"

# Everything
pip install -e "./python[ml,pm4py]"
```

**Requires Python 3.11+.**

### Verify the install

```r
# R
library(processmine)
log <- read_xes("data/sample_logs/bpi2012_sample.xes")
print(nrow(log))   # should be > 0
```

```python
# Python
from processmine_ml import read_xes
log = read_xes("data/sample_logs/bpi2012_sample.xes")
print(len(log))    # should be > 0
```

---

## 2. Data ingestion

All processmine functions consume a single canonical event-log DataFrame/tibble. The three required columns are `case_id`, `activity`, and `timestamp` (UTC). Everything else is optional.

### 2.1 From CSV

Most real-world data lives in CSV or a database export. Use `read_csv_eventlog()` to map your column names to the schema and handle timezone conversion automatically.

**R:**
```r
library(processmine)

# Simplest case — CSV already uses the canonical column names
log <- read_csv_eventlog("my_log.csv")

# Map custom column names
log <- read_csv_eventlog(
  "my_log.csv",
  case_col      = "CaseID",
  activity_col  = "EventName",
  timestamp_col = "StartTime"
)

# All options
log <- read_csv_eventlog(
  "my_log.csv",
  case_col            = "CaseID",
  activity_col        = "EventName",
  timestamp_col       = "CompletionTime",
  start_timestamp_col = "StartTime",    # event start time
  resource_col        = "AssignedUser",
  lifecycle_col       = "Status",
  case_attrs_cols     = c("Region", "Channel"),   # folded into case_attrs map
  event_attrs_cols    = c("Cost", "Priority"),    # folded into event_attrs map
  timestamp_format    = "%Y-%m-%d %H:%M:%S",      # strptime format; NULL = auto-detect
  tz                  = "America/New_York"         # source tz; converted to UTC
)
```

**Python:**
```python
from processmine_ml import read_csv_eventlog

# Simplest case
log = read_csv_eventlog("my_log.csv")

# Map custom column names
log = read_csv_eventlog(
    "my_log.csv",
    case_col="CaseID",
    activity_col="EventName",
    timestamp_col="StartTime",
)

# All options
log = read_csv_eventlog(
    "my_log.csv",
    case_col="CaseID",
    activity_col="EventName",
    timestamp_col="CompletionTime",
    start_timestamp_col="StartTime",
    resource_col="AssignedUser",
    lifecycle_col="Status",
    case_attrs_cols=["Region", "Channel"],
    event_attrs_cols=["Cost", "Priority"],
    timestamp_format="%Y-%m-%d %H:%M:%S",  # None = pandas auto-detect
    tz="America/New_York",
    sep=";",   # extra kwargs go to pandas.read_csv
)
```

**What happens to `case_attrs_cols` / `event_attrs_cols`?**
These columns are not removed — they are folded into a key-value map attached to each row. This keeps the top-level schema clean while preserving extra data for downstream use. Access them like:

```r
# R — each element is a named character vector
log$case_attrs[[1]]          # named vector for row 1
log$case_attrs[[1]]["Region"] # "NZ"
```

```python
# Python — each element is a dict
log["case_attrs"].iloc[0]          # {'Region': 'NZ', 'Channel': 'web'}
log["case_attrs"].iloc[0]["Region"] # 'NZ'
```

**Common timestamp formats:**

| Source system | Format string |
|---|---|
| ISO 8601 (default) | `NULL` / `None` (auto-detected) |
| `2024-01-15 08:30:00` | `"%Y-%m-%d %H:%M:%S"` |
| `15/01/2024 08:30` | `"%d/%m/%Y %H:%M"` |
| `01/15/2024 08:30 AM` | `"%m/%d/%Y %I:%M %p"` |
| Excel serial number | Requires pre-processing |

### 2.2 From XES

XES is the standard process mining exchange format exported by tools like Disco, ProM, and Celonis.

**R:**
```r
log <- read_xes("path/to/log.xes")
```

**Python:**
```python
from processmine_ml import read_xes
log = read_xes("path/to/log.xes")
```

Standard XES keys are mapped automatically:

| XES key | Schema column |
|---|---|
| `concept:name` (trace) | `case_id` |
| `concept:name` (event) | `activity` |
| `time:timestamp` | `timestamp` |
| `org:resource` | `resource` |
| `lifecycle:transition` | `lifecycle` |
| All other trace keys | `case_attrs` |
| All other event keys | `event_attrs` |

### 2.3 From Parquet

Parquet is the fastest format for repeated analysis. Read files written by either language:

```r
log <- read_eventlog_parquet("log.parquet")
```

```python
from processmine_ml import read_eventlog_parquet
log = read_eventlog_parquet("log.parquet")
```

The reader enforces the `schema_version` metadata guard — it will reject files not written by processmine, or files from a future incompatible major version.

### 2.4 Saving to Parquet

Always save after loading from CSV or XES — subsequent reads are ~10× faster:

```r
write_eventlog_parquet(log, "log.parquet")
```

```python
from processmine_ml import write_eventlog_parquet
write_eventlog_parquet(log, "log.parquet")
```

---

## 3. Process discovery

Discovery builds a model of your process from the event log. Start with the Directly-Follows Graph (DFG) for a quick overview, then use the Heuristics Miner for a cleaner model that filters noise.

### Directly-Follows Graph (DFG)

The DFG shows every activity transition that occurred, with counts and frequencies.

```r
library(processmine)

dfg <- discover_dfg(log)

# Inspect the model
dfg$edges            # tibble: from, to, n (count), freq (relative)
dfg$activities       # all activity names
dfg$start_activities # first activity of each case
dfg$end_activities   # last activity of each case

# Filter out rare edges (< 5% of cases)
dfg_filtered <- discover_dfg(log, noise_threshold = 0.05)
```

**Reading the edges:**
```r
head(dfg$edges)
# A tibble: 6 × 4
#   from             to               n  freq
#   <chr>            <chr>        <int> <dbl>
# 1 Approve Order    Pick Items      95 0.950
# 2 Close Order      NA               5 0.050
# 3 Create Order     Approve Order  100 1.000
```

### Heuristics miner

The Heuristics Miner filters edges based on a dependency score — only keeping transitions where A reliably leads to B (not just occasionally). Higher `dependency_threshold` = stricter filtering.

```r
# Default threshold 0.9 — keeps only strong dependencies
hnet <- discover_heuristics(log)

# More permissive — keeps weaker relationships
hnet <- discover_heuristics(log, dependency_threshold = 0.7)

# Inspect
hnet$edges            # same structure as DFG edges, plus dependency column
hnet$activities
hnet$start_activities
hnet$end_activities
```

**Choosing a threshold:**
- `0.9` — good default; removes most noise
- `0.7–0.8` — keeps more paths; useful when the process has genuine variation
- `0.5` — permissive; use only when you expect many valid paths

---

## 4. Conformance checking

Conformance checking measures how well the actual event log matches the discovered process model. This highlights cases that deviated from the expected flow.

```r
# Check conformance against the heuristics net
conf <- conformance_tokenreplay(log, hnet)

# Or against the DFG
conf <- conformance_tokenreplay(log, dfg)

# Summary statistics
conf$summary
# $fitness        0.94     # proportion of events that "fit" the model
# $n_cases        100
# $n_fitting      88       # cases with perfect fitness
# $n_deviating    12

# Per-case fitness (sorted worst first)
conf$per_case
# A tibble: 100 × 3
#   case_id  fitness  deviations
#   <chr>      <dbl>       <int>
# 1 C0042      0.333           4
# 2 C0017      0.500           2

# Detailed diagnostics (missing tokens, remaining tokens per case)
conf$diagnostics
```

**What fitness means:**
- `1.0` — the case followed the model exactly
- `< 1.0` — some activities were skipped, added, or out of order
- `0.0` — the case bears no resemblance to the model

**Typical workflow:**
```r
# Find the worst-performing cases
worst <- conf$per_case[order(conf$per_case$fitness), ]
head(worst, 10)

# Pull the actual event sequence for one of them
log[log$case_id == worst$case_id[1], c("activity", "timestamp")]
```

---

## 5. Performance analysis

Performance analysis measures how long things take — both at the case level and at individual transitions.

### Throughput time

How long does each case take from first to last event?

```r
throughput <- performance_throughput(log, unit = "hours")

# Returns a tibble with one row per case
# case_id   throughput
# C0001     4.2
# C0002     6.8

summary(throughput$throughput)
hist(throughput$throughput, main = "Case throughput (hours)")
```

`unit` options: `"secs"`, `"mins"`, `"hours"`, `"days"`.

### Bottleneck detection

Which transitions take the longest on average?

```r
bottlenecks <- performance_bottlenecks(log)

# Returns a tibble sorted by mean duration descending
# from              to            mean_duration_s   n
# Approve Order     Pick Items         14400        95
# Create Order      Approve Order       3600       100

head(bottlenecks, 5)  # top 5 slowest transitions
```

### SLA compliance

How many cases breached a time limit?

```r
# Check whether cases completed within 48 hours
sla <- performance_sla(log, list(limit = 48, unit = "hours"))

sla$summary
# $n_cases           100
# $n_compliant        82
# $compliance_rate  0.82
# $sla_limit_hours    48

# Per-case result
sla$per_case
# A tibble: 100 × 3
#   case_id  throughput_hours  sla_met
#   <chr>               <dbl>  <lgl>
# 1 C0001                4.2   TRUE
# 2 C0042               72.1   FALSE

# Cases that breached the SLA
breaches <- sla$per_case[!sla$per_case$sla_met, ]
```

---

## 6. Variant analysis

A variant is a unique sequence of activities. Variant analysis tells you how many distinct paths exist and which ones are rare.

```r
# All variants, sorted by frequency (most common first)
v <- variants(log)

# A tibble: 8 × 3
#   variant                                          n  freq
#   <chr>                                        <int> <dbl>
# 1 Create Order→Approve Order→Pick Items→...       80  0.80
# 2 Create Order→Credit Check→Approve Order→...     15  0.15
# 3 Create Order→Reject Order                        5  0.05

# How many distinct paths?
nrow(v)

# Rare variants (appear in < 5% of cases)
rare <- rare_paths(log, min_support = 0.05)
# Same structure as variants(), filtered to freq < min_support
```

**Common use cases:**
- `nrow(variants(log)) == 1` — highly standardised process
- Long tail of rare variants — investigate for compliance issues or ad-hoc workarounds
- Compare variants before and after a process change to measure impact

---

## 7. Train/test splitting

Before training the LSTM predictor (section 10), split by case — never by row. Splitting by row leaks future events into the training set.

**R:**
```r
splits <- train_test_split_by_case(log, test_size = 0.2, random_state = 42)
train  <- splits$train
test   <- splits$test

cat("Train cases:", length(unique(train$case_id)), "\n")
cat("Test cases: ", length(unique(test$case_id)),  "\n")
```

**Python:**
```python
from processmine_ml import train_test_split_by_case

train, test = train_test_split_by_case(log, test_size=0.2, random_state=42)

print("Train cases:", train["case_id"].nunique())
print("Test cases: ", test["case_id"].nunique())
```

`random_state` ensures the same split every run — important for reproducible evaluation.

---

## 8. Python ML — anomaly detection

Anomaly detection flags cases that look unusual compared to the rest of the log. It uses an Isolation Forest trained on five numeric features extracted per case.

```python
from processmine_ml import (
    read_csv_eventlog, extract_case_features, detect_anomalies
)

log = read_csv_eventlog("my_log.csv")

# Step 1 — inspect the features
features = extract_case_features(log)
print(features.describe())
#              throughput_s  n_events  n_unique_activities  n_unique_resources  resource_entropy
# count           100.0       100.0            100.0               100.0               100.0
# mean          14400.0         5.0              4.0                 3.0               1.58
# ...

# Step 2 — detect anomalies
anomalies = detect_anomalies(log, contamination=0.05, random_state=42)

# Returns one row per case, sorted by anomaly_score ascending (most anomalous first)
flagged = anomalies[anomalies["is_anomaly"]]
print(f"Flagged: {len(flagged)} of {len(anomalies)} cases")
print(flagged[["case_id", "throughput_s", "n_events", "anomaly_score"]])
```

**Parameters:**

| Parameter | Default | Meaning |
|---|---|---|
| `contamination` | `0.05` | Expected proportion of anomalies (0–0.5). Higher = more cases flagged. |
| `random_state` | `42` | Random seed for reproducibility. |
| `features` | `None` | List of feature names to use. `None` = all five features. |

**The five features:**

| Feature | Description |
|---|---|
| `throughput_s` | Case duration in seconds |
| `n_events` | Number of events in the case |
| `n_unique_activities` | Number of distinct activity types |
| `n_unique_resources` | Number of distinct resources |
| `resource_entropy` | Shannon entropy of resource distribution |

**Tuning `contamination`:**
- Start with `0.05` (5%)
- If flagged cases look normal, lower it to `0.02`
- If you miss obvious outliers, raise it to `0.10`

---

## 9. Python ML — concept drift

Concept drift detection monitors whether the process is changing over time — e.g., throughput increasing, activities disappearing, or resource patterns shifting. Uses the ADWIN (Adaptive Windowing) algorithm, which splits an adaptive window into two sub-windows and signals when their means diverge significantly.

```python
from processmine_ml import detect_drift

# Monitor throughput over time
drift = detect_drift(log, metric="throughput", delta=0.002)

# Returns one row per case in chronological order
change_points = drift[drift["drift_detected"]]
print(f"Change points: {len(change_points)}")
print(change_points[["case_id", "case_start", "throughput"]])
```

**Available metrics:**

| Metric | Description |
|---|---|
| `"throughput"` | Case duration in seconds |
| `"n_events"` | Number of events per case |
| `"n_unique_activities"` | Distinct activities per case |
| `"activity:<name>"` | Binary stream: 1 if `<name>` appeared in the case, 0 otherwise |

```python
# Monitor whether "Credit Check" is disappearing from cases
drift = detect_drift(log, metric="activity:Credit Check", delta=0.002)
```

**The `delta` parameter:**
Controls sensitivity. Smaller = more sensitive (more false alarms); larger = less sensitive (may miss slow drift).
- `0.002` — default; good for most logs
- `0.0002` — very sensitive; use when change points should be caught early
- `0.02` — insensitive; use when the signal is noisy

---

## 10. Python ML — next-activity prediction

`NextActivityPredictor` trains a two-layer LSTM that learns to predict what activity comes next given a prefix of activities seen so far.

### Train

```python
from processmine_ml import NextActivityPredictor, train_test_split_by_case, read_csv_eventlog

log   = read_csv_eventlog("my_log.csv")
train, test = train_test_split_by_case(log, test_size=0.2, random_state=42)

predictor = NextActivityPredictor()
predictor.fit(
    train,
    epochs        = 25,
    hidden_size   = 64,
    num_layers    = 2,
    embedding_dim = 32,
    lr            = 0.001,
    batch_size    = 64,
    random_state  = 42,
)
print("Training complete.")
```

**Key hyperparameters:**

| Parameter | Default | When to change |
|---|---|---|
| `epochs` | — | More epochs = better fit, but slower. Try 25–100. |
| `hidden_size` | — | LSTM hidden units. 32 for simple logs; 128 for complex. |
| `num_layers` | — | LSTM depth. 2 is usually sufficient. |
| `embedding_dim` | — | Activity embedding size. Match to vocabulary size. |
| `lr` | `0.001` | Reduce if training loss oscillates. |
| `batch_size` | `64` | Reduce if you get memory errors. |

### Predict

```python
# Top-3 most likely next activities given a prefix
preds = predictor.predict(["Create Order", "Approve Order"], top_k=3)
print(preds)
#            activity  probability
# 0        Pick Items        0.892
# 1      Reject Order        0.065
# 2   Credit Check          0.043
```

### Evaluate

```python
metrics = predictor.evaluate(test)
print(f"Top-1 accuracy: {metrics['top1_accuracy']:.1%}")
print(f"Top-3 accuracy: {metrics['top3_accuracy']:.1%}")
print(f"Prefixes scored: {int(metrics['n_prefixes'])}")
```

`top1_accuracy` — the correct next activity was the single top prediction.  
`top3_accuracy` — the correct next activity appeared in the top 3.

### Save and load

```python
# Save trained model
predictor.save("predictor.pt")

# Load in a later session
from processmine_ml import NextActivityPredictor
predictor = NextActivityPredictor.load("predictor.pt")

# Ready to predict immediately — no retraining needed
predictor.predict(["Create Order"], top_k=3)
```

---

## 11. R → Python bridge

The bridge lets you call the Python ML layer directly from R without switching languages. It uses `reticulate` under the hood and handles all data conversion via Parquet.

**Prerequisites:**
```r
install.packages("reticulate")
# and have the Python package installed:
# pip install -e "./python[ml,pm4py]"
```

### Anomaly detection from R

```r
library(processmine)

log       <- read_xes("my_log.xes")
anomalies <- bridge_anomalies(log, contamination = 0.05)

# anomalies is a regular R tibble
flagged <- anomalies[anomalies$is_anomaly, ]
```

### Drift detection from R

```r
drift <- bridge_drift(log, metric = "throughput", delta = 0.002)
change_pts <- drift[drift$drift_detected, ]
```

### LSTM prediction from R

```r
# Split, train, predict, evaluate — all from R
splits    <- train_test_split_by_case(log, test_size = 0.2)
predictor <- bridge_fit_predictor(splits$train, epochs = 25)

preds   <- bridge_predict(predictor, c("Create Order", "Approve Order"))
metrics <- bridge_evaluate(predictor, splits$test)

cat("Top-1 accuracy:", metrics$top1_accuracy, "\n")
```

### Alignment-based conformance from R

Alignment conformance is more accurate than token replay but computationally expensive. It uses PM4Py under the hood and requires `pip install -e "./python[pm4py]"`.

```r
alignment <- bridge_conformance_alignment(log)

# Per-case fitness and alignment cost
head(alignment)
# A tibble: 5 × 4
#   case_id   fitness  cost  is_fitting
#   <chr>       <dbl> <dbl>  <lgl>
# 1 C0001       1.000     0  TRUE
# 2 C0042       0.667     2  FALSE
```

---

## 12. End-to-end example

A complete analysis from raw CSV to trained predictor.

### R side

```r
library(processmine)

# 1. Load
log <- read_csv_eventlog(
  "order_management.csv",
  case_col      = "OrderID",
  activity_col  = "Step",
  timestamp_col = "CompletedAt",
  resource_col  = "Agent",
  tz            = "Europe/Amsterdam"
)

# 2. Discover
hnet <- discover_heuristics(log, dependency_threshold = 0.9)

# 3. Conformance
conf <- conformance_tokenreplay(log, hnet)
cat("Overall fitness:", conf$summary$fitness, "\n")

# 4. Performance
bottlenecks <- performance_bottlenecks(log)
sla         <- performance_sla(log, list(limit = 24, unit = "hours"))
cat("SLA compliance:", sla$summary$compliance_rate, "\n")

# 5. Variants
v <- variants(log)
cat("Distinct paths:", nrow(v), "\n")
cat("Top variant covers", round(v$freq[1] * 100), "% of cases\n")

# 6. Save for Python
write_eventlog_parquet(log, "order_log.parquet")
```

### Python side

```python
from processmine_ml import (
    read_eventlog_parquet, detect_anomalies, detect_drift,
    NextActivityPredictor, train_test_split_by_case,
)

# 1. Load the Parquet written by R (or read CSV directly)
log = read_eventlog_parquet("order_log.parquet")

# 2. Anomaly detection
anomalies = detect_anomalies(log, contamination=0.05)
print(f"Anomalous cases: {anomalies['is_anomaly'].sum()}")

# 3. Drift detection
drift = detect_drift(log, metric="throughput")
print(f"Drift change points: {drift['drift_detected'].sum()}")

# 4. Prediction
train, test = train_test_split_by_case(log, test_size=0.2, random_state=42)

predictor = NextActivityPredictor()
predictor.fit(train, epochs=30, hidden_size=64, num_layers=2)

metrics = predictor.evaluate(test)
print(f"Top-1 accuracy: {metrics['top1_accuracy']:.1%}")

# Predict the next step for an in-flight case
predictor.predict(["Receive Order", "Validate Order", "Approve Order"], top_k=3)

# Save the trained model
predictor.save("order_predictor.pt")
```

---

## 13. Schema reference

All processmine functions consume and produce a single canonical table.

| Column | Type | Required | Description |
|---|---|---|---|
| `case_id` | string | yes | Unique identifier for a process instance (order, ticket, patient) |
| `activity` | string | yes | Name of the step that occurred |
| `timestamp` | timestamp[us, UTC] | yes | When the step completed |
| `start_timestamp` | timestamp[us, UTC] | no | When the step started (enables duration analysis) |
| `resource` | string | no | Who or what performed the step |
| `lifecycle` | string | no | `start`, `complete`, `schedule`, `withdraw`, `suspend`, `resume` |
| `case_attrs` | map / dict | no | Arbitrary case-level key-value pairs |
| `event_attrs` | map / dict | no | Arbitrary event-level key-value pairs |

**Invariants:**
- All timestamps are UTC. Local times are converted on ingestion.
- `timestamp >= start_timestamp` wherever both are present.
- No nulls in `case_id`, `activity`, or `timestamp`.
- Events within a case are ordered by `timestamp` ascending.
- Parquet files carry `schema_version = "1.0"` metadata.

**Calling `validate_eventlog()` directly:**
```r
validate_eventlog(my_df)   # returns log invisibly on success; aborts on failure
```
```python
validate_eventlog(my_df)   # returns df on success; raises ValueError on failure
```

---

## 14. Troubleshooting

### "Missing required column(s): case_id"
Your CSV does not have a column called `case_id`. Pass the correct name:
```r
read_csv_eventlog("log.csv", case_col = "OrderID")
```

### "Column 'timestamp' must have tz = UTC"
Your timestamps were loaded without a timezone. Either set `tz` in `read_csv_eventlog()`, or fix manually:
```r
log$timestamp <- as.POSIXct(log$timestamp, tz = "UTC")
```
```python
log["timestamp"] = pd.to_datetime(log["timestamp"], utc=True).dt.as_unit("us")
```

### "start_timestamp must be <= timestamp"
Some rows have a start time after the completion time. Common cause: date parsing failure (e.g. wrong `timestamp_format`). Check:
```r
bad <- log[log$start_timestamp > log$timestamp, ]
```

### Timestamps parsed as NA / NaT
Your `timestamp_format` doesn't match the actual format in the CSV. Inspect a few rows:
```r
head(read.csv("log.csv")$timestamp)
# "15/01/2024 08:30" → use timestamp_format = "%d/%m/%Y %H:%M"
```

### Bridge fails with "ModuleNotFoundError"
The Python package is not installed in the Python environment reticulate is using:
```r
reticulate::py_config()    # shows which Python reticulate found
# then install into that environment:
reticulate::py_install("processmine-ml", pip = TRUE)
```

### LSTM training is slow
- Reduce `hidden_size` (try 32 instead of 64)
- Reduce `num_layers` to 1
- Reduce `epochs` (25 is usually sufficient)
- If on a Mac with Apple Silicon, PyTorch uses MPS automatically if available

### R CMD check warning about undocumented functions
Run `roxygen2::roxygenise("R")` to regenerate documentation before checking.

### `make roundtrip` fails
Ensure both the R package and Python package are installed in the same environment, and that `RETICULATE_PYTHON` points to the correct Python binary:
```bash
export RETICULATE_PYTHON=$(which python3)
make roundtrip
```
