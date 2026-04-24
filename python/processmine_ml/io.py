"""processmine_ml/io.py — I/O for the processmine event-log schema (v1)."""

from __future__ import annotations

import json
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

SCHEMA_VERSION = "1.0"
LIFECYCLE_VALS = frozenset({"start", "complete", "schedule", "withdraw", "suspend", "resume"})
REQUIRED_COLS  = ("case_id", "activity", "timestamp")

_PARQUET_SCHEMA = pa.schema([
    pa.field("case_id",         pa.string(),                  nullable=False),
    pa.field("activity",        pa.string(),                  nullable=False),
    pa.field("timestamp",       pa.timestamp("us", tz="UTC"), nullable=False),
    pa.field("start_timestamp", pa.timestamp("us", tz="UTC"), nullable=True),
    pa.field("resource",        pa.string(),                  nullable=True),
    pa.field("lifecycle",       pa.string(),                  nullable=True),
    pa.field("case_attrs",      pa.string(),                  nullable=True),
    pa.field("event_attrs",     pa.string(),                  nullable=True),
]).with_metadata({"schema_version": SCHEMA_VERSION})


# ---- validate_eventlog -------------------------------------------------------

def validate_eventlog(df: pd.DataFrame) -> pd.DataFrame:
    """Validate *df* against the processmine schema v1.

    Returns *df* unchanged on success; raises ``ValueError`` on any violation.
    """
    missing = [c for c in REQUIRED_COLS if c not in df.columns]
    if missing:
        raise ValueError(f"Missing required column(s): {', '.join(missing)}")

    for col in REQUIRED_COLS:
        if df[col].isna().any():
            raise ValueError(
                f"Column '{col}' contains Null/NA values; required columns must be non-null."
            )

    _assert_utc(df["timestamp"], "timestamp")
    if "start_timestamp" in df.columns:
        _assert_utc(df["start_timestamp"], "start_timestamp", allow_na=True)
        both = df["start_timestamp"].notna() & df["timestamp"].notna()
        if (df.loc[both, "timestamp"] < df.loc[both, "start_timestamp"]).any():
            raise ValueError("start_timestamp must be <= timestamp for all events.")

    if "lifecycle" in df.columns:
        bad = set(df["lifecycle"].dropna().unique()) - LIFECYCLE_VALS
        if bad:
            raise ValueError(
                f"Invalid lifecycle value(s): {bad}. "
                f"Allowed: {sorted(LIFECYCLE_VALS)}"
            )

    return df


def _assert_utc(series: pd.Series, name: str, allow_na: bool = False) -> None:
    dtype = series.dtype
    if not hasattr(dtype, "tz"):
        raise ValueError(f"Column '{name}' must be a timezone-aware datetime (got {dtype}).")
    tz = str(dtype.tz)
    if tz not in ("UTC", "utc"):
        raise ValueError(f"Column '{name}' must have tz=UTC (got '{tz}').")


# ---- read_xes ----------------------------------------------------------------

_XES_NS         = "http://www.xes-standard.org/"
_STD_TRACE_KEYS = {"concept:name"}
_STD_EVENT_KEYS = {"concept:name", "time:timestamp", "org:resource", "lifecycle:transition"}
_STR_ELEM_TAGS  = {"string", "int", "float", "boolean"}


def read_xes(path: str | Path) -> pd.DataFrame:
    """Parse an XES event log file and return a validated DataFrame."""
    tree = ET.parse(str(path))
    root = tree.getroot()

    def _tag(elem: ET.Element) -> str:
        return elem.tag.replace(f"{{{_XES_NS}}}", "")

    rows: list[dict[str, Any]] = []

    for tr in root:
        if _tag(tr) != "trace":
            continue
        case_id, case_attrs = _parse_trace_attrs(tr, _tag)
        for ev in tr:
            if _tag(ev) != "event":
                continue
            row = _parse_event(ev, _tag)
            row["case_id"]    = case_id
            row["case_attrs"] = dict(case_attrs)
            rows.append(row)

    if not rows:
        return _empty_df()

    df = pd.DataFrame(rows)
    df["timestamp"] = (
        pd.to_datetime(df["timestamp"], utc=True, format="ISO8601").dt.as_unit("us")
    )
    if "start_timestamp" in df.columns:
        mask = df["start_timestamp"].notna()
        if mask.any():
            df.loc[mask, "start_timestamp"] = (
                pd.to_datetime(df.loc[mask, "start_timestamp"], utc=True, format="ISO8601")
                .dt.as_unit("us")
            )
        df["start_timestamp"] = df["start_timestamp"].astype("datetime64[us, UTC]")

    return validate_eventlog(df)


def _parse_trace_attrs(
    trace: ET.Element, tag_fn: Any
) -> tuple[str, dict[str, str]]:
    case_id = ""
    extra: dict[str, str] = {}
    for child in trace:
        t = tag_fn(child)
        k = child.get("key", "")
        v = child.get("value", "")
        if k == "concept:name":
            case_id = v
        elif t in _STR_ELEM_TAGS and k not in _STD_TRACE_KEYS:
            extra[k] = str(v)
    return case_id, extra


def _parse_event(event: ET.Element, tag_fn: Any) -> dict[str, Any]:
    row: dict[str, Any] = {
        "activity":    None,
        "timestamp":   None,
        "resource":    None,
        "lifecycle":   None,
        "event_attrs": {},
    }
    extra: dict[str, str] = {}
    for child in event:
        t = tag_fn(child)
        k = child.get("key", "")
        v = child.get("value", "")
        if k == "concept:name":
            row["activity"] = v
        elif k == "time:timestamp":
            row["timestamp"] = v
        elif k == "org:resource":
            row["resource"] = v
        elif k == "lifecycle:transition":
            row["lifecycle"] = v
        elif t in _STR_ELEM_TAGS and k not in _STD_EVENT_KEYS:
            extra[k] = str(v)
    row["event_attrs"] = extra
    return row


def _empty_df() -> pd.DataFrame:
    return pd.DataFrame(columns=list(REQUIRED_COLS))


# ---- write_eventlog_parquet --------------------------------------------------

def write_eventlog_parquet(df: pd.DataFrame, path: str | Path) -> None:
    """Validate *df* and write it to a Parquet file at *path*."""
    validate_eventlog(df)
    df = df.copy()

    df["timestamp"] = _to_utc_us(df["timestamp"])
    if "start_timestamp" in df.columns:
        df["start_timestamp"] = _to_utc_us(df["start_timestamp"])

    arrays: list[pa.Array] = []
    fields: list[pa.Field] = []

    for field in _PARQUET_SCHEMA:
        name = field.name
        if name not in df.columns:
            if field.nullable:
                arrays.append(pa.nulls(len(df), type=field.type))
            else:
                raise ValueError(f"Required column '{name}' is missing.")
        elif name in ("case_attrs", "event_attrs"):
            arrays.append(_dict_col_to_json_array(df[name]))
        elif pa.types.is_timestamp(field.type):
            arrays.append(pa.array(df[name], type=field.type))
        else:
            col = df[name].where(df[name].notna(), other=None)
            arrays.append(pa.array(col.tolist(), type=field.type))
        fields.append(field)

    schema = pa.schema(fields).with_metadata({"schema_version": SCHEMA_VERSION})
    table  = pa.table(dict(zip([f.name for f in fields], arrays)), schema=schema)
    pq.write_table(table, str(path))


def _to_utc_us(series: pd.Series) -> pd.Series:
    if not hasattr(series.dtype, "tz"):
        series = pd.to_datetime(series, utc=True)
    elif str(series.dtype.tz) != "UTC":
        series = series.dt.tz_convert("UTC")
    return series.dt.as_unit("us")


def _dict_col_to_json_array(series: pd.Series) -> pa.Array:
    """Serialise a column of dicts to JSON strings for Parquet storage."""
    out: list[str | None] = []
    for val in series:
        if val is None or (isinstance(val, float) and pd.isna(val)):
            out.append(None)
        else:
            out.append(json.dumps({str(k): str(v) for k, v in (val.items() if isinstance(val, dict) else val)}, sort_keys=True))
    return pa.array(out, type=pa.string())


# ---- read_eventlog_parquet ---------------------------------------------------

def read_eventlog_parquet(path: str | Path) -> pd.DataFrame:
    """Read a processmine Parquet file and return a validated DataFrame."""
    table = pq.read_table(str(path))

    meta    = table.schema.metadata or {}
    raw     = meta.get(b"schema_version") or meta.get("schema_version")
    version = raw.decode() if isinstance(raw, bytes) else (raw or "")
    if not version:
        raise ValueError("Parquet file is missing 'schema_version' metadata.")
    major = int(version.split(".")[0])
    if major != 1:
        raise ValueError(
            f"Unsupported schema version '{version}'. Only major version 1 is supported."
        )

    df = table.to_pandas(timestamp_as_object=False)

    for ts_col in ("timestamp", "start_timestamp"):
        if ts_col in df.columns and hasattr(df[ts_col].dtype, "tz"):
            df[ts_col] = df[ts_col].dt.as_unit("us").dt.tz_convert("UTC")

    # Deserialise JSON string attr columns back to Python dicts
    for attr_col in ("case_attrs", "event_attrs"):
        if attr_col in df.columns:
            df[attr_col] = df[attr_col].apply(
                lambda x: json.loads(x) if isinstance(x, str) else ({} if x is None else x)
            )

    return validate_eventlog(df)
