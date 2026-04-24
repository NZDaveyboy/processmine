import sys
import pathlib

# Allow running pytest from repo root without editable install
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))
