#' @importFrom tibble as_tibble tibble
#' @importFrom rlang abort
NULL

# ---- variants ----------------------------------------------------------------

#' Extract all unique activity-sequence variants from an event log.
#'
#' A variant is the ordered sequence of activities for a single case, expressed
#' as a `"->"` separated string. Returns variants sorted from most to least
#' frequent.
#'
#' @param log A validated processmine tibble.
#' @return A tibble with columns `variant` (character), `n` (integer count),
#'   `freq` (fraction of cases).
#' @export
variants <- function(log) {
  validate_eventlog(log)

  log_sorted <- log[order(log$case_id, log$timestamp), ]
  cases      <- split(log_sorted, log_sorted$case_id)
  total      <- length(cases)

  seqs   <- vapply(cases, function(cl) paste(cl$activity, collapse = "->"), character(1))
  counts <- table(seqs)

  result <- tibble::tibble(
    variant = names(counts),
    n       = as.integer(counts),
    freq    = as.numeric(counts) / total
  )
  result[order(-result$n), ]
}

# ---- rare_paths --------------------------------------------------------------

#' Extract infrequent variants from an event log.
#'
#' Returns all variants whose relative frequency is strictly below
#' `min_support`. Useful for identifying noise, exceptions, or rework.
#'
#' @param log A validated processmine tibble.
#' @param min_support Minimum support threshold (fraction of cases). Variants
#'   with `freq < min_support` are returned. Default `0.01`.
#' @return A tibble with columns `variant`, `n`, `freq` (subset of
#'   [variants()] output).
#' @export
rare_paths <- function(log, min_support = 0.01) {
  if (!is.numeric(min_support) || length(min_support) != 1L ||
      min_support <= 0 || min_support > 1) {
    rlang::abort("min_support must be a single numeric value in (0, 1].")
  }

  v <- variants(log)
  v[v$freq < min_support, ]
}
