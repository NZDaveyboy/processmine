make_conform_log <- function() {
  # C1: A -> B -> C (happy path)
  # C2: A -> B -> C (happy path)
  # C3: A -> X -> C (X not in model — non-fitting transition)
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  tibble::as_tibble(data.frame(
    case_id   = c("C1","C1","C1","C2","C2","C2","C3","C3","C3"),
    activity  = c("A","B","C","A","B","C","A","X","C"),
    timestamp = base + c(0,100,200, 500,600,700, 1000,1100,1200),
    stringsAsFactors = FALSE
  ))
}

test_that("conformance_tokenreplay returns processmine_conformance", {
  log   <- make_conform_log()
  model <- discover_dfg(log)
  conf  <- conformance_tokenreplay(log, model)

  expect_s3_class(conf, "processmine_conformance")
  expect_named(conf, c("summary", "per_case", "diagnostics"))
  expect_s3_class(conf$per_case, "data.frame")
  expect_named(conf$per_case, c("case_id", "transitions", "fitting", "fitness"))
})

test_that("conformance_tokenreplay gives fitness 1 for perfect fit", {
  log   <- make_conform_log()
  # Build model from C1 and C2 only (the happy-path cases)
  ref   <- log[log$case_id %in% c("C1", "C2"), ]
  model <- discover_dfg(ref)
  conf  <- conformance_tokenreplay(log, model)

  c1 <- conf$per_case[conf$per_case$case_id == "C1", ]
  expect_equal(c1$fitness, 1.0)

  c2 <- conf$per_case[conf$per_case$case_id == "C2", ]
  expect_equal(c2$fitness, 1.0)
})

test_that("conformance_tokenreplay penalises non-fitting transitions", {
  log   <- make_conform_log()
  ref   <- log[log$case_id %in% c("C1", "C2"), ]
  model <- discover_dfg(ref)
  conf  <- conformance_tokenreplay(log, model)

  c3 <- conf$per_case[conf$per_case$case_id == "C3", ]
  # A->X is not in model; X->C is not in model — 0 fitting out of 2
  expect_equal(c3$fitting, 0L)
  expect_equal(c3$fitness, 0.0)
})

test_that("conformance_tokenreplay summary stats are correct", {
  log   <- make_conform_log()
  ref   <- log[log$case_id %in% c("C1", "C2"), ]
  model <- discover_dfg(ref)
  conf  <- conformance_tokenreplay(log, model)

  expect_equal(conf$summary$n_cases, 3L)
  expect_equal(conf$summary$n_fitting_cases, 2L)
  expect_equal(conf$summary$mean_fitness, 2/3, tolerance = 1e-6)
})

test_that("conformance_tokenreplay accepts heuristics net", {
  log   <- make_conform_log()
  model <- discover_heuristics(log, dependency_threshold = 0.0)
  conf  <- conformance_tokenreplay(log, model)

  expect_s3_class(conf, "processmine_conformance")
  expect_equal(conf$diagnostics$model_type, "processmine_hnet")
})

test_that("conformance_tokenreplay rejects unknown model type", {
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  log  <- tibble::tibble(
    case_id = "C1", activity = c("A", "B"),
    timestamp = base + c(0, 100)
  )
  expect_error(conformance_tokenreplay(log, list(edges = data.frame())),
               "processmine_dfg")
})

test_that("conformance_tokenreplay handles single-event cases", {
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  log  <- tibble::tibble(
    case_id = c("C1", "C1", "C2"),
    activity  = c("A", "B", "A"),
    timestamp = base + c(0, 100, 500)
  )
  model <- discover_dfg(log[log$case_id == "C1", ])
  conf  <- conformance_tokenreplay(log, model)

  c2 <- conf$per_case[conf$per_case$case_id == "C2", ]
  expect_equal(c2$transitions, 0L)
  expect_true(is.na(c2$fitness))
})
