"""processmine_ml/align.py — PM4Py alignment-based conformance (opt-in).

This module is an optional heavy dependency. Install PM4Py with:
    pip install 'processmine-ml[pm4py]'

Alignments are more precise than token replay but far slower. For logs with
more than ~10k cases, consider token replay (via R's conformance_tokenreplay)
or set a tight timeout_per_trace.
"""

from __future__ import annotations

from typing import Any, Optional

import pandas as pd

from processmine_ml.io import validate_eventlog

__all__ = ["conformance_alignments"]

# Columns PM4Py expects
_COL_CASE  = "case:concept:name"
_COL_ACT   = "concept:name"
_COL_TS    = "time:timestamp"


def _import_pm4py() -> Any:
    try:
        import pm4py  # type: ignore[import-untyped,import-not-found]
        return pm4py
    except ImportError as exc:
        raise ImportError(
            "PM4Py is required for alignment conformance. "
            "Install with: pip install 'processmine-ml[pm4py]'"
        ) from exc


def _to_pm4py_df(df: pd.DataFrame) -> pd.DataFrame:
    """Rename columns and strip timezone for PM4Py compatibility."""
    out = df[["case_id", "activity", "timestamp"]].copy()
    out = out.rename(columns={
        "case_id":   _COL_CASE,
        "activity":  _COL_ACT,
        "timestamp": _COL_TS,
    })
    # PM4Py 2.7.x is most stable with tz-naive timestamps
    ts_dtype = out[_COL_TS].dtype
    if isinstance(ts_dtype, pd.DatetimeTZDtype) and ts_dtype.tz is not None:
        out[_COL_TS] = out[_COL_TS].dt.tz_localize(None)
    return out.sort_values([_COL_CASE, _COL_TS])


def conformance_alignments(
    df: pd.DataFrame,
    timeout_per_trace: int = 30,
    model: Optional[tuple[Any, Any, Any]] = None,
) -> pd.DataFrame:
    """Compute alignment-based conformance fitness using PM4Py.

    For each case, an optimal alignment between the observed trace and the
    process model is computed. A fitness of ``1.0`` means the trace is fully
    explained by the model; ``0.0`` means every move was either a log-only or
    model-only move.

    If *model* is ``None``, the inductive miner is applied to *df* to discover
    a Petri net automatically.

    Args:
        df: A validated processmine event log DataFrame.
        timeout_per_trace: Per-trace alignment timeout in seconds. Traces that
            time out receive ``fitness=None`` and ``cost=None``. Default ``30``.
        model: Optional pre-discovered ``(net, initial_marking, final_marking)``
            tuple from PM4Py. Pass this to reuse a model across multiple calls.

    Returns:
        A DataFrame with columns ``case_id``, ``fitness`` (float or None),
        ``cost`` (int or None), ``is_fitting`` (bool or None, True when
        fitness == 1.0). One row per case, ordered as they appear in *df*.

    Raises:
        ImportError: If PM4Py is not installed.
        ValueError: If *df* fails schema validation.
    """
    pm4py = _import_pm4py()
    validate_eventlog(df)

    df_pm = _to_pm4py_df(df)

    if model is None:
        net, im, fm = pm4py.discover_petri_net_inductive(df_pm)
    else:
        net, im, fm = model

    diagnostics = pm4py.conformance_diagnostics_alignments(
        df_pm, net, im, fm,
        parameters={"timeout": timeout_per_trace},
    )

    # Case order is determined by the sorted df_pm
    case_order = list(df_pm[_COL_CASE].unique())

    records = []
    for case_id, diag in zip(case_order, diagnostics):
        fitness = diag.get("fitness")
        cost    = diag.get("cost")
        records.append({
            "case_id":    case_id,
            "fitness":    float(fitness) if fitness is not None else None,
            "cost":       int(cost)      if cost    is not None else None,
            "is_fitting": bool(fitness >= 1.0) if fitness is not None else None,
        })

    return pd.DataFrame(records)
