#!/bin/bash
# OpenCode Offline - Analysis Toolbox Test Suite
# Validates that every CLI tool of the analysis image is installed AND runnable
# from the agent's shell (i.e. resolvable through PATH, not just present on disk).
# Exit codes: 0 = all tests passed, 1 = one or more failures

set -uo pipefail

PASS=0
FAIL=0
VENV="${ANALYSIS_VENV:-/opt/analysis-venv/.venv}"

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

# Tool must be on PATH and must actually execute
tool() {
  local bin="$1"
  shift
  if ! command -v "$bin" >/dev/null 2>&1; then
    fail "$bin is not on PATH"
    return
  fi
  if "$@" >/dev/null 2>&1; then
    pass "$bin runs from PATH ($(command -v "$bin"))"
  else
    fail "$bin is on PATH but failed to run"
  fi
}

echo ""
echo "======================================"
echo " OpenCode Offline Analysis Toolbox"
echo "======================================"

# --- Section 1: Search, text and file tools ---
echo ""
echo "--- 1. Search / text / file tools ---"

tool rg rg --version
tool jq jq --version
tool find find /tmp -maxdepth 0
tool xargs true
tool sort sort /dev/null
tool uniq uniq /dev/null
tool head head -n1 /dev/null
tool tail tail -n1 /dev/null
tool wc wc -l /dev/null
tool awk awk 'BEGIN{exit 0}'
tool sed sed -n '' /dev/null
tool file file /etc/hostname
tool less less --version
tool tree tree -L 1 /tmp

# --- Section 2: Archive tools ---
echo ""
echo "--- 2. Archive tools ---"

tool tar tar --version
tool gzip gzip --version
tool xz xz --version
tool zip zip --version
tool unzip unzip -v

# --- Section 3: Network / process debugging ---
echo ""
echo "--- 3. Network / process debugging ---"

tool curl curl --version
tool ps ps -o pid= -p 1
tool lsof bash -c 'lsof -p $$'
tool ip ip addr
tool nc bash -c 'nc -h || nc --version'
tool git git --version

# --- Section 4: CSV / data analysis ---
echo ""
echo "--- 4. CSV / data analysis ---"

tool mlr mlr --version
tool python3 python3 --version
tool pip pip --version

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/data.csv" <<'CSV'
ts,sensor,value
2024-01-01T00:00:00Z,a,1
2024-01-01T00:01:00Z,a,3
2024-01-01T00:02:00Z,b,10
CSV

if [ "$(mlr --icsv --ojson stats1 -a mean -f value -g sensor "$WORK/data.csv" | jq -r '.[0].value_mean')" = "2" ]; then
  pass "mlr + jq compute grouped statistics over CSV"
else
  fail "mlr + jq compute grouped statistics over CSV"
fi

# --- Section 5: Python analysis venv ---
echo ""
echo "--- 5. Python analysis venv ---"

if [ "$(command -v python3)" = "$VENV/bin/python3" ]; then
  pass "python3 resolves to the analysis venv"
else
  fail "python3 resolves to the analysis venv (got $(command -v python3))"
fi

for pkg in pandas numpy duckdb pyarrow scipy tabulate; do
  if python3 -c "import $pkg" >/dev/null 2>&1; then
    pass "python package $pkg importable"
  else
    fail "python package $pkg importable"
  fi
done

if python3 - "$WORK/data.csv" >/dev/null 2>&1 <<'PY'
import sys
import duckdb
import pandas as pd
from tabulate import tabulate

frame = pd.read_csv(sys.argv[1])
summary = duckdb.query("select sensor, avg(value) as mean from frame group by sensor order by sensor").to_df()
assert summary.loc[0, "mean"] == 2
print(tabulate(summary, headers="keys"))
PY
then
  pass "pandas + duckdb + tabulate end-to-end CSV analysis"
else
  fail "pandas + duckdb + tabulate end-to-end CSV analysis"
fi

# --- Section 6: OpenCode bundle ---
echo ""
echo "--- 6. OpenCode bundle ---"

tool opencode opencode --version

# --- Section 7: Security regression checks ---
echo ""
echo "--- 7. Security regression checks ---"

for python in /usr/local/bin/python3 "$VENV/bin/python3"; do
  if "$python" - >/dev/null 2>&1 <<'PY'
import importlib.util
import sys
from pip._vendor import urllib3

assert sys.version_info >= (3, 13, 16)
assert importlib.util.find_spec("setuptools") is None
assert tuple(map(int, urllib3.__version__.split("."))) >= (2, 0, 6)
PY
  then
    pass "$python uses patched Python/urllib3 without setuptools"
  else
    fail "$python uses patched Python/urllib3 without setuptools"
  fi
done

if pip check >/dev/null 2>&1; then
  pass "analysis Python dependencies are consistent"
else
  fail "analysis Python dependencies are consistent"
fi

if grep -q 'go1\.27\.1' /usr/local/share/miller-build.txt; then
  pass "Miller was rebuilt with Go 1.27.1"
else
  fail "Miller was rebuilt with Go 1.27.1"
fi

for pkg in 'python3*' 'libxml2*' 'libevent*' 'vim*'; do
  if dpkg-query -W -f='${db:Status-Status}\n' "$pkg" 2>/dev/null | grep -q '^installed$'; then
    fail "unnecessary runtime package $pkg is installed"
  else
    pass "unnecessary runtime package $pkg is absent"
  fi
done

echo ""
echo "======================================"
echo " Results: $PASS passed, $FAIL failed"
echo "======================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
