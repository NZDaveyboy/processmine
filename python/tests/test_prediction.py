"""python/tests/test_prediction.py — Tests for processmine_ml.prediction."""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

torch = pytest.importorskip("torch", reason="PyTorch not installed; skipping prediction tests")

from processmine_ml.prediction import NextActivityPredictor  # noqa: E402


# ---- fixtures ----------------------------------------------------------------

def make_deterministic_log(n_repeats: int = 50) -> pd.DataFrame:
    """Log where every case follows A -> B -> C, no variation."""
    base = pd.Timestamp("2024-01-01", tz="UTC")
    rows: list[dict] = []
    for i in range(n_repeats):
        for j, act in enumerate(["A", "B", "C"]):
            rows.append({
                "case_id":   f"C{i:03d}",
                "activity":  act,
                "timestamp": (base + pd.Timedelta(hours=i * 3 + j)).as_unit("us"),
            })
    return pd.DataFrame(rows)


def make_mixed_log(n_cases: int = 30, seed: int = 0) -> pd.DataFrame:
    """Log with two variants: A->B->C (70%) and A->D->C (30%)."""
    rng   = np.random.default_rng(seed)
    base  = pd.Timestamp("2024-01-01", tz="UTC")
    rows: list[dict] = []
    for i in range(n_cases):
        middle = "B" if rng.random() < 0.7 else "D"
        for j, act in enumerate(["A", middle, "C"]):
            rows.append({
                "case_id":   f"C{i:03d}",
                "activity":  act,
                "timestamp": (base + pd.Timedelta(hours=i * 3 + j)).as_unit("us"),
            })
    return pd.DataFrame(rows)


_SMALL_FIT_KWARGS = dict(
    epochs=5, hidden_size=8, num_layers=1, embedding_dim=4, batch_size=16
)


# ---- fit ---------------------------------------------------------------------

def test_fit_returns_self():
    log       = make_deterministic_log(n_repeats=5)
    predictor = NextActivityPredictor()
    result    = predictor.fit(log, **_SMALL_FIT_KWARGS)
    assert result is predictor


def test_fit_sets_fitted_flag():
    log = make_deterministic_log(n_repeats=5)
    p   = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    assert p._fitted


def test_fit_builds_vocabulary():
    log = make_deterministic_log(n_repeats=5)
    p   = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    assert set(p._act_to_idx.keys()) == {"A", "B", "C"}
    assert len(p._idx_to_act) == 3


def test_fit_chainable():
    log = make_deterministic_log(n_repeats=5)
    p   = NextActivityPredictor()
    assert isinstance(p.fit(log, **_SMALL_FIT_KWARGS), NextActivityPredictor)


def test_fit_rejects_single_event_cases_only():
    ts = pd.to_datetime(["2024-01-01 08:00:00"], utc=True).astype("datetime64[us, UTC]")
    df = pd.DataFrame({"case_id": ["C1"], "activity": ["A"], "timestamp": ts})
    with pytest.raises(ValueError, match="training pairs"):
        NextActivityPredictor().fit(df, **_SMALL_FIT_KWARGS)


# ---- predict -----------------------------------------------------------------

def test_predict_returns_dataframe():
    log  = make_deterministic_log(n_repeats=10)
    p    = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    pred = p.predict(["A"])
    assert isinstance(pred, pd.DataFrame)
    assert list(pred.columns) == ["activity", "probability"]


def test_predict_probabilities_sum_to_one():
    log  = make_deterministic_log(n_repeats=10)
    p    = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    pred = p.predict(["A"])
    assert pred["probability"].sum() == pytest.approx(1.0, abs=1e-5)


def test_predict_top_k_limits_rows():
    log  = make_mixed_log(n_cases=20)
    p    = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    pred = p.predict(["A"], top_k=2)
    assert len(pred) == 2


def test_predict_sorted_by_probability_descending():
    log  = make_mixed_log(n_cases=20)
    p    = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    pred = p.predict(["A"])
    assert (pred["probability"].diff().dropna() <= 0).all()


def test_predict_before_fit_raises():
    p = NextActivityPredictor()
    with pytest.raises(RuntimeError, match="fit"):
        p.predict(["A"])


def test_predict_unknown_activity_raises():
    log = make_deterministic_log(n_repeats=5)
    p   = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    with pytest.raises(ValueError, match="not seen during training"):
        p.predict(["UNKNOWN"])


# ---- evaluate ----------------------------------------------------------------

def test_evaluate_returns_expected_keys():
    log    = make_deterministic_log(n_repeats=10)
    p      = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    result = p.evaluate(log)
    assert set(result.keys()) == {"top1_accuracy", "top3_accuracy", "n_prefixes"}


def test_evaluate_accuracy_in_range():
    log    = make_deterministic_log(n_repeats=10)
    p      = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    result = p.evaluate(log)
    assert 0.0 <= result["top1_accuracy"] <= 1.0
    assert 0.0 <= result["top3_accuracy"] <= 1.0
    assert result["top3_accuracy"] >= result["top1_accuracy"]


def test_evaluate_before_fit_raises():
    log = make_deterministic_log(n_repeats=5)
    p   = NextActivityPredictor()
    with pytest.raises(RuntimeError, match="fit"):
        p.evaluate(log)


def test_evaluate_counts_correct_prefixes():
    log    = make_deterministic_log(n_repeats=5)
    p      = NextActivityPredictor().fit(log, **_SMALL_FIT_KWARGS)
    result = p.evaluate(log)
    # 5 cases × 2 prefixes each (A→B and A,B→C)
    assert result["n_prefixes"] == 10.0


def test_deterministic_log_learns_high_accuracy():
    """With a perfectly predictable sequence and enough training, top-1 > 80%."""
    log = make_deterministic_log(n_repeats=60)
    p   = NextActivityPredictor().fit(
        log, epochs=30, hidden_size=16, num_layers=1, embedding_dim=8, batch_size=32
    )
    result = p.evaluate(log)
    assert result["top1_accuracy"] > 0.8, (
        f"Expected top-1 accuracy > 0.8 on deterministic log, got {result['top1_accuracy']:.3f}"
    )


# ---- reproducibility ---------------------------------------------------------

def test_fit_predict_reproducible():
    log = make_mixed_log(n_cases=20)
    p1  = NextActivityPredictor().fit(log, random_state=7, **_SMALL_FIT_KWARGS)
    p2  = NextActivityPredictor().fit(log, random_state=7, **_SMALL_FIT_KWARGS)
    pd.testing.assert_frame_equal(p1.predict(["A"]), p2.predict(["A"]))
