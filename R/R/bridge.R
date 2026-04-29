#' @importFrom rlang abort
#' @importFrom tibble as_tibble
NULL

# ---- internal helpers -------------------------------------------------------

.bridge_env <- new.env(parent = emptyenv())

.require_reticulate <- function() {
  if (!requireNamespace("reticulate", quietly = TRUE)) {
    rlang::abort(
      "reticulate is required for bridge functions. ",
      "Install with: install.packages('reticulate')"
    )
  }
}

# Memoised module import — avoids re-importing on every call.
.ml <- function() {
  .require_reticulate()
  if (!exists("mod", envir = .bridge_env)) {
    tryCatch(
      assign("mod", reticulate::import("processmine_ml"), envir = .bridge_env),
      error = function(e) rlang::abort(paste0(
        "Could not import processmine_ml. Is it installed?\n",
        "  pip install -e './python[ml]'"
      ))
    )
  }
  .bridge_env$mod
}

# Write log to a temp Parquet, return the Python DataFrame.
# The Parquet round-trip guarantees correct timestamp encoding.
.log_to_py <- function(log) {
  tmp <- tempfile(fileext = ".parquet")
  write_eventlog_parquet(log, tmp)
  on.exit(unlink(tmp), add = TRUE)
  .ml()$read_eventlog_parquet(tmp)
}

# Convert a Python pandas DataFrame to an R tibble.
.py_to_tbl <- function(py_df) {
  tibble::as_tibble(reticulate::py_to_r(py_df))
}

# ---- bridge_anomalies -------------------------------------------------------

#' Detect anomalous cases using the Python Isolation Forest.
#'
#' Calls [processmine_ml.detect_anomalies][python] on the event log via
#' reticulate. Requires the Python `processmine_ml[ml]` extras.
#'
#' @param log A validated processmine tibble.
#' @param contamination Expected fraction of anomalies. Default `0.05`.
#' @param random_state Integer seed for reproducibility. Default `42`.
#' @return A tibble with columns `case_id`, feature columns,
#'   `anomaly_score`, and `is_anomaly`.
#' @export
bridge_anomalies <- function(log, contamination = 0.05, random_state = 42L) {
  validate_eventlog(log)
  py_df  <- .log_to_py(log)
  result <- .ml()$detect_anomalies(
    py_df,
    contamination = contamination,
    random_state  = as.integer(random_state)
  )
  .py_to_tbl(result)
}

# ---- bridge_drift -----------------------------------------------------------

#' Detect concept drift in a process metric stream using ADWIN.
#'
#' Calls [processmine_ml.detect_drift][python] via reticulate.
#'
#' Supported metrics: `"throughput"`, `"n_events"`, `"n_unique_activities"`,
#' `"activity:<name>"` (binary presence stream).
#'
#' @param log A validated processmine tibble.
#' @param metric Metric to monitor. Default `"throughput"`.
#' @param delta ADWIN sensitivity. Smaller = fewer false positives but slower
#'   detection. Default `0.002`.
#' @return A tibble with columns `case_id`, `case_start`, the metric column,
#'   and `drift_detected`.
#' @export
bridge_drift <- function(log, metric = "throughput", delta = 0.002) {
  validate_eventlog(log)
  py_df  <- .log_to_py(log)
  result <- .ml()$detect_drift(py_df, metric = metric, delta = delta)
  .py_to_tbl(result)
}

# ---- bridge_fit_predictor ---------------------------------------------------

#' Fit an LSTM next-activity predictor on an event log.
#'
#' Calls [processmine_ml.NextActivityPredictor.fit][python] via reticulate.
#' Returns a `processmine_predictor` object that can be passed to
#' [bridge_predict()] and [bridge_evaluate()].
#'
#' Requires `processmine_ml[ml]` (PyTorch).
#'
#' @param log A validated processmine tibble.
#' @param epochs Number of training epochs. Default `20`.
#' @param hidden_size LSTM hidden dimension. Default `64`.
#' @param num_layers Number of LSTM layers. Default `2`.
#' @param embedding_dim Activity embedding dimension. Default `32`.
#' @param lr Adam learning rate. Default `0.001`.
#' @param batch_size Mini-batch size. Default `64`.
#' @param random_state Integer seed. Default `42`.
#' @return A `processmine_predictor` object.
#' @export
bridge_fit_predictor <- function(
    log,
    epochs        = 20L,
    hidden_size   = 64L,
    num_layers    = 2L,
    embedding_dim = 32L,
    lr            = 0.001,
    batch_size    = 64L,
    random_state  = 42L
) {
  validate_eventlog(log)
  py_df <- .log_to_py(log)
  py_p  <- .ml()$NextActivityPredictor()
  py_p$fit(
    py_df,
    epochs        = as.integer(epochs),
    hidden_size   = as.integer(hidden_size),
    num_layers    = as.integer(num_layers),
    embedding_dim = as.integer(embedding_dim),
    lr            = lr,
    batch_size    = as.integer(batch_size),
    random_state  = as.integer(random_state)
  )
  structure(list(.py = py_p), class = "processmine_predictor")
}

# ---- bridge_predict ---------------------------------------------------------

#' Predict the next activity given a prefix.
#'
#' @param predictor A `processmine_predictor` returned by [bridge_fit_predictor()].
#' @param prefix Character vector of activity names (the case prefix so far).
#' @param top_k Number of top predictions to return. Default `5`.
#' @return A tibble with columns `activity` and `probability`.
#' @export
bridge_predict <- function(predictor, prefix, top_k = 5L) {
  if (!inherits(predictor, "processmine_predictor")) {
    rlang::abort("predictor must be a processmine_predictor from bridge_fit_predictor().")
  }
  result <- predictor$.py$predict(as.list(prefix), top_k = as.integer(top_k))
  .py_to_tbl(result)
}

# ---- bridge_evaluate --------------------------------------------------------

#' Evaluate next-activity prediction accuracy on an event log.
#'
#' @param predictor A `processmine_predictor` returned by [bridge_fit_predictor()].
#' @param log A validated processmine tibble.
#' @return A named list with `top1_accuracy`, `top3_accuracy`, `n_prefixes`.
#' @export
bridge_evaluate <- function(predictor, log) {
  if (!inherits(predictor, "processmine_predictor")) {
    rlang::abort("predictor must be a processmine_predictor from bridge_fit_predictor().")
  }
  validate_eventlog(log)
  py_df  <- .log_to_py(log)
  result <- predictor$.py$evaluate(py_df)
  as.list(reticulate::py_to_r(result))
}

# ---- bridge_conformance_alignment -------------------------------------------

#' Compute alignment-based conformance via PM4Py (opt-in, slow).
#'
#' Alignments are more precise than token replay but significantly slower.
#' For logs with more than ~10k cases, use [conformance_tokenreplay()] instead.
#'
#' Requires `processmine_ml[pm4py]` Python extras:
#' `pip install 'processmine-ml[pm4py]'`
#'
#' @param log A validated processmine tibble.
#' @param timeout_per_trace Per-trace timeout in seconds. Default `30`.
#' @return A tibble with columns `case_id`, `fitness`, `cost`, `is_fitting`.
#' @export
bridge_conformance_alignment <- function(log, timeout_per_trace = 30L) {
  validate_eventlog(log)

  # Import the optional align sub-module (errors clearly if pm4py absent)
  align <- tryCatch(
    reticulate::import("processmine_ml.align"),
    error = function(e) rlang::abort(paste0(
      "Could not import processmine_ml.align. ",
      "Is PM4Py installed?\n  pip install 'processmine-ml[pm4py]'"
    ))
  )

  py_df  <- .log_to_py(log)
  result <- align$conformance_alignments(
    py_df,
    timeout_per_trace = as.integer(timeout_per_trace)
  )
  .py_to_tbl(result)
}
