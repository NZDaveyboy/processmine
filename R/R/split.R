#' Split an event log into train and test sets by case
#'
#' Splits unique case IDs so that no case appears in both sets. All events
#' belonging to a case stay together.
#'
#' @param log A validated processmine event log tibble.
#' @param test_size Proportion of cases to place in the test set (0 < test_size < 1).
#' @param random_state Integer seed for reproducibility.
#'
#' @return A named list with elements `$train` and `$test`, each a tibble
#'   with the same columns as `log`.
#'
#' @export
train_test_split_by_case <- function(log, test_size = 0.2, random_state = 42L) {
  if (!is.numeric(test_size) || test_size <= 0 || test_size >= 1) {
    rlang::abort("`test_size` must be a number strictly between 0 and 1.")
  }

  case_ids <- sort(unique(log$case_id))
  set.seed(random_state)
  case_ids <- sample(case_ids)

  n_test  <- max(1L, round(length(case_ids) * test_size))
  test_ids  <- case_ids[seq_len(n_test)]
  train_ids <- case_ids[-seq_len(n_test)]

  list(
    train = log[log$case_id %in% train_ids, ],
    test  = log[log$case_id %in% test_ids, ]
  )
}
