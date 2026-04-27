"""processmine_ml/anomaly.py — Case-level anomaly detection via Isolation Forest."""

from __future__ import annotations

from typing import Optional

import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest  # type: ignore[import-untyped]

from processmine_ml.io import validate_eventlog

__all__ = ["extract_case_features", "detect_anomalies"]


# ---- extract_case_features ---------------------------------------------------

def extract_case_features(df: pd.DataFrame) -> pd.DataFrame:
    """Compute case-level features from an event log.

    Each row in the output corresponds to one case. Features are derived purely
    from the event log schema — no domain knowledge required.

    Features:
    - ``throughput_s``: elapsed seconds from first to last event in the case.
    - ``n_events``: total number of events.
    - ``n_unique_activities``: count of distinct activity values.
    - ``n_unique_resources``: count of distinct resource values (0 if no
      ``resource`` column present).
    - ``resource_entropy``: Shannon entropy (bits) of the resource distribution
      within the case (0 if no ``resource`` column present).

    Args:
        df: A validated processmine event log DataFrame.

    Returns:
        A DataFrame indexed by ``case_id`` with one row per case and one column
        per feature.
    """
    validate_eventlog(df)

    has_resource = "resource" in df.columns

    groups = df.sort_values("timestamp").groupby("case_id", sort=False)

    records = []
    for case_id, grp in groups:
        throughput_s = (grp["timestamp"].max() - grp["timestamp"].min()).total_seconds()
        n_events = len(grp)
        n_unique_activities = grp["activity"].nunique()

        if has_resource:
            res = grp["resource"].dropna()
            n_unique_resources = res.nunique()
            counts = res.value_counts(normalize=True)
            resource_entropy = float(-(counts * np.log2(counts + 1e-12)).sum())
        else:
            n_unique_resources = 0
            resource_entropy = 0.0

        records.append({
            "case_id":             case_id,
            "throughput_s":        throughput_s,
            "n_events":            n_events,
            "n_unique_activities": n_unique_activities,
            "n_unique_resources":  n_unique_resources,
            "resource_entropy":    resource_entropy,
        })

    return pd.DataFrame(records).set_index("case_id")


# ---- detect_anomalies --------------------------------------------------------

_FEATURE_COLS = [
    "throughput_s",
    "n_events",
    "n_unique_activities",
    "n_unique_resources",
    "resource_entropy",
]


def detect_anomalies(
    df: pd.DataFrame,
    contamination: float = 0.05,
    random_state: int = 42,
    features: Optional[list[str]] = None,
) -> pd.DataFrame:
    """Detect anomalous cases using an Isolation Forest.

    Trains an Isolation Forest on case-level features extracted from *df* and
    returns one row per case with an anomaly score and a boolean flag.

    The anomaly score is the raw ``decision_function`` output from
    ``IsolationForest``: higher values mean *more normal*, lower (negative)
    values mean *more anomalous*. The ``is_anomaly`` flag is ``True`` for the
    fraction of cases indicated by *contamination*.

    Args:
        df: A validated processmine event log DataFrame.
        contamination: Expected fraction of anomalies in the dataset. Passed
            directly to ``IsolationForest``. Default ``0.05``.
        random_state: Random seed for reproducibility. Default ``42``.
        features: Optional list of feature column names to use. Must be a
            subset of the columns produced by :func:`extract_case_features`.
            Defaults to all five features.

    Returns:
        A DataFrame with columns ``case_id``, all feature columns,
        ``anomaly_score`` (float, higher = more normal), and ``is_anomaly``
        (bool). Sorted by ``anomaly_score`` ascending (most anomalous first).

    Raises:
        ValueError: If *contamination* is not in ``(0, 0.5]``, or if any
            element of *features* is not a valid feature column.
    """
    if not (0 < contamination <= 0.5):
        raise ValueError(
            f"contamination must be in (0, 0.5], got {contamination!r}."
        )

    feat_df = extract_case_features(df)

    use_cols = features if features is not None else _FEATURE_COLS
    unknown = [c for c in use_cols if c not in feat_df.columns]
    if unknown:
        raise ValueError(
            f"Unknown feature column(s): {unknown}. "
            f"Valid columns: {list(feat_df.columns)}"
        )

    X = feat_df[use_cols].to_numpy(dtype=float)

    clf = IsolationForest(contamination=contamination, random_state=random_state)
    clf.fit(X)

    scores  = clf.decision_function(X)
    is_anom = clf.predict(X) == -1

    result = feat_df.reset_index().copy()
    result["anomaly_score"] = scores
    result["is_anomaly"]    = is_anom

    return result.sort_values("anomaly_score").reset_index(drop=True)
