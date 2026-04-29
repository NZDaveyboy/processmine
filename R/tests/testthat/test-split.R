test_that("train_test_split_by_case returns correct proportions", {
  log <- tibble::tibble(
    case_id   = rep(paste0("C", 1:10), each = 3),
    activity  = rep(c("A", "B", "C"), 10),
    timestamp = as.POSIXct(
      seq(as.POSIXct("2024-01-01", tz = "UTC"),
          by = "hour", length.out = 30),
      tz = "UTC"
    )
  )

  splits <- train_test_split_by_case(log, test_size = 0.2, random_state = 42L)
  expect_named(splits, c("train", "test"))

  total_cases <- length(unique(log$case_id))
  n_test  <- length(unique(splits$test$case_id))
  n_train <- length(unique(splits$train$case_id))
  expect_equal(n_test + n_train, total_cases)
})

test_that("no case appears in both train and test", {
  log <- tibble::tibble(
    case_id   = rep(paste0("C", 1:20), each = 2),
    activity  = rep(c("A", "B"), 20),
    timestamp = as.POSIXct(
      seq(as.POSIXct("2024-01-01", tz = "UTC"),
          by = "hour", length.out = 40),
      tz = "UTC"
    )
  )

  splits  <- train_test_split_by_case(log, test_size = 0.3, random_state = 1L)
  overlap <- intersect(splits$train$case_id, splits$test$case_id)
  expect_length(overlap, 0)
})

test_that("split is reproducible", {
  log <- tibble::tibble(
    case_id   = rep(paste0("C", 1:20), each = 2),
    activity  = rep(c("A", "B"), 20),
    timestamp = as.POSIXct(
      seq(as.POSIXct("2024-01-01", tz = "UTC"),
          by = "hour", length.out = 40),
      tz = "UTC"
    )
  )

  s1 <- train_test_split_by_case(log, random_state = 99L)
  s2 <- train_test_split_by_case(log, random_state = 99L)
  expect_equal(sort(unique(s1$test$case_id)), sort(unique(s2$test$case_id)))
})

test_that("invalid test_size is rejected", {
  log <- tibble::tibble(
    case_id   = c("C1", "C1"),
    activity  = c("A", "B"),
    timestamp = as.POSIXct(c("2024-01-01", "2024-01-02"), tz = "UTC")
  )

  expect_error(train_test_split_by_case(log, test_size = 0))
  expect_error(train_test_split_by_case(log, test_size = 1))
  expect_error(train_test_split_by_case(log, test_size = -0.1))
})

test_that("columns are preserved in both splits", {
  log <- tibble::tibble(
    case_id   = rep(c("C1", "C2"), each = 2),
    activity  = c("A", "B", "A", "B"),
    timestamp = as.POSIXct(
      c("2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04"), tz = "UTC"
    ),
    resource  = c("alice", "bob", "carol", "dave")
  )

  splits <- train_test_split_by_case(log, test_size = 0.5, random_state = 1L)
  expect_equal(names(splits$train), names(log))
  expect_equal(names(splits$test), names(log))
})
