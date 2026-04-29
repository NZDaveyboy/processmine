"""python/tests/test_align.py — Tests for processmine_ml.align (PM4Py optional)."""

from __future__ import annotations

import pandas as pd
import pytest

pm4py = pytest.importorskip("pm4py", reason="PM4Py not installed; skipping alignment tests")

from processmine_ml.align import conformance_alignments  # noqa: E402


# ---- fixtures ----------------------------------------------------------------

def make_simple_log() -> pd.DataFrame:
    """Three cases: 2 happy-path (A->B->C), 1 deviating (A->X->C)."""
    base = pd.Timestamp("2024-01-01", tz="UTC")
    rows = [
        {"case_id": "C1", "activity": "A", "timestamp": base},
        {"case_id": "C1", "activity": "B", "timestamp": base + pd.Timedelta(hours=1)},
        {"case_id": "C1", "activity": "C", "timestamp": base + pd.Timedelta(hours=2)},
        {"case_id": "C2", "activity": "A", "timestamp": base + pd.Timedelta(hours=3)},
        {"case_id": "C2", "activity": "B", "timestamp": base + pd.Timedelta(hours=4)},
        {"case_id": "C2", "activity": "C", "timestamp": base + pd.Timedelta(hours=5)},
        {"case_id": "C3", "activity": "A", "timestamp": base + pd.Timedelta(hours=6)},
        {"case_id": "C3", "activity": "X", "timestamp": base + pd.Timedelta(hours=7)},
        {"case_id": "C3", "activity": "C", "timestamp": base + pd.Timedelta(hours=8)},
    ]
    df = pd.DataFrame(rows)
    df["timestamp"] = df["timestamp"].dt.as_unit("us")
    return df


# ---- tests -------------------------------------------------------------------

def test_conformance_alignments_returns_dataframe():
    df     = make_simple_log()
    result = conformance_alignments(df)
    assert isinstance(result, pd.DataFrame)


def test_conformance_alignments_one_row_per_case():
    df     = make_simple_log()
    result = conformance_alignments(df)
    assert len(result) == df["case_id"].nunique()


def test_conformance_alignments_expected_columns():
    df     = make_simple_log()
    result = conformance_alignments(df)
    for col in ("case_id", "fitness", "cost", "is_fitting"):
        assert col in result.columns


def test_conformance_alignments_fitness_range():
    df     = make_simple_log()
    result = conformance_alignments(df)
    for fitness in result["fitness"].dropna():
        assert 0.0 <= fitness <= 1.0


def test_conformance_alignments_happy_path_perfect_fitness():
    """Cases C1 and C2 follow A->B->C exactly; model from C1+C2 should give fitness 1."""
    df = make_simple_log()

    # Discover model from happy-path cases only
    import pm4py
    from processmine_ml.align import _to_pm4py_df
    ref    = df[df["case_id"].isin(["C1", "C2"])]
    df_pm  = _to_pm4py_df(ref)
    net, im, fm = pm4py.discover_petri_net_inductive(df_pm)

    result  = conformance_alignments(df, model=(net, im, fm))
    c1 = result[result["case_id"] == "C1"]["fitness"].iloc[0]
    c2 = result[result["case_id"] == "C2"]["fitness"].iloc[0]

    assert c1 == pytest.approx(1.0, abs=0.01)
    assert c2 == pytest.approx(1.0, abs=0.01)


def test_conformance_alignments_deviating_case_lower_fitness():
    """C3 deviates from the A->B->C model; its fitness should be < 1."""
    df = make_simple_log()
    import pm4py
    from processmine_ml.align import _to_pm4py_df
    ref    = df[df["case_id"].isin(["C1", "C2"])]
    df_pm  = _to_pm4py_df(ref)
    net, im, fm = pm4py.discover_petri_net_inductive(df_pm)

    result = conformance_alignments(df, model=(net, im, fm))
    c3 = result[result["case_id"] == "C3"]["fitness"].iloc[0]

    assert c3 is not None
    assert c3 < 1.0


def test_conformance_alignments_is_fitting_flag():
    df     = make_simple_log()
    result = conformance_alignments(df)
    # is_fitting == (fitness == 1.0) where not None
    for _, row in result.dropna(subset=["fitness"]).iterrows():
        assert row["is_fitting"] == (row["fitness"] >= 1.0)


def test_conformance_alignments_rejects_invalid_log():
    df = pd.DataFrame({"case_id": ["C1"], "activity": ["A"]})
    with pytest.raises((ValueError, Exception)):
        conformance_alignments(df)
