# Bridge tests require reticulate + processmine_ml to be importable.
# In CI these run only in the roundtrip job where both are installed.
skip_if_not_installed("reticulate")
skip_if_not(
  reticulate::py_module_available("processmine_ml"),
  "processmine_ml not importable; skipping bridge tests"
)

has_torch <- reticulate::py_module_available("torch")

make_bridge_log <- function() {
  # 12 cases: A -> B -> C repeated, 2 events minimum so LSTM can train
  base <- as.POSIXct("2024-01-01 08:00:00", tz = "UTC")
  rows <- do.call(rbind, lapply(1:12, function(i) {
    data.frame(
      case_id   = paste0("C", sprintf("%02d", i)),
      activity  = c("A", "B", "C"),
      timestamp = base + c(0, 3600, 7200) + (i - 1) * 86400,
      resource  = c("alice", "bob", "carol"),
      stringsAsFactors = FALSE
    )
  }))
  tibble::as_tibble(rows)
}

log <- make_bridge_log()

# ---- bridge_anomalies -------------------------------------------------------

test_that("bridge_anomalies returns expected columns", {
  result <- bridge_anomalies(log, contamination = 0.1)

  expect_s3_class(result, "data.frame")
  expect_true("case_id"       %in% names(result))
  expect_true("anomaly_score" %in% names(result))
  expect_true("is_anomaly"    %in% names(result))
})

test_that("bridge_anomalies returns one row per case", {
  result <- bridge_anomalies(log, contamination = 0.1)
  expect_equal(nrow(result), length(unique(log$case_id)))
})

test_that("bridge_anomalies contamination controls flag count", {
  r10 <- bridge_anomalies(log, contamination = 0.10)
  r20 <- bridge_anomalies(log, contamination = 0.20)
  expect_lte(sum(r10$is_anomaly), sum(r20$is_anomaly) + 1L)
})

# ---- bridge_drift -----------------------------------------------------------

test_that("bridge_drift returns expected columns", {
  result <- bridge_drift(log, metric = "throughput")

  expect_s3_class(result, "data.frame")
  expect_true("case_id"        %in% names(result))
  expect_true("drift_detected" %in% names(result))
  expect_true("throughput"     %in% names(result))
})

test_that("bridge_drift returns one row per case", {
  result <- bridge_drift(log)
  expect_equal(nrow(result), length(unique(log$case_id)))
})

test_that("bridge_drift accepts activity metric", {
  result <- bridge_drift(log, metric = "activity:A")
  expect_true("activity:A" %in% names(result))
})

# ---- bridge_fit_predictor / bridge_predict / bridge_evaluate ----------------

if (has_torch) {
  test_that("bridge_fit_predictor returns processmine_predictor", {
    p <- bridge_fit_predictor(log, epochs = 3L, hidden_size = 8L,
                              num_layers = 1L, embedding_dim = 4L)
    expect_s3_class(p, "processmine_predictor")
  })

  test_that("bridge_predict returns activity and probability columns", {
    p      <- bridge_fit_predictor(log, epochs = 3L, hidden_size = 8L,
                                   num_layers = 1L, embedding_dim = 4L)
    result <- bridge_predict(p, c("A"), top_k = 3L)

    expect_s3_class(result, "data.frame")
    expect_named(result, c("activity", "probability"))
    expect_lte(nrow(result), 3L)
  })

  test_that("bridge_predict probabilities sum to ~1", {
    p      <- bridge_fit_predictor(log, epochs = 3L, hidden_size = 8L,
                                   num_layers = 1L, embedding_dim = 4L,
                                   random_state = 7L)
    result <- bridge_predict(p, c("A", "B"),
                             top_k = length(unique(log$activity)))
    expect_equal(sum(result$probability), 1.0, tolerance = 1e-4)
  })

  test_that("bridge_evaluate returns accuracy metrics", {
    p      <- bridge_fit_predictor(log, epochs = 3L, hidden_size = 8L,
                                   num_layers = 1L, embedding_dim = 4L)
    result <- bridge_evaluate(p, log)

    expect_named(result, c("top1_accuracy", "top3_accuracy", "n_prefixes"),
                 ignore.order = TRUE)
    expect_gte(result$top1_accuracy, 0.0)
    expect_lte(result$top1_accuracy, 1.0)
  })

  test_that("bridge_predict rejects wrong predictor type", {
    expect_error(bridge_predict(list(), c("A")), "processmine_predictor")
  })
} else {
  message("Skipping prediction bridge tests: PyTorch not available")
}
