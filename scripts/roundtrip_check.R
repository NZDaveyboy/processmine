#!/usr/bin/env Rscript
# scripts/roundtrip_check.R
# Loads a synthetic fixture log (10 cases, 3 activities, UTC timestamps),
# round-trips R -> Parquet -> Python -> Parquet -> R, and asserts lossless
# equality on all schema columns.

`%||%` <- function(a, b) if (!is.null(a)) a else b

suppressPackageStartupMessages({
  devtools::load_all("R", quiet = TRUE)
})

# ---- 1. Build synthetic fixture ---------------------------------------------

set.seed(42)

cases      <- paste0("C", sprintf("%03d", 1:10))
activities <- c("submit", "approve", "close")
base_time  <- as.POSIXct("2024-03-01 08:00:00", tz = "UTC")

rows <- do.call(rbind, lapply(cases, function(cid) {
  acts <- sample(activities, size = sample(2:3, 1), replace = FALSE)
  n    <- length(acts)
  ts   <- base_time + cumsum(sample(600:3600, n))
  st   <- ts - sample(60:300, n)
  data.frame(
    case_id         = cid,
    activity        = acts,
    timestamp       = ts,
    start_timestamp = st,
    resource        = sample(c("alice", "bob", "carol"), n, replace = TRUE),
    lifecycle       = sample(c("complete", "start"), n, replace = TRUE),
    stringsAsFactors = FALSE
  )
}))

# Attach case_attrs and event_attrs as list columns
rows$case_attrs  <- lapply(rows$case_id, function(cid) {
  c(dept = sample(c("sales", "ops", "legal"), 1),
    priority = sample(c("low", "medium", "high"), 1))
})
rows$event_attrs <- lapply(seq_len(nrow(rows)), function(i) {
  if (i %% 3 == 0) character(0) else c(note = paste0("note-", i))
})

fixture <- tibble::as_tibble(rows)

cat("Fixture rows:", nrow(fixture), "\n")
cat("Fixture cases:", length(unique(fixture$case_id)), "\n")

# ---- 2. Validate fixture ----------------------------------------------------

validate_eventlog(fixture)
cat("[OK] R validate_eventlog passed\n")

# ---- 3. R -> Parquet (tmp1) -------------------------------------------------

tmp1 <- tempfile(fileext = ".parquet")
tmp2 <- tempfile(fileext = ".parquet")
on.exit({ unlink(tmp1); unlink(tmp2) })

write_eventlog_parquet(fixture, tmp1)
cat("[OK] R write_eventlog_parquet ->", tmp1, "\n")

# ---- 4. Python reads tmp1, validates, writes tmp2 ---------------------------

# Resolve _roundtrip_py.py relative to this script's location when called via
# Rscript, and fall back to "scripts/" if running from the repo root via make.
this_dir  <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)), error = function(e) ".")
py_script <- file.path(this_dir, "_roundtrip_py.py")
if (!file.exists(py_script)) {
  py_script <- file.path("scripts", "_roundtrip_py.py")
}

ret <- system2("python3", c(shQuote(py_script), shQuote(tmp1), shQuote(tmp2)),
               stdout = TRUE, stderr = TRUE)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  cat(ret, sep = "\n")
  stop("Python roundtrip step failed (exit code ", attr(ret, "status"), ")")
}
cat("[OK] Python read/write complete\n")

# ---- 5. R reads tmp2 --------------------------------------------------------

back <- read_eventlog_parquet(tmp2)
cat("[OK] R read_eventlog_parquet from Python output\n")

# ---- 6. Assert equality on all schema columns --------------------------------

stopifnot_equal <- function(a, b, label) {
  if (!isTRUE(all.equal(a, b))) {
    stop(paste0("MISMATCH in column '", label, "':\n",
                paste(capture.output(all.equal(a, b)), collapse = "\n")))
  }
  cat(sprintf("  [=] %-20s OK\n", label))
}

cat("\nColumn-level equality checks:\n")
stopifnot_equal(back$case_id,         fixture$case_id,         "case_id")
stopifnot_equal(back$activity,         fixture$activity,         "activity")
stopifnot_equal(back$timestamp,        fixture$timestamp,        "timestamp")
stopifnot_equal(back$start_timestamp,  fixture$start_timestamp,  "start_timestamp")
stopifnot_equal(back$resource,         fixture$resource,         "resource")
stopifnot_equal(back$lifecycle,        fixture$lifecycle,        "lifecycle")

# Normalise map columns: sort keys, serialise to JSON-like string for comparison
norm_attrs <- function(x) {
  vapply(x, function(m) {
    if (length(m) == 0) return("{}")
    m <- m[order(names(m))]
    paste0("{", paste(names(m), m, sep = "=", collapse = ","), "}")
  }, character(1))
}

stopifnot_equal(norm_attrs(back$case_attrs),  norm_attrs(fixture$case_attrs),  "case_attrs")
stopifnot_equal(norm_attrs(back$event_attrs), norm_attrs(fixture$event_attrs), "event_attrs")

cat("\n*** ROUNDTRIP PASS ***\n")
