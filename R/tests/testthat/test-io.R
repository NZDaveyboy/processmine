# ---- helpers ----------------------------------------------------------------

make_minimal_log <- function() {
  tibble::tibble(
    case_id   = c("C1", "C1", "C2"),
    activity  = c("A", "B", "A"),
    timestamp = as.POSIXct(
      c("2024-01-01 08:00:00", "2024-01-01 09:00:00", "2024-01-02 08:00:00"),
      tz = "UTC"
    )
  )
}

make_full_log <- function() {
  tibble::tibble(
    case_id         = c("C1", "C1", "C2"),
    activity        = c("A", "B", "A"),
    timestamp       = as.POSIXct(
      c("2024-01-01 08:00:00", "2024-01-01 09:00:00", "2024-01-02 08:00:00"),
      tz = "UTC"
    ),
    start_timestamp = as.POSIXct(
      c("2024-01-01 07:50:00", "2024-01-01 08:55:00", "2024-01-02 07:45:00"),
      tz = "UTC"
    ),
    resource  = c("alice", "bob", "alice"),
    lifecycle = c("complete", "complete", "start"),
    case_attrs  = list(
      list(dept = "sales"),
      list(dept = "sales"),
      list(dept = "ops")
    ),
    event_attrs = list(
      list(priority = "high"),
      list(),
      list(priority = "low")
    )
  )
}

# ---- validate_eventlog ------------------------------------------------------

test_that("validate_eventlog accepts a valid minimal log", {
  log <- make_minimal_log()
  expect_invisible(validate_eventlog(log))
})

test_that("validate_eventlog accepts a full log with optional columns", {
  log <- make_full_log()
  expect_invisible(validate_eventlog(log))
})

test_that("validate_eventlog rejects missing case_id column", {
  log <- make_minimal_log()
  log$case_id <- NULL
  expect_error(validate_eventlog(log), "case_id")
})

test_that("validate_eventlog rejects missing activity column", {
  log <- make_minimal_log()
  log$activity <- NULL
  expect_error(validate_eventlog(log), "activity")
})

test_that("validate_eventlog rejects missing timestamp column", {
  log <- make_minimal_log()
  log$timestamp <- NULL
  expect_error(validate_eventlog(log), "timestamp")
})

test_that("validate_eventlog rejects NA in required columns", {
  log <- make_minimal_log()
  log$case_id[1] <- NA_character_
  expect_error(validate_eventlog(log), "NA")
})

test_that("validate_eventlog rejects non-UTC timestamp", {
  log <- make_minimal_log()
  log$timestamp <- as.POSIXct(
    c("2024-01-01 08:00:00", "2024-01-01 09:00:00", "2024-01-02 08:00:00"),
    tz = "America/New_York"
  )
  expect_error(validate_eventlog(log), "[Uu][Tt][Cc]")
})

test_that("validate_eventlog rejects timestamp before start_timestamp", {
  log <- make_minimal_log()
  log$start_timestamp <- log$timestamp + 3600  # start > end
  expect_error(validate_eventlog(log), "start_timestamp")
})

test_that("validate_eventlog rejects invalid lifecycle value", {
  log <- make_minimal_log()
  log$lifecycle <- c("complete", "complete", "INVALID")
  expect_error(validate_eventlog(log), "lifecycle")
})

# ---- read_xes ---------------------------------------------------------------

test_that("read_xes parses the tiny fixture", {
  path <- testthat::test_path("fixtures", "tiny.xes")
  log  <- read_xes(path)

  expect_s3_class(log, "tbl_df")
  expect_equal(nrow(log), 5L)
  expect_true(all(c("case_id", "activity", "timestamp") %in% names(log)))
  expect_equal(attr(log$timestamp, "tzone"), "UTC")
})

test_that("read_xes maps XES keys correctly", {
  path <- testthat::test_path("fixtures", "tiny.xes")
  log  <- read_xes(path)

  expect_equal(sort(unique(log$case_id)), c("case-1", "case-2", "case-3"))
  expect_equal(sort(unique(log$activity)), c("approve", "reject", "submit"))
  expect_true("resource" %in% names(log))
  expect_equal(log$resource[log$case_id == "case-1" & log$activity == "submit"], "alice")
})

test_that("read_xes captures non-standard attributes in case_attrs/event_attrs", {
  path <- testthat::test_path("fixtures", "tiny.xes")
  log  <- read_xes(path)

  expect_true("case_attrs" %in% names(log))
  # case-1 has department = sales
  ca <- log$case_attrs[log$case_id == "case-1"][[1]]
  expect_equal(ca[["department"]], "sales")
})

# ---- write/read_eventlog_parquet --------------------------------------------

test_that("write_eventlog_parquet + read_eventlog_parquet round-trips required columns", {
  log  <- make_minimal_log()
  tmp  <- tempfile(fileext = ".parquet")
  on.exit(unlink(tmp))

  write_eventlog_parquet(log, tmp)
  back <- read_eventlog_parquet(tmp)

  expect_equal(back$case_id,   log$case_id)
  expect_equal(back$activity,  log$activity)
  expect_equal(back$timestamp, log$timestamp)
})

test_that("write_eventlog_parquet + read_eventlog_parquet round-trips all optional columns", {
  log  <- make_full_log()
  tmp  <- tempfile(fileext = ".parquet")
  on.exit(unlink(tmp))

  write_eventlog_parquet(log, tmp)
  back <- read_eventlog_parquet(tmp)

  expect_equal(back$resource,        log$resource)
  expect_equal(back$lifecycle,       log$lifecycle)
  expect_equal(back$start_timestamp, log$start_timestamp)
  # attrs columns round-trip as named character vectors
  expect_equal(back$case_attrs[[1]], c(dept = "sales"))
  expect_equal(back$event_attrs[[1]], c(priority = "high"))
  expect_equal(length(back$event_attrs[[2]]), 0L)
})

test_that("Parquet file carries schema_version metadata", {
  log <- make_minimal_log()
  tmp <- tempfile(fileext = ".parquet")
  on.exit(unlink(tmp))

  write_eventlog_parquet(log, tmp)
  tbl  <- arrow::read_parquet(tmp, as_data_frame = FALSE)
  meta <- tbl$schema$metadata
  expect_equal(meta[["schema_version"]], "1.0")
})

test_that("read_eventlog_parquet rejects unknown major schema version", {
  log <- make_minimal_log()
  tmp <- tempfile(fileext = ".parquet")
  on.exit(unlink(tmp))

  # Write valid parquet, then overwrite schema_version metadata to 2.0
  write_eventlog_parquet(log, tmp)
  tbl <- arrow::read_parquet(tmp, as_data_frame = FALSE)
  tbl <- tbl$ReplaceSchemaMetadata(list(schema_version = "2.0"))
  arrow::write_parquet(tbl, tmp)

  expect_error(read_eventlog_parquet(tmp), "[Ss]chema.version|version")
})
