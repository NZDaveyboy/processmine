make_perf_log <- function() {
  base <- as.POSIXct("2024-01-01 08:00:00", tz = "UTC")
  tibble::as_tibble(data.frame(
    case_id   = c("C1","C1","C1","C2","C2","C2"),
    activity  = c("A","B","C","A","B","C"),
    timestamp = base + c(0, 3600, 7200,   0, 1800, 3600),
    stringsAsFactors = FALSE
  ))
}

# ---- performance_throughput --------------------------------------------------

test_that("performance_throughput returns correct hours", {
  log <- make_perf_log()
  tp  <- performance_throughput(log, unit = "hours")

  expect_s3_class(tp, "data.frame")
  expect_named(tp, c("case_id", "throughput", "unit"))
  expect_equal(nrow(tp), 2L)

  c1 <- tp[tp$case_id == "C1", ]$throughput
  expect_equal(c1, 2.0, tolerance = 1e-6)  # 7200s = 2h

  c2 <- tp[tp$case_id == "C2", ]$throughput
  expect_equal(c2, 1.0, tolerance = 1e-6)  # 3600s = 1h
})

test_that("performance_throughput respects unit argument", {
  log <- make_perf_log()
  tp  <- performance_throughput(log, unit = "minutes")

  c1 <- tp[tp$case_id == "C1", ]$throughput
  expect_equal(c1, 120.0, tolerance = 1e-6)  # 7200s = 120min
  expect_equal(tp$unit[1], "minutes")
})

test_that("performance_throughput rejects unknown unit", {
  log <- make_perf_log()
  expect_error(performance_throughput(log, unit = "fortnights"), "Unknown unit")
})

# ---- performance_bottlenecks ------------------------------------------------

test_that("performance_bottlenecks returns edge-level mean durations", {
  log <- make_perf_log()
  bn  <- performance_bottlenecks(log)

  expect_s3_class(bn, "data.frame")
  expect_named(bn, c("from_activity", "to_activity", "mean_duration_s", "n"))

  ab <- bn[bn$from_activity == "A" & bn$to_activity == "B", ]
  expect_equal(nrow(ab), 1L)
  # C1: A->B = 3600s; C2: A->B = 1800s → mean = 2700s
  expect_equal(ab$mean_duration_s, 2700, tolerance = 1e-6)
  expect_equal(ab$n, 2L)
})

test_that("performance_bottlenecks rejects unknown method", {
  log <- make_perf_log()
  expect_error(performance_bottlenecks(log, method = "telekinesis"), "method")
})

test_that("performance_bottlenecks returns sorted by descending duration", {
  log <- make_perf_log()
  bn  <- performance_bottlenecks(log)

  expect_true(all(diff(bn$mean_duration_s) <= 0))
})

# ---- performance_sla ---------------------------------------------------------

test_that("performance_sla flags cases correctly", {
  log <- make_perf_log()
  # C1 throughput = 2h, C2 = 1h; SLA limit = 1.5h
  sla <- performance_sla(log, sla_spec = list(limit = 1.5, unit = "hours"))

  expect_s3_class(sla, "data.frame")
  expect_named(sla, c("case_id", "throughput", "unit", "within_sla", "sla_limit"))

  c1_ok <- sla[sla$case_id == "C1", ]$within_sla
  c2_ok <- sla[sla$case_id == "C2", ]$within_sla
  expect_false(c1_ok)
  expect_true(c2_ok)
})

test_that("performance_sla uses hours as default unit", {
  log <- make_perf_log()
  sla <- performance_sla(log, sla_spec = list(limit = 3))
  expect_equal(sla$unit[1], "hours")
})

test_that("performance_sla rejects missing limit", {
  log <- make_perf_log()
  expect_error(performance_sla(log, sla_spec = list(unit = "hours")), "limit")
})

test_that("performance_sla rejects non-list sla_spec", {
  log <- make_perf_log()
  expect_error(performance_sla(log, sla_spec = 1.5), "sla_spec")
})
