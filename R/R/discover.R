#' @importFrom tibble as_tibble tibble
#' @importFrom rlang abort
NULL

# ---- discover_dfg ------------------------------------------------------------

#' Discover a Directly-Follows Graph from an event log.
#'
#' Counts how many times activity B directly follows activity A within the same
#' case. Returns a `processmine_dfg` object.
#'
#' @param log A validated processmine tibble.
#' @param noise_threshold Minimum edge frequency (relative to total events) to
#'   retain. Edges below the threshold are dropped. Default `0` keeps all edges.
#' @return A `processmine_dfg` list with elements:
#'   * `$edges`: tibble of `from`, `to`, `n`, `freq`
#'   * `$activities`: sorted character vector of all activities
#'   * `$start_activities`: first activity of each case
#'   * `$end_activities`: last activity of each case
#' @export
discover_dfg <- function(log, noise_threshold = 0) {
  validate_eventlog(log)

  log <- log[order(log$case_id, log$timestamp), ]
  cases <- split(log, log$case_id)

  edges_list <- lapply(cases, function(cl) {
    acts <- cl$activity
    if (length(acts) < 2L) return(NULL)
    data.frame(from = acts[-length(acts)], to = acts[-1L],
               stringsAsFactors = FALSE)
  })
  edges_raw <- do.call(rbind, Filter(Negate(is.null), edges_list))

  if (is.null(edges_raw) || nrow(edges_raw) == 0L) {
    return(.empty_dfg())
  }

  # Aggregate counts
  key   <- paste(edges_raw$from, edges_raw$to, sep = "\r")
  counts <- tabulate(match(key, unique(key)))
  ukeys  <- unique(key)
  parts  <- strsplit(ukeys, "\r", fixed = TRUE)

  edges <- tibble::tibble(
    from = vapply(parts, `[[`, character(1), 1L),
    to   = vapply(parts, `[[`, character(1), 2L),
    n    = as.integer(counts),
    freq = counts / nrow(log)
  )

  if (noise_threshold > 0) {
    edges <- edges[edges$freq >= noise_threshold, ]
  }
  edges <- edges[order(edges$from, edges$to), ]

  start_acts <- vapply(cases, function(cl) cl$activity[1L],            character(1))
  end_acts   <- vapply(cases, function(cl) cl$activity[nrow(cl)],       character(1))

  structure(
    list(
      edges            = edges,
      activities       = sort(unique(log$activity)),
      start_activities = sort(unique(start_acts)),
      end_activities   = sort(unique(end_acts))
    ),
    class = "processmine_dfg"
  )
}

.empty_dfg <- function() {
  structure(
    list(
      edges = tibble::tibble(
        from = character(0), to = character(0),
        n    = integer(0),   freq = numeric(0)
      ),
      activities       = character(0),
      start_activities = character(0),
      end_activities   = character(0)
    ),
    class = "processmine_dfg"
  )
}

# ---- discover_heuristics -----------------------------------------------------

#' Discover a heuristics net from an event log.
#'
#' Builds a Directly-Follows Graph and filters edges using the dependency
#' measure `dep(A,B) = (|A->B| - |B->A|) / (|A->B| + |B->A| + 1)`.
#' Only edges with `dep >= dependency_threshold` are retained.
#'
#' @param log A validated processmine tibble.
#' @param dependency_threshold Minimum dependency measure to retain an edge.
#'   Must be in `[0, 1)`. Default `0.9`.
#' @return A `processmine_hnet` list with elements:
#'   * `$edges`: tibble of `from`, `to`, `n`, `freq`, `dependency`
#'   * `$activities`, `$start_activities`, `$end_activities`
#'   * `$dependency_threshold`: the value used for filtering
#' @export
discover_heuristics <- function(log, dependency_threshold = 0.9) {
  if (!is.numeric(dependency_threshold) || dependency_threshold < 0 ||
      dependency_threshold >= 1) {
    rlang::abort("dependency_threshold must be numeric in [0, 1).")
  }

  dfg   <- discover_dfg(log)
  edges <- dfg$edges

  if (nrow(edges) == 0L) {
    return(structure(
      list(
        edges                = edges,
        activities           = dfg$activities,
        start_activities     = dfg$start_activities,
        end_activities       = dfg$end_activities,
        dependency_threshold = dependency_threshold
      ),
      class = "processmine_hnet"
    ))
  }

  # Build a lookup of n by (from, to) key for fast reverse-edge lookup
  edge_key <- paste(edges$from, edges$to, sep = "\r")
  edge_n   <- stats::setNames(edges$n, edge_key)

  dep <- vapply(seq_len(nrow(edges)), function(i) {
    ab  <- edges$n[i]
    rev <- paste(edges$to[i], edges$from[i], sep = "\r")
    ba  <- if (rev %in% names(edge_n)) edge_n[[rev]] else 0L
    (ab - ba) / (ab + ba + 1)
  }, numeric(1))

  edges$dependency <- dep
  edges <- edges[edges$dependency >= dependency_threshold, ]
  edges <- edges[order(edges$from, edges$to), ]

  structure(
    list(
      edges                = edges,
      activities           = dfg$activities,
      start_activities     = dfg$start_activities,
      end_activities       = dfg$end_activities,
      dependency_threshold = dependency_threshold
    ),
    class = "processmine_hnet"
  )
}
