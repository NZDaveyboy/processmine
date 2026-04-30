"""Tests for read_csv_eventlog."""

from __future__ import annotations

import textwrap

import pytest

from processmine_ml.io import read_csv_eventlog


def _csv_path(tmp_path, content: str):
    p = tmp_path / "log.csv"
    p.write_text(textwrap.dedent(content).strip())
    return p


def test_reads_minimal_csv_default_columns(tmp_path):
    p = _csv_path(tmp_path, """
        case_id,activity,timestamp
        C1,A,2024-01-01 00:00:00
        C1,B,2024-01-01 01:00:00
        C2,A,2024-01-01 00:00:00
    """)
    log = read_csv_eventlog(p)
    assert len(log) == 3
    assert list(log.columns[:3]) == ["case_id", "activity", "timestamp"]
    assert str(log["timestamp"].dtype.tz) == "UTC"


def test_maps_custom_column_names(tmp_path):
    p = _csv_path(tmp_path, """
        CaseID,EventName,EventTime
        X1,Start,2024-01-01 08:00:00
        X1,End,2024-01-01 09:00:00
    """)
    log = read_csv_eventlog(
        p,
        case_col="CaseID",
        activity_col="EventName",
        timestamp_col="EventTime",
    )
    assert list(log.columns[:3]) == ["case_id", "activity", "timestamp"]
    assert list(log["case_id"]) == ["X1", "X1"]


def test_includes_optional_columns(tmp_path):
    p = _csv_path(tmp_path, """
        case_id,activity,timestamp,resource,lifecycle
        C1,A,2024-01-01 00:00:00,alice,complete
    """)
    log = read_csv_eventlog(p, resource_col="resource", lifecycle_col="lifecycle")
    assert "resource" in log.columns
    assert "lifecycle" in log.columns
    assert log["resource"].iloc[0] == "alice"
    assert log["lifecycle"].iloc[0] == "complete"


def test_folds_columns_into_attrs(tmp_path):
    p = _csv_path(tmp_path, """
        case_id,activity,timestamp,region,cost
        C1,A,2024-01-01 00:00:00,NZ,10
        C1,B,2024-01-01 01:00:00,NZ,20
    """)
    log = read_csv_eventlog(
        p,
        case_attrs_cols=["region"],
        event_attrs_cols=["cost"],
    )
    assert "case_attrs" in log.columns
    assert "event_attrs" in log.columns
    assert log["case_attrs"].iloc[0]["region"] == "NZ"
    assert log["event_attrs"].iloc[0]["cost"] == "10"
    assert log["event_attrs"].iloc[1]["cost"] == "20"


def test_converts_non_utc_source_tz_to_utc(tmp_path):
    p = _csv_path(tmp_path, """
        case_id,activity,timestamp
        C1,A,2024-01-01 12:00:00
    """)
    log = read_csv_eventlog(p, tz="America/New_York")
    assert str(log["timestamp"].dtype.tz) == "UTC"
    # 12:00 EST = 17:00 UTC
    assert log["timestamp"].iloc[0].hour == 17


def test_explicit_timestamp_format(tmp_path):
    p = _csv_path(tmp_path, """
        case_id,activity,timestamp
        C1,A,01/15/2024 08:30
    """)
    log = read_csv_eventlog(p, timestamp_format="%m/%d/%Y %H:%M")
    assert log["timestamp"].iloc[0].month == 1
    assert log["timestamp"].iloc[0].day == 15


def test_errors_on_missing_required_column(tmp_path):
    p = _csv_path(tmp_path, """
        case_id,activity,timestamp
        C1,A,2024-01-01
    """)
    with pytest.raises(ValueError, match="not found in CSV"):
        read_csv_eventlog(p, case_col="no_such_col")


def test_errors_on_missing_optional_column(tmp_path):
    p = _csv_path(tmp_path, """
        case_id,activity,timestamp
        C1,A,2024-01-01
    """)
    with pytest.raises(ValueError, match="not found in CSV"):
        read_csv_eventlog(p, resource_col="no_resource")


def test_result_passes_validate_eventlog(tmp_path):
    p = _csv_path(tmp_path, """
        case_id,activity,timestamp
        C1,A,2024-01-01 00:00:00
        C1,B,2024-01-01 01:00:00
    """)
    from processmine_ml.io import validate_eventlog
    log = read_csv_eventlog(p)
    validate_eventlog(log)  # should not raise


def test_passes_extra_kwargs_to_read_csv(tmp_path):
    p = _csv_path(tmp_path, """
        case_id;activity;timestamp
        C1;A;2024-01-01 00:00:00
    """)
    log = read_csv_eventlog(p, sep=";")
    assert len(log) == 1
