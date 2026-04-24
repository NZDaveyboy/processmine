"""scripts/_roundtrip_py.py — Python leg of the round-trip check.

Usage: python3 scripts/_roundtrip_py.py <input.parquet> <output.parquet>
"""

import sys
sys.path.insert(0, "python")

from processmine_ml.io import read_eventlog_parquet, write_eventlog_parquet

input_path, output_path = sys.argv[1], sys.argv[2]
df = read_eventlog_parquet(input_path)
write_eventlog_parquet(df, output_path)
