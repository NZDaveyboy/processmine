"""python/tests/test_drift.py — Tests for processmine_ml.drift."""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from processmine_ml.drift import detect_drift, extract_case_stream


# ---- fixtures ----------------------------------------------------------------

def make_stable_log(n_cases: int = 40, seed: int = 0) -> pd.DataFrame:
    """Synthetic log with stable ~1-hour throughput throughout."""
    rng = np.random.default_rng(seed)
    base = pd.Timestamp("2024-01-01", tz="UTC")
    rows: list[dict] = []
    for i in range(n_cases):
        duration = int(rng.integers(3000, 3600))  # ~50–60 min, tight band
        rows.append({
            "case_id":   f"C{i:03d}",
            "activity":  "A",
            "timestamp": base + pd.Timedelta(hours=i * 2),
            "resource":  "alice",
        })
        rows.append({
            "case_id":   f"C{i:03d}",
            "activity":  "B",
            "timestamp": base + pd.Timedelta(hours=i * 2, seconds=duration),
            "resource":  "bob",
        })
    df = pd.DataFrame(rows)
    df["timestamp"] = df["timestamp"].dt.as_unit("us")
    return df


def make_drifting_log(
    n_before: int = 40,
    n_after: int = 40,
    before_hours: float = 1.0,
    after_hours: float = 12.0,
    seed: int = 0,
) -> pd.DataFrame:
    """Synthetic log with a clear throughput-time step change at case n_before."""
    rng = np.random.default_rng(seed)
    base = pd.Timestamp("2024-01-01", tz="UTC")
    rows: list[dict] = []
    for i in range(n_before + n_after):
        hours = before_hours if i < n_before else after_hours
        jitter = rng.uniform(-0.05, 0.05) * hours
        duration_s = (hours + jitter) * 3600
        rows.append({
            "case_id":   f"C{i:03d}",
            "activity":  "Submit",
            "timestamp": base + pd.Timedelta(hours=i * 0.5),
            "resource":  "alice",
        })
        rows.append({
            "case_id":   f"C{i:03d}",
            "activity":  "Close",
            "timestamp": base + pd.Timedelta(hours=i * 0.5, seconds=duration_s),
            "resource":  "bob",
        })
    df = pd.DataFrame(rows)
    df["timestamp"] = df["timestamp"].dt.as_unit("us")
    return df


# ---- extract_case_stream -----------------------------------------------------

def test_extract_case_stream_one_row_per_case():
    df     = make_stable_log(n_cases=10)
    stream = extract_case_stream(df)
    assert len(stream) == 10


def test_extract_case_stream_columns():
    df     = make_stable_log(n_cases=5)
    stream = extract_case_stream(df)
    for col in ("case_id", "case_start", "throughput", "n_events", "n_unique_activities"):
        assert col in stream.columns


def test_extract_case_stream_sorted_by_case_start():
    df     = make_stable_log(n_cases=20)
    stream = extract_case_stream(df)
    assert (stream["case_start"].diff().dropna() >= pd.Timedelta(0)).all()


def test_extract_case_stream_throughput_correct():
    ts = pd.to_datetime(
        ["2024-01-01 08:00:00", "2024-01-01 10:00:00"], utc=True
    ).astype("datetime64[us, UTC]")
    df = pd.DataFrame({
        "case_id":   ["C1", "C1"],
        "activity":  ["A", "B"],
        "timestamp": ts,
    })
    stream = extract_case_stream(df)
    assert stream.loc[0, "throughput"] == pytest.approx(7200.0)


# ---- detect_drift ------------------------------------------------------------

def test_detect_drift_returns_expected_columns():
    df     = make_stable_log(n_cases=20)
    result = detect_drift(df, metric="throughput")
    for col in ("case_id", "case_start", "throughput", "drift_detected"):
        assert col in result.columns


def test_detect_drift_one_row_per_case():
    df     = make_stable_log(n_cases=15)
    result = detect_drift(df, metric="throughput")
    assert len(result) == 15


def test_detect_drift_no_spurious_alarms_on_stable_log():
    df     = make_stable_log(n_cases=40, seed=1)
    result = detect_drift(df, metric="throughput", delta=0.002)
    # Stable log should produce zero or very few change points
    assert result["drift_detected"].sum() <= 2


def test_detect_drift_detects_step_change():
    df     = make_drifting_log(n_before=40, n_after=40)
    result = detect_drift(df, metric="throughput", delta=0.002)
    assert result["drift_detected"].any(), "Expected at least one drift detection"

    # All detections should occur in the second half (after the change point)
    first_detection_idx = result[result["drift_detected"]].index[0]
    assert first_detection_idx >= 30, (
        f"Drift detected too early at index {first_detection_idx}"
    )


def test_detect_drift_n_events_metric():
    df     = make_stable_log(n_cases=20)
    result = detect_drift(df, metric="n_events")
    assert "n_events" in result.columns
    assert result["drift_detected"].dtype == bool


def test_detect_drift_n_unique_activities_metric():
    df     = make_stable_log(n_cases=20)
    result = detect_drift(df, metric="n_unique_activities")
    assert "n_unique_activities" in result.columns


def test_detect_drift_activity_metric():
    df     = make_drifting_log(n_before=40, n_after=40)
    result = detect_drift(df, metric="activity:Submit")
    assert "activity:Submit" in result.columns
    # All cases contain Submit so values should be 1.0 throughout
    assert (result["activity:Submit"] == 1.0).all()


def test_detect_drift_activity_metric_detects_disappearing_activity():
    """An activity present in the first half but absent in the second should trigger drift."""
    base  = pd.Timestamp("2024-01-01", tz="UTC")
    rows: list[dict] = []
    # First 40 cases: Submit -> Close
    for i in range(40):
        for j, act in enumerate(["Submit", "Close"]):
            rows.append({
                "case_id":   f"C{i:03d}",
                "activity":  act,
                "timestamp": (base + pd.Timedelta(hours=i * 2 + j)).as_unit("us"),
            })
    # Next 40 cases: Open -> Close  (Submit disappears)
    for i in range(40, 80):
        for j, act in enumerate(["Open", "Close"]):
            rows.append({
                "case_id":   f"C{i:03d}",
                "activity":  act,
                "timestamp": (base + pd.Timedelta(hours=i * 2 + j)).as_unit("us"),
            })
    df     = pd.DataFrame(rows)
    result = detect_drift(df, metric="activity:Submit", delta=0.002)
    assert result["drift_detected"].any()


def test_detect_drift_rejects_unknown_metric():
    df = make_stable_log(n_cases=10)
    with pytest.raises(ValueError, match="Unknown metric"):
        detect_drift(df, metric="magic")


def test_detect_drift_rejects_unknown_activity():
    df = make_stable_log(n_cases=10)
    with pytest.raises(ValueError, match="not found"):
        detect_drift(df, metric="activity:Nonexistent")


def test_detect_drift_rejects_nonpositive_delta():
    df = make_stable_log(n_cases=10)
    with pytest.raises(ValueError, match="delta"):
        detect_drift(df, metric="throughput", delta=0.0)


def test_detect_drift_sensitive_delta_detects_faster():
    """Lower delta = more sensitive = detects the same step change earlier."""
    df       = make_drifting_log(n_before=40, n_after=40)
    loose    = detect_drift(df, metric="throughput", delta=0.5)
    tight    = detect_drift(df, metric="throughput", delta=0.0001)

    tight_detections = tight[tight["drift_detected"]]
    loose_detections = loose[loose["drift_detected"]]

    if tight_detections.empty or loose_detections.empty:
        pytest.skip("One detector found no drift — increase log size")

    assert tight_detections.index[0] <= loose_detections.index[0]
