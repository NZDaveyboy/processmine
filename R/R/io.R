#' @importFrom rlang abort
#' @importFrom arrow read_parquet write_parquet as_arrow_table
#' @importFrom tibble tibble as_tibble
#' @importFrom jsonlite toJSON fromJSON
NULL

SCHEMA_VERSION <- "1.0"
LIFECYCLE_VALS <- c("start", "complete", "schedule", "withdraw", "suspend", "resume")
REQUIRED_COLS  <- c("case_id", "activity", "timestamp")

# ---- validate_eventlog -------------------------------------------------------

#' Validate an event log against the processmine schema (v1).
#'
#' @param log A data frame / tibble.
#' @return `log` invisibly on success; throws on violation.
#' @export
validate_eventlog <- function(log) {
  missing_cols <- setdiff(REQUIRED_COLS, names(log))
  if (length(missing_cols) > 0) {
    rlang::abort(paste0("Missing required column(s): ", paste(missing_cols, collapse = ", ")))
  }

  for (col in REQUIRED_COLS) {
    if (anyNA(log[[col]])) {
      rlang::abort(paste0(
        "Column '", col, "' contains NA values; required columns must be non-null."
      ))
    }
  }

  .assert_utc(log$timestamp, "timestamp")

  if ("start_timestamp" %in% names(log)) {
    .assert_utc(log$start_timestamp, "start_timestamp", allow_na = TRUE)
    both <- !is.na(log$start_timestamp)
    if (any(log$timestamp[both] < log$start_timestamp[both])) {
      rlang::abort("start_timestamp must be <= timestamp for all events.")
    }
  }

  if ("lifecycle" %in% names(log)) {
    vals <- unique(stats::na.omit(log$lifecycle))
    bad  <- setdiff(vals, LIFECYCLE_VALS)
    if (length(bad) > 0) {
      rlang::abort(paste0(
        "Invalid lifecycle value(s): ", paste(bad, collapse = ", "),
        ". Allowed: ", paste(LIFECYCLE_VALS, collapse = ", ")
      ))
    }
  }

  invisible(log)
}

.assert_utc <- function(x, name, allow_na = FALSE) {
  if (!inherits(x, "POSIXct")) {
    rlang::abort(paste0("Column '", name, "' must be POSIXct."))
  }
  tz <- attr(x, "tzone")
  if (is.null(tz) || !(tz %in% c("UTC", "GMT"))) {
    rlang::abort(paste0("Column '", name, "' must have tz = UTC (got '", tz %||% "NULL", "')."))
  }
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

# ---- read_xes ----------------------------------------------------------------

#' Read an XES event log file into a processmine tibble.
#'
#' @param path Path to a `.xes` file.
#' @return A validated tibble conforming to the processmine schema.
#' @export
read_xes <- function(path) {
  doc    <- xml2::read_xml(path)
  ns     <- c(xes = "http://www.xes-standard.org/")
  traces <- xml2::xml_find_all(doc, ".//xes:trace|.//trace", ns)

  rows <- vector("list", 0L)

  for (tr in traces) {
    case_id    <- .xes_string(tr, "concept:name")
    case_attrs <- .xes_extra_attrs(tr, c("concept:name"))

    events <- xml2::xml_find_all(tr, ".//xes:event|.//event", ns)
    for (ev in events) {
      activity    <- .xes_string(ev, "concept:name")
      ts          <- .xes_date(ev, "time:timestamp")
      resource    <- .xes_string(ev, "org:resource",          default = NA_character_)
      lifecycle   <- .xes_string(ev, "lifecycle:transition",  default = NA_character_)
      event_attrs <- .xes_extra_attrs(ev, c("concept:name", "time:timestamp",
                                            "org:resource", "lifecycle:transition"))
      rows[[length(rows) + 1L]] <- list(
        case_id     = case_id,
        activity    = activity,
        timestamp   = ts,
        resource    = resource,
        lifecycle   = lifecycle,
        case_attrs  = list(case_attrs),
        event_attrs = list(event_attrs)
      )
    }
  }

  log <- tibble::tibble(
    case_id     = vapply(rows, `[[`, character(1), "case_id"),
    activity    = vapply(rows, `[[`, character(1), "activity"),
    timestamp   = do.call(c, lapply(rows, `[[`, "timestamp")),
    resource    = vapply(rows, `[[`, character(1), "resource"),
    lifecycle   = vapply(rows, `[[`, character(1), "lifecycle"),
    case_attrs  = lapply(rows, function(r) r$case_attrs[[1]]),
    event_attrs = lapply(rows, function(r) r$event_attrs[[1]])
  )

  validate_eventlog(log)
  log
}

.xes_string <- function(node, key, default = NA_character_) {
  child <- xml2::xml_find_first(node, paste0(".//*[@key='", key, "']"))
  if (inherits(child, "xml_missing")) return(default)
  val <- xml2::xml_attr(child, "value")
  if (is.na(val)) default else val
}

.xes_date <- function(node, key) {
  raw <- .xes_string(node, key, default = NA_character_)
  if (is.na(raw)) return(as.POSIXct(NA, tz = "UTC"))
  as.POSIXct(raw, format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC")
}

.xes_extra_attrs <- function(node, skip_keys) {
  children <- xml2::xml_children(node)
  out <- character(0)
  for (ch in children) {
    k <- xml2::xml_attr(ch, "key")
    v <- xml2::xml_attr(ch, "value")
    if (!is.na(k) && !(k %in% skip_keys) && !is.na(v) &&
        xml2::xml_name(ch) %in% c("string", "int", "float", "boolean")) {
      out[k] <- as.character(v)
    }
  }
  out
}

# ---- read_csv_eventlog -------------------------------------------------------

#' Read a CSV file into a processmine event log tibble.
#'
#' Maps arbitrary CSV column names to the processmine schema, parses
#' timestamps, and calls `validate_eventlog()` before returning.
#'
#' @param path Path to a `.csv` file.
#' @param case_col Name of the column containing the case identifier.
#' @param activity_col Name of the column containing the activity name.
#' @param timestamp_col Name of the column containing the event completion timestamp.
#' @param start_timestamp_col Optional name of the column containing the event
#'   start timestamp. `NULL` to omit.
#' @param resource_col Optional name of the resource column. `NULL` to omit.
#' @param lifecycle_col Optional name of the lifecycle column. `NULL` to omit.
#' @param case_attrs_cols Optional character vector of column names to fold
#'   into the `case_attrs` map. These columns are removed from the top-level
#'   output and stored as named character vectors per event.
#' @param event_attrs_cols Optional character vector of column names to fold
#'   into the `event_attrs` map.
#' @param timestamp_format `strptime`-style format string for parsing
#'   timestamps (e.g. `"%Y-%m-%d %H:%M:%S"`). `NULL` lets R guess.
#' @param tz Source timezone of the timestamp strings. Defaults to `"UTC"`.
#'   Set to the actual timezone if your CSV stores local times (e.g.
#'   `"America/New_York"`); they will be converted to UTC.
#' @param ... Additional arguments passed to [utils::read.csv()].
#'
#' @return A validated tibble conforming to the processmine schema.
#' @export
read_csv_eventlog <- function(
  path,
  case_col            = "case_id",
  activity_col        = "activity",
  timestamp_col       = "timestamp",
  start_timestamp_col = NULL,
  resource_col        = NULL,
  lifecycle_col       = NULL,
  case_attrs_cols     = NULL,
  event_attrs_cols    = NULL,
  timestamp_format    = NULL,
  tz                  = "UTC",
  ...
) {
  raw <- utils::read.csv(path, stringsAsFactors = FALSE, ...)

  # Check required source columns exist
  required_src <- c(case_col, activity_col, timestamp_col)
  optional_src <- c(start_timestamp_col, resource_col, lifecycle_col,
                    case_attrs_cols, event_attrs_cols)
  missing_src  <- setdiff(c(required_src, optional_src), names(raw))
  if (length(missing_src) > 0) {
    rlang::abort(paste0(
      "Column(s) not found in CSV: ", paste(missing_src, collapse = ", ")
    ))
  }

  # Build log with canonical names
  log <- tibble::tibble(
    case_id  = as.character(raw[[case_col]]),
    activity = as.character(raw[[activity_col]]),
    timestamp = .parse_csv_timestamp(raw[[timestamp_col]], timestamp_format, tz)
  )

  if (!is.null(start_timestamp_col)) {
    log$start_timestamp <- .parse_csv_timestamp(
      raw[[start_timestamp_col]], timestamp_format, tz
    )
  }
  if (!is.null(resource_col)) {
    log$resource <- as.character(raw[[resource_col]])
  }
  if (!is.null(lifecycle_col)) {
    log$lifecycle <- as.character(raw[[lifecycle_col]])
  }

  # Fold extra columns into attrs maps
  if (!is.null(case_attrs_cols)) {
    log$case_attrs <- lapply(seq_len(nrow(raw)), function(i) {
      vapply(case_attrs_cols, function(col) as.character(raw[[col]][i]), character(1))
    })
  }
  if (!is.null(event_attrs_cols)) {
    log$event_attrs <- lapply(seq_len(nrow(raw)), function(i) {
      vapply(event_attrs_cols, function(col) as.character(raw[[col]][i]), character(1))
    })
  }

  validate_eventlog(log)
  log
}

.parse_csv_timestamp <- function(x, fmt, tz) {
  parsed <- if (is.null(fmt)) {
    as.POSIXct(x, tz = tz)
  } else {
    as.POSIXct(x, format = fmt, tz = tz)
  }
  # Convert to UTC if source tz differs
  attr(parsed, "tzone") <- "UTC"
  parsed
}

# ---- write_eventlog_parquet --------------------------------------------------

#' Write a validated event log to a Parquet file.
#'
#' `case_attrs` and `event_attrs` list-columns are serialised to JSON strings
#' at the Parquet boundary for portability. Use `read_eventlog_parquet()` to
#' round-trip them back to named character vectors.
#'
#' @param log A data frame conforming to the processmine schema.
#' @param path Destination path for the `.parquet` file.
#' @return `path` invisibly.
#' @export
write_eventlog_parquet <- function(log, path) {
  validate_eventlog(log)
  df <- as.data.frame(log, stringsAsFactors = FALSE)

  # Ensure UTC tz attribute is preserved after coercion
  attr(df$timestamp, "tzone") <- "UTC"
  if ("start_timestamp" %in% names(df)) {
    attr(df$start_timestamp, "tzone") <- "UTC"
  }

  # Serialise map-like list columns to JSON strings
  if ("case_attrs" %in% names(df)) {
    df$case_attrs <- vapply(df$case_attrs, .attrs_to_json, character(1))
  }
  if ("event_attrs" %in% names(df)) {
    df$event_attrs <- vapply(df$event_attrs, .attrs_to_json, character(1))
  }

  tbl <- arrow::as_arrow_table(tibble::as_tibble(df))
  tbl <- tbl$ReplaceSchemaMetadata(list(schema_version = SCHEMA_VERSION))
  arrow::write_parquet(tbl, path)
  invisible(path)
}

.attrs_to_json <- function(x) {
  if (length(x) == 0) return("{}")
  # Accept both named lists and named character vectors
  x <- vapply(x, function(v) as.character(v)[1L], character(1L))
  as.character(jsonlite::toJSON(as.list(x), auto_unbox = TRUE))
}

# ---- read_eventlog_parquet ---------------------------------------------------

#' Read a Parquet event log written by processmine.
#'
#' @param path Path to a `.parquet` file.
#' @return A validated tibble conforming to the processmine schema.
#' @export
read_eventlog_parquet <- function(path) {
  tbl <- arrow::read_parquet(path, as_data_frame = FALSE)

  meta    <- tbl$schema$metadata
  version <- meta[["schema_version"]]
  if (is.null(version)) {
    rlang::abort("Parquet file is missing 'schema_version' metadata.")
  }
  major <- as.integer(strsplit(version, "\\.")[[1]][1])
  if (major != 1L) {
    rlang::abort(paste0(
      "Unsupported schema version '", version, "'. ",
      "Only major version 1 is supported."
    ))
  }

  log <- tibble::as_tibble(tbl)

  # Deserialise JSON string map columns back to named character vectors
  if ("case_attrs" %in% names(log)) {
    log$case_attrs <- lapply(log$case_attrs, .json_to_attrs)
  }
  if ("event_attrs" %in% names(log)) {
    log$event_attrs <- lapply(log$event_attrs, .json_to_attrs)
  }

  # Restore UTC tz attribute (Arrow round-trip may drop tzone on POSIXct)
  if ("timestamp" %in% names(log)) {
    attr(log$timestamp, "tzone") <- "UTC"
  }
  if ("start_timestamp" %in% names(log)) {
    attr(log$start_timestamp, "tzone") <- "UTC"
  }

  validate_eventlog(log)
  log
}

.json_to_attrs <- function(x) {
  if (is.null(x) || identical(x, "{}") || identical(x, "")) return(character(0))
  obj <- jsonlite::fromJSON(x, simplifyVector = TRUE)
  if (length(obj) == 0) return(character(0))
  vapply(obj, function(v) as.character(v)[1L], character(1L))
}
