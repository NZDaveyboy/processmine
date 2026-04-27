test_that("discover_dfg returns correct edge counts", {
  # C1-C9: A -> B -> C; C10: A -> C
  base <- as.POSIXct("2024-01-01 08:00:00", tz = "UTC")
  rows <- do.call(rbind, lapply(1:9, function(i) {
    data.frame(
      case_id   = paste0("C", i),
      activity  = c("A", "B", "C"),
      timestamp = base + c(0, 100, 200) + (i - 1) * 1000,
      stringsAsFactors = FALSE
    )
  }))
  rows <- rbind(rows, data.frame(
    case_id   = "C10",
    activity  = c("A", "C"),
    timestamp = base + c(0, 100) + 9000,
    stringsAsFactors = FALSE
  ))
  log <- tibble::as_tibble(rows)

  dfg <- discover_dfg(log)

  expect_s3_class(dfg, "processmine_dfg")
  expect_true(is.data.frame(dfg$edges))
  expect_named(dfg$edges, c("from", "to", "n", "freq"))

  ab <- dfg$edges[dfg$edges$from == "A" & dfg$edges$to == "B", ]
  expect_equal(ab$n, 9L)

  bc <- dfg$edges[dfg$edges$from == "B" & dfg$edges$to == "C", ]
  expect_equal(bc$n, 9L)

  ac <- dfg$edges[dfg$edges$from == "A" & dfg$edges$to == "C", ]
  expect_equal(ac$n, 1L)
})

test_that("discover_dfg captures start and end activities", {
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  log  <- tibble::tibble(
    case_id   = c("C1", "C1", "C2", "C2"),
    activity  = c("A", "B", "A", "B"),
    timestamp = base + c(0, 100, 500, 600)
  )
  dfg <- discover_dfg(log)

  expect_equal(dfg$start_activities, "A")
  expect_equal(dfg$end_activities,   "B")
  expect_equal(sort(dfg$activities), c("A", "B"))
})

test_that("discover_dfg noise_threshold filters low-frequency edges", {
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  rows <- do.call(rbind, lapply(1:9, function(i) {
    data.frame(case_id = paste0("C", i),
               activity  = c("A", "B", "C"),
               timestamp = base + c(0, 100, 200) + (i - 1) * 1000,
               stringsAsFactors = FALSE)
  }))
  rows <- rbind(rows, data.frame(
    case_id = "C10", activity = c("A", "C"),
    timestamp = base + c(0, 100) + 9000, stringsAsFactors = FALSE
  ))
  log <- tibble::as_tibble(rows)

  dfg <- discover_dfg(log, noise_threshold = 0.1)

  # A->C appears once / 29 events ≈ 0.034 — below threshold
  ac_edges <- dfg$edges[dfg$edges$from == "A" & dfg$edges$to == "C", ]
  expect_equal(nrow(ac_edges), 0L)
})

test_that("discover_dfg handles single-event cases gracefully", {
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  log  <- tibble::tibble(
    case_id   = c("C1", "C2"),
    activity  = c("A", "A"),
    timestamp = base + c(0, 100)
  )
  dfg <- discover_dfg(log)

  expect_equal(nrow(dfg$edges), 0L)
  expect_equal(dfg$activities, "A")
})

test_that("discover_heuristics filters by dependency threshold", {
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  rows <- do.call(rbind, lapply(1:9, function(i) {
    data.frame(case_id = paste0("C", i), activity = c("A", "B", "C"),
               timestamp = base + c(0, 100, 200) + (i - 1) * 1000,
               stringsAsFactors = FALSE)
  }))
  rows <- rbind(rows, data.frame(
    case_id = "C10", activity = c("A", "C"),
    timestamp = base + c(0, 100) + 9000, stringsAsFactors = FALSE
  ))
  log  <- tibble::as_tibble(rows)
  hnet <- discover_heuristics(log, dependency_threshold = 0.9)

  expect_s3_class(hnet, "processmine_hnet")
  expect_true("dependency" %in% names(hnet$edges))

  # A->B and B->C: dep = (9 - 0) / (9 + 0 + 1) = 0.9 — retained
  ab <- hnet$edges[hnet$edges$from == "A" & hnet$edges$to == "B", ]
  expect_equal(nrow(ab), 1L)
  expect_equal(ab$dependency, 0.9)

  # A->C: dep = (1 - 0) / (1 + 0 + 1) = 0.5 — below threshold
  ac <- hnet$edges[hnet$edges$from == "A" & hnet$edges$to == "C", ]
  expect_equal(nrow(ac), 0L)
})

test_that("discover_heuristics rejects invalid threshold", {
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  log  <- tibble::tibble(
    case_id = "C1", activity = c("A", "B"),
    timestamp = base + c(0, 100)
  )
  expect_error(discover_heuristics(log, dependency_threshold = 1.5),
               "dependency_threshold")
})
