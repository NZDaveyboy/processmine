"""Tests for train_test_split_by_case."""

import pandas as pd
import pytest

from processmine_ml.split import train_test_split_by_case


def _make_log(n_cases: int = 10, events_per_case: int = 3) -> pd.DataFrame:
    rows = []
    base = pd.Timestamp("2024-01-01", tz="UTC")
    for i in range(n_cases):
        for j in range(events_per_case):
            rows.append(
                {
                    "case_id": f"C{i:03d}",
                    "activity": f"A{j}",
                    "timestamp": base + pd.Timedelta(hours=i * 10 + j),
                }
            )
    df = pd.DataFrame(rows)
    df["timestamp"] = df["timestamp"].dt.as_unit("us")
    return df


def test_split_sizes_default():
    log = _make_log(10)
    train, test = train_test_split_by_case(log, test_size=0.2, random_state=42)
    total_cases = log["case_id"].nunique()
    assert test["case_id"].nunique() + train["case_id"].nunique() == total_cases


def test_no_overlap():
    log = _make_log(20)
    train, test = train_test_split_by_case(log, test_size=0.3, random_state=0)
    overlap = set(train["case_id"]) & set(test["case_id"])
    assert len(overlap) == 0


def test_all_events_stay_together():
    log = _make_log(10)
    train, test = train_test_split_by_case(log)
    for case_id in test["case_id"].unique():
        assert case_id not in train["case_id"].values


def test_reproducible():
    log = _make_log(20)
    train1, test1 = train_test_split_by_case(log, random_state=7)
    train2, test2 = train_test_split_by_case(log, random_state=7)
    assert set(test1["case_id"]) == set(test2["case_id"])


def test_different_seeds_differ():
    log = _make_log(20)
    _, test1 = train_test_split_by_case(log, random_state=1)
    _, test2 = train_test_split_by_case(log, random_state=2)
    assert set(test1["case_id"]) != set(test2["case_id"])


def test_invalid_test_size():
    log = _make_log(10)
    with pytest.raises(ValueError):
        train_test_split_by_case(log, test_size=0.0)
    with pytest.raises(ValueError):
        train_test_split_by_case(log, test_size=1.0)


def test_columns_preserved():
    log = _make_log(10)
    train, test = train_test_split_by_case(log)
    assert list(train.columns) == list(log.columns)
    assert list(test.columns) == list(log.columns)
