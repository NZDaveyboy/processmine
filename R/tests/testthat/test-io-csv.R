
# Helper — write a temp CSV and return its path
.write_tmp_csv <- function(df) {
  path <- tempfile(fileext = ".csv")
  utils::write.csv(df, path, row.names = FALSE)
  path
}

test_that("read_csv_eventlog reads minimal CSV with default column names", {
  df <- data.frame(
    case_id   = c("C1", "C1", "C2"),
    activity  = c("A", "B", "A"),
    timestamp = c("2024-01-01 00:00:00", "2024-01-01 01:00:00", "2024-01-01 00:00:00"),
    stringsAsFactors = FALSE
  )
  path <- .write_tmp_csv(df)
  log  <- read_csv_eventlog(path, timestamp_format = "%Y-%m-%d %H:%M:%S")

  expect_equal(nrow(log), 3L)
  expect_equal(log$case_id,  c("C1", "C1", "C2"))
  expect_equal(log$activity, c("A",  "B",  "A"))
  expect_s3_class(log$timestamp, "POSIXct")
  expect_equal(attr(log$timestamp, "tzone"), "UTC")
})

test_that("read_csv_eventlog maps custom column names", {
  df <- data.frame(
    CaseID    = c("X1", "X1"),
    EventName = c("Start", "End"),
    EventTime = c("2024-01-01 08:00:00", "2024-01-01 09:00:00"),
    stringsAsFactors = FALSE
  )
  path <- .write_tmp_csv(df)
  log  <- read_csv_eventlog(
    path,
    case_col      = "CaseID",
    activity_col  = "EventName",
    timestamp_col = "EventTime",
    timestamp_format = "%Y-%m-%d %H:%M:%S"
  )

  expect_equal(names(log)[1:3], c("case_id", "activity", "timestamp"))
  expect_equal(log$case_id, c("X1", "X1"))
})

test_that("read_csv_eventlog includes optional columns when specified", {
  df <- data.frame(
    case_id   = "C1",
    activity  = "A",
    timestamp = "2024-01-01 00:00:00",
    resource  = "alice",
    lifecycle = "complete",
    stringsAsFactors = FALSE
  )
  path <- .write_tmp_csv(df)
  log  <- read_csv_eventlog(
    path,
    resource_col  = "resource",
    lifecycle_col = "lifecycle",
    timestamp_format = "%Y-%m-%d %H:%M:%S"
  )

  expect_true("resource"  %in% names(log))
  expect_true("lifecycle" %in% names(log))
  expect_equal(log$resource,  "alice")
  expect_equal(log$lifecycle, "complete")
})

test_that("read_csv_eventlog folds columns into case_attrs and event_attrs", {
  df <- data.frame(
    case_id   = c("C1", "C1"),
    activity  = c("A",  "B"),
    timestamp = c("2024-01-01 00:00:00", "2024-01-01 01:00:00"),
    region    = c("NZ",  "NZ"),
    cost      = c("10",  "20"),
    stringsAsFactors = FALSE
  )
  path <- .write_tmp_csv(df)
  log  <- read_csv_eventlog(
    path,
    case_attrs_cols  = "region",
    event_attrs_cols = "cost",
    timestamp_format = "%Y-%m-%d %H:%M:%S"
  )

  expect_true("case_attrs"  %in% names(log))
  expect_true("event_attrs" %in% names(log))
  expect_equal(log$case_attrs[[1]][["region"]],  "NZ")
  expect_equal(log$event_attrs[[1]][["cost"]], "10")
  expect_equal(log$event_attrs[[2]][["cost"]], "20")
})

test_that("read_csv_eventlog converts non-UTC source timezone to UTC", {
  df <- data.frame(
    case_id   = "C1",
    activity  = "A",
    timestamp = "2024-01-01 12:00:00",
    stringsAsFactors = FALSE
  )
  path <- .write_tmp_csv(df)
  log  <- read_csv_eventlog(
    path,
    timestamp_format = "%Y-%m-%d %H:%M:%S",
    tz = "Pacific/Auckland"  # UTC+13
  )

  # 2024-01-01 12:00 NZDT = 2024-12-31 23:00 UTC
  expect_equal(attr(log$timestamp, "tzone"), "UTC")
})

test_that("read_csv_eventlog errors when required source column is missing", {
  df <- data.frame(
    case_id   = "C1",
    activity  = "A",
    timestamp = "2024-01-01 00:00:00",
    stringsAsFactors = FALSE
  )
  path <- .write_tmp_csv(df)
  expect_error(read_csv_eventlog(path, case_col = "no_such_col"), "not found in CSV")
})

test_that("read_csv_eventlog errors when optional source column is missing", {
  df <- data.frame(
    case_id   = "C1",
    activity  = "A",
    timestamp = "2024-01-01 00:00:00",
    stringsAsFactors = FALSE
  )
  path <- .write_tmp_csv(df)
  expect_error(
    read_csv_eventlog(path, resource_col = "no_resource",
                      timestamp_format = "%Y-%m-%d %H:%M:%S"),
    "not found in CSV"
  )
})
