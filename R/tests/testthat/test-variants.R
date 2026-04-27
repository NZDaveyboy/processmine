make_variant_log <- function() {
  # 6 cases:
  # C1-C4: A -> B -> C  (4 cases, freq = 4/6 ≈ 0.667)
  # C5:    A -> C       (1 case,  freq = 1/6 ≈ 0.167)
  # C6:    A -> B       (1 case,  freq = 1/6 ≈ 0.167)
  base <- as.POSIXct("2024-01-01", tz = "UTC")
  rows <- do.call(rbind, lapply(1:4, function(i) {
    data.frame(case_id = paste0("C", i), activity = c("A","B","C"),
               timestamp = base + c(0,100,200) + (i-1)*1000, stringsAsFactors = FALSE)
  }))
  rows <- rbind(rows,
    data.frame(case_id = "C5", activity = c("A","C"),
               timestamp = base + c(0,100) + 4000, stringsAsFactors = FALSE),
    data.frame(case_id = "C6", activity = c("A","B"),
               timestamp = base + c(0,100) + 5000, stringsAsFactors = FALSE)
  )
  tibble::as_tibble(rows)
}

test_that("variants returns correct variant strings", {
  log <- make_variant_log()
  v   <- variants(log)

  expect_s3_class(v, "data.frame")
  expect_named(v, c("variant", "n", "freq"))
  expect_true("A->B->C" %in% v$variant)
  expect_true("A->C"    %in% v$variant)
  expect_true("A->B"    %in% v$variant)
})

test_that("variants counts are correct", {
  log <- make_variant_log()
  v   <- variants(log)

  main <- v[v$variant == "A->B->C", ]
  expect_equal(main$n, 4L)
  expect_equal(main$freq, 4/6, tolerance = 1e-6)
})

test_that("variants frequencies sum to 1", {
  log <- make_variant_log()
  v   <- variants(log)
  expect_equal(sum(v$freq), 1.0, tolerance = 1e-10)
})

test_that("variants are sorted by descending frequency", {
  log <- make_variant_log()
  v   <- variants(log)
  expect_true(all(diff(v$n) <= 0))
})

test_that("rare_paths returns variants below support threshold", {
  log  <- make_variant_log()
  rare <- rare_paths(log, min_support = 0.2)

  # A->C (1/6 ≈ 0.167) and A->B (1/6 ≈ 0.167) are below 0.2
  expect_true("A->C" %in% rare$variant)
  expect_true("A->B" %in% rare$variant)
  # A->B->C (4/6 ≈ 0.667) is NOT rare
  expect_false("A->B->C" %in% rare$variant)
})

test_that("rare_paths returns empty tibble when nothing is rare", {
  log  <- make_variant_log()
  rare <- rare_paths(log, min_support = 0.01)
  expect_equal(nrow(rare), 0L)
})

test_that("rare_paths rejects invalid min_support", {
  log <- make_variant_log()
  expect_error(rare_paths(log, min_support = 0),     "min_support")
  expect_error(rare_paths(log, min_support = -0.1),  "min_support")
  expect_error(rare_paths(log, min_support = 1.5),   "min_support")
})
