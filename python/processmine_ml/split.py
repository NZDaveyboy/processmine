"""Case-level train/test splitting for event logs."""

from __future__ import annotations

import numpy as np
import pandas as pd


def train_test_split_by_case(
    df: pd.DataFrame,
    test_size: float = 0.2,
    random_state: int = 42,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Split an event log into train and test sets by case.

    Splits unique case IDs so that no case appears in both sets. All events
    belonging to a case stay together.

    Parameters
    ----------
    df:
        Validated processmine event log.
    test_size:
        Proportion of cases to place in the test set (0 < test_size < 1).
    random_state:
        Random seed for reproducibility.

    Returns
    -------
    tuple[pd.DataFrame, pd.DataFrame]
        (train_df, test_df) with the same columns as the input.
    """
    if not (0 < test_size < 1):
        raise ValueError(f"test_size must be between 0 and 1, got {test_size}")

    case_ids = np.array(sorted(df["case_id"].unique()))
    rng = np.random.default_rng(random_state)
    rng.shuffle(case_ids)

    n_test = max(1, round(len(case_ids) * test_size))
    test_ids = set(case_ids[:n_test])
    train_ids = set(case_ids[n_test:])

    train_df = df[df["case_id"].isin(train_ids)].copy()
    test_df = df[df["case_id"].isin(test_ids)].copy()

    return train_df, test_df
