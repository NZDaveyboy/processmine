"""python/tests/test_anomaly.py — Tests for processmine_ml.anomaly."""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from processmine_ml.anomaly import detect_anomalies, extract_case_features


# ---- fixtures ----------------------------------------------------------------

def make_log(n_normal: int = 20, seed: int = 0) -> pd.DataFrame:
    """Synthetic log: n_normal happy-path cases + 1 obvious outlier."""
    rng = np.random.default_rng(seed)
    base = pd.Timestamp("2024-01-01", tz="UTC")
    rows: list[dict] = []

    for i in range(n_normal):
        case_id = f"C{i:03d}"
        n_events = int(rng.integers(3, 6))
        activities = rng.choice(["A", "B", "C"], size=n_events).tolist()
        resources  = rng.choice(["alice", "bob"], size=n_events).tolist()
        for j, (act, res) in enumerate(zip(activities, resources)):
            rows.append({
                "case_id":   case_id,
                "activity":  act,
                "timestamp": base + pd.Timedelta(hours=i * 24 + j),
                "resource":  res,
            })

    # Outlier: very long case with many unique activities and resources
    for j in range(30):
        rows.append({
            "case_id":   "OUTLIER",
            "activity":  f"ACT_{j}",
            "timestamp": base + pd.Timedelta(hours=n_normal * 24 + j * 10),
            "resource":  f"res_{j}",
        })

    df = pd.DataFrame(rows)
    df["timestamp"] = df["timestamp"].dt.as_unit("us")
    return df


# ---- extract_case_features ---------------------------------------------------

def test_extract_case_features_returns_one_row_per_case():
    df = make_log(n_normal=5)
    feat = extract_case_features(df)
    assert len(feat) == 6  # 5 normal + OUTLIER
    assert feat.index.name == "case_id"


def test_extract_case_features_columns():
    df = make_log(n_normal=5)
    feat = extract_case_features(df)
    expected = {
        "throughput_s", "n_events", "n_unique_activities",
        "n_unique_resources", "resource_entropy",
    }
    assert expected.issubset(set(feat.columns))


def test_extract_case_features_throughput_correct():
    ts = pd.to_datetime(["2024-01-01 08:00:00", "2024-01-01 10:00:00"], utc=True).astype("datetime64[us, UTC]")
    df = pd.DataFrame({
        "case_id":   ["C1", "C1"],
        "activity":  ["A", "B"],
        "timestamp": ts,
    })
    feat = extract_case_features(df)
    assert feat.loc["C1", "throughput_s"] == pytest.approx(7200.0)


def test_extract_case_features_no_resource_column():
    ts = pd.to_datetime(["2024-01-01 08:00:00", "2024-01-01 09:00:00"], utc=True).astype("datetime64[us, UTC]")
    df = pd.DataFrame({
        "case_id":   ["C1", "C1"],
        "activity":  ["A", "B"],
        "timestamp": ts,
    })
    feat = extract_case_features(df)
    assert feat.loc["C1", "n_unique_resources"] == 0
    assert feat.loc["C1", "resource_entropy"]   == 0.0


def test_extract_case_features_single_event_case():
    ts = pd.to_datetime(["2024-01-01 08:00:00"], utc=True).astype("datetime64[us, UTC]")
    df = pd.DataFrame({"case_id": ["C1"], "activity": ["A"], "timestamp": ts})
    feat = extract_case_features(df)
    assert feat.loc["C1", "throughput_s"]  == 0.0
    assert feat.loc["C1", "n_events"]      == 1


# ---- detect_anomalies --------------------------------------------------------

def test_detect_anomalies_returns_expected_columns():
    df   = make_log(n_normal=20)
    result = detect_anomalies(df, contamination=0.05)

    required = {"case_id", "throughput_s", "n_events", "n_unique_activities",
                "n_unique_resources", "resource_entropy",
                "anomaly_score", "is_anomaly"}
    assert required.issubset(set(result.columns))


def test_detect_anomalies_one_row_per_case():
    df     = make_log(n_normal=20)
    result = detect_anomalies(df)
    assert len(result) == len(df["case_id"].unique())


def test_detect_anomalies_sorted_by_score_ascending():
    df     = make_log(n_normal=20)
    result = detect_anomalies(df)
    assert (result["anomaly_score"].diff().dropna() >= 0).all()


def test_detect_anomalies_outlier_detected():
    df     = make_log(n_normal=20)
    result = detect_anomalies(df, contamination=0.1)
    outlier_row = result[result["case_id"] == "OUTLIER"]
    assert len(outlier_row) == 1
    assert bool(outlier_row["is_anomaly"].iloc[0])


def test_detect_anomalies_contamination_controls_flag_count():
    df = make_log(n_normal=40)
    n_cases = df["case_id"].nunique()

    for cont in (0.05, 0.10, 0.20):
        result = detect_anomalies(df, contamination=cont)
        n_flagged = result["is_anomaly"].sum()
        expected  = round(n_cases * cont)
        # sklearn may round slightly differently — allow ±1
        assert abs(n_flagged - expected) <= 1


def test_detect_anomalies_rejects_bad_contamination():
    df = make_log(n_normal=10)
    with pytest.raises(ValueError, match="contamination"):
        detect_anomalies(df, contamination=0.0)
    with pytest.raises(ValueError, match="contamination"):
        detect_anomalies(df, contamination=0.6)


def test_detect_anomalies_custom_features():
    df     = make_log(n_normal=20)
    result = detect_anomalies(df, features=["throughput_s", "n_events"])
    assert "anomaly_score" in result.columns


def test_detect_anomalies_rejects_unknown_feature():
    df = make_log(n_normal=10)
    with pytest.raises(ValueError, match="Unknown feature"):
        detect_anomalies(df, features=["throughput_s", "nonexistent"])


def test_detect_anomalies_reproducible():
    df = make_log(n_normal=20)
    r1 = detect_anomalies(df, random_state=7)
    r2 = detect_anomalies(df, random_state=7)
    pd.testing.assert_frame_equal(r1, r2)
