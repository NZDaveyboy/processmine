"""python/tests/test_io.py — Tests for processmine_ml.io."""

from __future__ import annotations

import pathlib

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
import pytest

from processmine_ml.io import (
    read_eventlog_parquet,
    read_xes,
    validate_eventlog,
    write_eventlog_parquet,
)

FIXTURES = pathlib.Path(__file__).parent.parent.parent / "R" / "tests" / "testthat" / "fixtures"


# ---- helpers ----------------------------------------------------------------

def make_minimal_df() -> pd.DataFrame:
    ts = pd.to_datetime(
        ["2024-01-01 08:00:00", "2024-01-01 09:00:00", "2024-01-02 08:00:00"],
        utc=True,
    ).astype("datetime64[us, UTC]")
    return pd.DataFrame({
        "case_id":   ["C1", "C1", "C2"],
        "activity":  ["A",  "B",  "A"],
        "timestamp": ts,
    })


def make_full_df() -> pd.DataFrame:
    ts = pd.to_datetime(
        ["2024-01-01 08:00:00", "2024-01-01 09:00:00", "2024-01-02 08:00:00"],
        utc=True,
    ).astype("datetime64[us, UTC]")
    st = pd.to_datetime(
        ["2024-01-01 07:50:00", "2024-01-01 08:55:00", "2024-01-02 07:45:00"],
        utc=True,
    ).astype("datetime64[us, UTC]")
    return pd.DataFrame({
        "case_id":         ["C1",       "C1",      "C2"],
        "activity":        ["A",        "B",       "A"],
        "timestamp":       ts,
        "start_timestamp": st,
        "resource":        ["alice",    "bob",     "alice"],
        "lifecycle":       ["complete", "complete","start"],
        "case_attrs":      [{"dept": "sales"}, {"dept": "sales"}, {"dept": "ops"}],
        "event_attrs":     [{"priority": "high"}, {}, {"priority": "low"}],
    })


# ---- validate_eventlog ------------------------------------------------------

def test_validate_eventlog_accepts_valid_minimal():
    df = make_minimal_df()
    result = validate_eventlog(df)
    assert result is df


def test_validate_eventlog_accepts_full_log():
    df = make_full_df()
    result = validate_eventlog(df)
    assert result is df


def test_validate_eventlog_rejects_missing_case_id():
    df = make_minimal_df().drop(columns=["case_id"])
    with pytest.raises(ValueError, match="case_id"):
        validate_eventlog(df)


def test_validate_eventlog_rejects_missing_activity():
    df = make_minimal_df().drop(columns=["activity"])
    with pytest.raises(ValueError, match="activity"):
        validate_eventlog(df)


def test_validate_eventlog_rejects_missing_timestamp():
    df = make_minimal_df().drop(columns=["timestamp"])
    with pytest.raises(ValueError, match="timestamp"):
        validate_eventlog(df)


def test_validate_eventlog_rejects_null_in_required():
    df = make_minimal_df().copy()
    df.loc[0, "case_id"] = None
    with pytest.raises(ValueError, match="[Nn]ull|[Nn][Aa]"):
        validate_eventlog(df)


def test_validate_eventlog_rejects_non_utc_timestamp():
    df = make_minimal_df().copy()
    df["timestamp"] = pd.to_datetime(
        ["2024-01-01 08:00:00", "2024-01-01 09:00:00", "2024-01-02 08:00:00"]
    ).tz_localize("America/New_York")
    with pytest.raises(ValueError, match="[Uu][Tt][Cc]"):
        validate_eventlog(df)


def test_validate_eventlog_rejects_timestamp_before_start():
    df = make_minimal_df().copy()
    # start_timestamp > timestamp
    df["start_timestamp"] = df["timestamp"] + pd.Timedelta(hours=1)
    with pytest.raises(ValueError, match="start_timestamp"):
        validate_eventlog(df)


def test_validate_eventlog_rejects_bad_lifecycle():
    df = make_minimal_df().copy()
    df["lifecycle"] = ["complete", "complete", "INVALID"]
    with pytest.raises(ValueError, match="lifecycle"):
        validate_eventlog(df)


# ---- read_xes ---------------------------------------------------------------

def test_read_xes_parses_fixture():
    path = FIXTURES / "tiny.xes"
    log = read_xes(path)

    assert isinstance(log, pd.DataFrame)
    assert len(log) == 5
    assert {"case_id", "activity", "timestamp"}.issubset(log.columns)
    assert str(log["timestamp"].dtype) == "datetime64[us, UTC]"


def test_read_xes_maps_keys_correctly():
    path = FIXTURES / "tiny.xes"
    log = read_xes(path)

    assert sorted(log["case_id"].unique()) == ["case-1", "case-2", "case-3"]
    assert sorted(log["activity"].unique()) == ["approve", "reject", "submit"]
    alice_row = log[(log["case_id"] == "case-1") & (log["activity"] == "submit")]
    assert alice_row["resource"].iloc[0] == "alice"


def test_read_xes_captures_case_attrs():
    path = FIXTURES / "tiny.xes"
    log = read_xes(path)

    assert "case_attrs" in log.columns
    case1 = log[log["case_id"] == "case-1"]["case_attrs"].iloc[0]
    assert case1.get("department") == "sales"


# ---- write/read round-trip --------------------------------------------------

def test_roundtrip_required_columns(tmp_path):
    df = make_minimal_df()
    out = tmp_path / "log.parquet"

    write_eventlog_parquet(df, out)
    back = read_eventlog_parquet(out)

    assert list(back["case_id"]) == list(df["case_id"])
    assert list(back["activity"]) == list(df["activity"])
    pd.testing.assert_series_equal(back["timestamp"], df["timestamp"], check_names=False)


def test_roundtrip_optional_columns(tmp_path):
    df = make_full_df()
    out = tmp_path / "log.parquet"

    write_eventlog_parquet(df, out)
    back = read_eventlog_parquet(out)

    assert list(back["resource"]) == list(df["resource"])
    assert list(back["lifecycle"]) == list(df["lifecycle"])
    pd.testing.assert_series_equal(
        back["start_timestamp"], df["start_timestamp"], check_names=False
    )
    # attrs round-trip as dicts
    assert back["case_attrs"].iloc[0] == {"dept": "sales"}
    assert back["event_attrs"].iloc[0] == {"priority": "high"}
    assert back["event_attrs"].iloc[1] == {}


def test_parquet_carries_schema_version(tmp_path):
    df = make_minimal_df()
    out = tmp_path / "log.parquet"

    write_eventlog_parquet(df, out)
    meta = pq.read_schema(out).metadata
    assert meta[b"schema_version"] == b"1.0"


def test_read_parquet_rejects_unknown_schema_version(tmp_path):
    df = make_minimal_df()
    ts = pa.array(df["timestamp"].values, type=pa.timestamp("us", tz="UTC"))
    table = pa.table({
        "case_id":   pa.array(df["case_id"]),
        "activity":  pa.array(df["activity"]),
        "timestamp": ts,
    })
    table = table.replace_schema_metadata({"schema_version": "2.0"})
    pq.write_table(table, tmp_path / "bad.parquet")

    with pytest.raises(ValueError, match="[Ss]chema.version|version"):
        read_eventlog_parquet(tmp_path / "bad.parquet")
