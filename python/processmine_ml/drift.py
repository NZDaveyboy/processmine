"""processmine_ml/drift.py — Concept drift detection using ADWIN."""

from __future__ import annotations

from typing import Union

import pandas as pd
from river import drift as river_drift  # type: ignore[import-untyped]

from processmine_ml.io import validate_eventlog

__all__ = ["extract_case_stream", "detect_drift"]

# Metrics that operate on a scalar derived per case
_SCALAR_METRICS = ("throughput", "n_events", "n_unique_activities")


# ---- extract_case_stream -----------------------------------------------------

def extract_case_stream(df: pd.DataFrame) -> pd.DataFrame:
    """Build a time-ordered stream of per-case scalar metrics.

    Each row is one case, ordered by the case's first-event timestamp. This is
    the input stream that drift detectors consume.

    Columns returned:
    - ``case_id``
    - ``case_start``: timestamp of the case's first event
    - ``throughput``: elapsed seconds from first to last event
    - ``n_events``: total number of events
    - ``n_unique_activities``: count of distinct activities

    Args:
        df: A validated processmine event log DataFrame.

    Returns:
        DataFrame with one row per case, sorted by ``case_start`` ascending.
    """
    validate_eventlog(df)

    groups = df.sort_values("timestamp").groupby("case_id", sort=False)
    records = []
    for case_id, grp in groups:
        first = grp["timestamp"].min()
        last  = grp["timestamp"].max()
        records.append({
            "case_id":             case_id,
            "case_start":          first,
            "throughput":          (last - first).total_seconds(),
            "n_events":            len(grp),
            "n_unique_activities": grp["activity"].nunique(),
        })

    result = pd.DataFrame(records)
    return result.sort_values("case_start").reset_index(drop=True)


# ---- detect_drift ------------------------------------------------------------

def detect_drift(
    df: pd.DataFrame,
    metric: Union[str, None] = "throughput",
    delta: float = 0.002,
) -> pd.DataFrame:
    """Detect concept drift in a process metric stream using ADWIN.

    Iterates over cases in chronological order and feeds the chosen metric into
    an ADWIN detector. ADWIN (ADaptive WINdowing) maintains a variable-size
    sliding window and signals a change point when the means of two sub-windows
    differ by more than a statistically significant amount.

    Supported metrics:

    - ``"throughput"``: case throughput time in seconds.
    - ``"n_events"``: number of events per case.
    - ``"n_unique_activities"``: distinct activity count per case.
    - ``"activity:<name>"``: binary stream — ``1.0`` if the case contains the
      named activity, ``0.0`` otherwise. Example: ``"activity:Approve Order"``.

    Args:
        df: A validated processmine event log DataFrame.
        metric: Metric to monitor. Default ``"throughput"``.
        delta: ADWIN sensitivity parameter. Smaller values mean fewer false
            positives but slower detection. Default ``0.002``.

    Returns:
        A DataFrame with columns ``case_id``, ``case_start``, the metric
        column, and ``drift_detected`` (bool — ``True`` at each change point).
        Rows are ordered chronologically.

    Raises:
        ValueError: If *metric* is not recognised or if an ``"activity:<name>"``
            metric names an activity not present in the log.
    """
    if delta <= 0:
        raise ValueError(f"delta must be positive, got {delta!r}.")

    validate_eventlog(df)
    stream = extract_case_stream(df)

    activity_name: str | None = None
    if metric is not None and metric.startswith("activity:"):
        activity_name = metric[len("activity:"):]
        known = set(df["activity"].unique())
        if activity_name not in known:
            raise ValueError(
                f"Activity {activity_name!r} not found in the log. "
                f"Known activities: {sorted(known)}"
            )
        metric_col = metric  # used as column label in output
    elif metric not in _SCALAR_METRICS:
        raise ValueError(
            f"Unknown metric {metric!r}. "
            f"Supported: {list(_SCALAR_METRICS)} or 'activity:<name>'."
        )
    else:
        metric_col = metric

    detector = river_drift.ADWIN(delta=delta)

    # For activity metrics we need the per-case activity presence lookup
    if activity_name is not None:
        cases_with_act = set(
            df.loc[df["activity"] == activity_name, "case_id"].unique()
        )
        values = stream["case_id"].map(
            lambda cid: 1.0 if cid in cases_with_act else 0.0
        ).tolist()
    else:
        values = stream[metric].tolist()  # type: ignore[index]

    drift_flags = []
    for val in values:
        detector.update(val)
        drift_flags.append(detector.drift_detected)

    result = stream[["case_id", "case_start"]].copy()
    result[metric_col] = values
    result["drift_detected"] = drift_flags
    return result.reset_index(drop=True)
