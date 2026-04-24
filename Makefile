.PHONY: test-r test-py roundtrip test check-r style-r lint-py format-py

# R -------------------------------------------------------------------------
test-r:
	Rscript -e "devtools::test('R')"

check-r:
	Rscript -e "devtools::check('R')"

style-r:
	Rscript -e "styler::style_pkg('R')"

# Python --------------------------------------------------------------------
test-py:
	PYTHONPATH=python pytest python/

lint-py:
	ruff check python/ && mypy python/

format-py:
	ruff format python/

# Cross-language correctness -------------------------------------------------
roundtrip:
	Rscript scripts/roundtrip_check.R

# All -----------------------------------------------------------------------
test: test-r test-py roundtrip
