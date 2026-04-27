#' @importFrom tibble as_tibble tibble
#' @importFrom rlang abort
NULL

# ---- conformance_tokenreplay -------------------------------------------------

#' Measure conformance via token replay against a process model.
#'
#' For each case, replays the activity sequence against the allowed transitions
#' of a `processmine_dfg` or `processmine_hnet`. A transition `A -> B` is
#' *fitting* if the edge `(A, B)` exists in the model. Per-case fitness is the
#' fraction of transitions that are fitting.
#'
#' @param log A validated processmine tibble.
#' @param model A `processmine_dfg` (from [discover_dfg()]) or
#'   `processmine_hnet` (from [discover_heuristics()]).
#' @return A `processmine_conformance` list with:
#'   * `$summary`: list with `mean_fitness`, `median_fitness`, `n_cases`,
#'     `n_fitting_cases` (fitness == 1.0)
#'   * `$per_case`: tibble with `case_id`, `transitions`, `fitting`, `fitness`
#'   * `$diagnostics`: list with `model_type`, `allowed_transitions`
#' @export
conformance_tokenreplay <- function(log, model) {
  validate_eventlog(log)

  if (inherits(model, "processmine_dfg") || inherits(model, "processmine_hnet")) {
    allowed <- paste(model$edges$from, model$edges$to, sep = "->")
  } else {
    rlang::abort(
      "model must be a processmine_dfg or processmine_hnet.",
      call = NULL
    )
  }

  log_sorted <- log[order(log$case_id, log$timestamp), ]
  cases      <- split(log_sorted, log_sorted$case_id)

  per_case_list <- lapply(names(cases), function(cid) {
    acts <- cases[[cid]]$activity
    if (length(acts) < 2L) {
      return(data.frame(
        case_id     = cid,
        transitions = 0L,
        fitting     = 0L,
        fitness     = NA_real_,
        stringsAsFactors = FALSE
      ))
    }
    trans  <- paste(acts[-length(acts)], acts[-1L], sep = "->")
    n_fit  <- sum(trans %in% allowed)
    data.frame(
      case_id     = cid,
      transitions = length(trans),
      fitting     = n_fit,
      fitness     = n_fit / length(trans),
      stringsAsFactors = FALSE
    )
  })

  per_case <- tibble::as_tibble(do.call(rbind, per_case_list))
  valid    <- !is.na(per_case$fitness)

  summary_stats <- list(
    mean_fitness     = mean(per_case$fitness[valid]),
    median_fitness   = stats::median(per_case$fitness[valid]),
    n_cases          = nrow(per_case),
    n_fitting_cases  = sum(per_case$fitness[valid] >= 1.0, na.rm = TRUE)
  )

  structure(
    list(
      summary     = summary_stats,
      per_case    = per_case,
      diagnostics = list(
        model_type           = class(model)[1L],
        allowed_transitions  = length(allowed)
      )
    ),
    class = "processmine_conformance"
  )
}
