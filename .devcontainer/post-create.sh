#!/usr/bin/env bash
# Runs once when the devcontainer is first created.
# Installs R + Python deps so `make test` works immediately.
set -euo pipefail

echo "==> Installing Python package (editable) with dev extras..."
if [ -f python/pyproject.toml ]; then
  pip install --user --break-system-packages -e "./python[dev]"
else
  echo "    (skipped: python/pyproject.toml not yet present)"
fi

echo "==> Restoring R package dependencies via renv..."
if [ -f renv.lock ]; then
  R -e "renv::restore(prompt = FALSE)"
else
  echo "    (skipped: renv.lock not yet present)"
fi

echo "==> Verifying R <-> Python round-trip..."
if [ -f scripts/roundtrip_check.R ]; then
  Rscript scripts/roundtrip_check.R && echo "    Round-trip OK." || echo "    Round-trip failed (expected if schema/validators not yet implemented)."
else
  echo "    (skipped: scripts/roundtrip_check.R not yet present)"
fi

echo ""
echo "Devcontainer ready. Try:"
echo "  make test        # full test suite"
echo "  R                # or: radian"
echo "  python           # Python 3.11"
