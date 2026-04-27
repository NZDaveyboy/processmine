#' @importFrom tibble as_tibble tibble
#' @importFrom rlang abort
NULL

.time_units <- c("seconds", "minutes", "hours", "days", "weeks")
.unit_secs  <- c(seconds = 1, minutes = 60, hours = 3600,
                 days = 86400, weeks = 604800)

# ---- performance_throughput --------------------------------------------------

#' Compute per-case throughput time.
#'
#' Throughput time is measured from the first event timestamp to the last within
#' each case.
#'
#' @param log A validated processmine tibble.
#' @param unit Time unit for the result. One of `"seconds"`, `"minutes"`,
#'   `"hours"` (default), `"days"`, `"weeks"`.
#' @return A tibble with columns `case_id`, `throughput`, `unit`.
#' @export
performance_throughput <- function(log, unit = "hours") {
  validate_eventlog(log)
  if (!unit %in% .time_units) {
    rlang::abort(paste0(
      "Unknown unit '", unit, "'. Must be one of: ",
      paste(.time_units, collapse = ", "), "."
    ))
  }

  log_sorted <- log[order(log$case_id, log$timestamp), ]
  cases      <- split(log_sorted, log_sorted$case_id)
  secs_per   <- .unit_secs[[unit]]

  durations <- vapply(cases, function(cl) {
    as.numeric(difftime(max(cl$timestamp), min(cl$timestamp), units = "secs")) /
      secs_per
  }, numeric(1))

  tibble::tibble(
    case_id    = names(durations),
    throughput = unname(durations),
    unit       = unit
  )
}

# ---- performance_bottlenecks -------------------------------------------------

#' Identify transition bottlenecks by mean waiting time.
#'
#' For each directly-follows edge `(A, B)`, computes the mean elapsed time
#' between the timestamp of activity A and the timestamp of activity B, across
#' all occurrences in the log. Returns edges sorted from slowest to fastest.
#'
#' @param log A validated processmine tibble.
#' @param method Currently only `"handover"` is supported (inter-event elapsed
#'   time). Reserved for future `"waiting"` (requires `start_timestamp`).
#' @return A tibble with columns `from_activity`, `to_activity`,
#'   `mean_duration_s`, `n`.
#' @export
performance_bottlenecks <- function(log, method = "handover") {
  validate_eventlog(log)
  if (!method %in% c("handover", "waiting")) {
    rlang::abort("method must be 'handover' or 'waiting'.")
  }

  log_sorted <- log[order(log$case_id, log$timestamp), ]
  cases      <- split(log_sorted, log_sorted$case_id)

  trans_list <- lapply(cases, function(cl) {
    n <- nrow(cl)
    if (n < 2L) return(NULL)
    data.frame(
      from_activity = cl$activity[-n],
      to_activity   = cl$activity[-1L],
      duration_s    = as.numeric(
        difftime(cl$timestamp[-1L], cl$timestamp[-n], units = "secs")
      ),
      stringsAsFactors = FALSE
    )
  })

  transitions <- do.call(rbind, Filter(Negate(is.null), trans_list))

  if (is.null(transitions) || nrow(transitions) == 0L) {
    return(tibble::tibble(
      from_activity   = character(0),
      to_activity     = character(0),
      mean_duration_s = numeric(0),
      n               = integer(0)
    ))
  }

  key    <- paste(transitions$from_activity, transitions$to_activity, sep = "\r")
  ukeys  <- unique(key)
  result <- do.call(rbind, lapply(ukeys, function(k) {
    rows  <- transitions[key == k, ]
    parts <- strsplit(k, "\r", fixed = TRUE)[[1]]
    data.frame(
      from_activity   = parts[1L],
      to_activity     = parts[2L],
      mean_duration_s = mean(rows$duration_s),
      n               = nrow(rows),
      stringsAsFactors = FALSE
    )
  }))

  result <- result[order(-result$mean_duration_s), ]
  tibble::as_tibble(result)
}

# ---- performance_sla ---------------------------------------------------------

#' Check SLA compliance for each case.
#'
#' Compares per-case throughput time against a user-supplied limit. Returns a
#' tibble flagging which cases are within the SLA.
#'
#' @param log A validated processmine tibble.
#' @param sla_spec A named list with:
#'   * `limit`: numeric maximum throughput (required)
#'   * `unit`: time unit string (default `"hours"`); passed to
#'     [performance_throughput()]
#' @return A tibble with columns `case_id`, `throughput`, `unit`,
#'   `within_sla`, `sla_limit`.
#' @export
performance_sla <- function(log, sla_spec) {
  if (!is.list(sla_spec) || is.null(sla_spec$limit)) {
    rlang::abort("sla_spec must be a list with at least a 'limit' element.")
  }
  if (!is.numeric(sla_spec$limit) || length(sla_spec$limit) != 1L) {
    rlang::abort("sla_spec$limit must be a single numeric value.")
  }

  unit <- if (!is.null(sla_spec$unit)) sla_spec$unit else "hours"
  tp   <- performance_throughput(log, unit = unit)

  tibble::tibble(
    case_id    = tp$case_id,
    throughput = tp$throughput,
    unit       = tp$unit,
    within_sla = tp$throughput <= sla_spec$limit,
    sla_limit  = sla_spec$limit
  )
}
