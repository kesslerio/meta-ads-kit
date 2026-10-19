#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/meta-ads.sh"
FAILED=0
SERVER_PID=""
TMP=""

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${TMP}" && -d "${TMP}" ]]; then
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

TMP="$(mktemp -d)"
LOG="${TMP}/requests.log"
MODE_FILE="${TMP}/mode"
OUT="${TMP}/out"
ERR="${TMP}/err"
: > "$LOG"
echo ok > "$MODE_FILE"

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/social" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${TMP}/bin/social"

cat > "${TMP}/server.py" <<'PY'
#!/usr/bin/env python3
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

log_path = sys.argv[1]
mode_path = sys.argv[2]

PAGE1 = {
    "ad_id": "a",
    "actions": [
        {"action_type": "link_click", "value": "3", "7d_click": "2", "1d_view": "1"}
    ],
}
PAGE2 = {
    "ad_id": "b",
    "actions": [
        {"action_type": "purchase", "value": "1", "7d_click": "1", "1d_view": "0"}
    ],
    "conversions": [
        {"action_type": "offsite_conversion", "value": "1", "7d_click": "1", "1d_view": "0"}
    ],
    "cost_per_action_type": [
        {"action_type": "purchase", "value": "4.5", "7d_click": "4.5", "1d_view": "0"}
    ],
}
SPARSE = {
    "ad_id": "c",
    "actions": [
        {"action_type": "link_click", "value": "5", "7d_click": "5"},
        {"action_type": "video_view", "value": "9", "1d_view": "9"},
        {"action_type": "purchase", "value": "2", "7d_click": "1", "1d_view": "1"},
        {"action_type": "post_interaction_net", "value": "4"}
    ],
}
UNWINDOWED = {
    "ad_id": "d",
    "actions": [
        {"action_type": "link_click", "value": "5"}
    ],
}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path != "/health":
            with open(log_path, "a", encoding="utf-8") as fh:
                line = parsed.path
                if parsed.query:
                    line += "?" + parsed.query
                fh.write(line + "\n")
        if parsed.path == "/health":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        mode = "ok"
        try:
            with open(mode_path, encoding="utf-8") as fh:
                mode = fh.read().strip() or "ok"
        except FileNotFoundError:
            pass
        if mode == "error":
            body = json.dumps({"error": {"message": "bad window"}}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if not parsed.path.endswith("/insights"):
            body = b'{"error":{"message":"not found"}}'
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        qs = parse_qs(parsed.query)
        if mode in ("sparse", "unwindowed"):
            payload = {"data": [SPARSE if mode == "sparse" else UNWINDOWED]}
        elif qs.get("page", ["1"])[0] == "2":
            payload = {"data": [PAGE2]}
        else:
            host = self.headers.get("Host", "127.0.0.1")
            payload = {
                "data": [PAGE1],
                "paging": {"next": f"http://{host}{parsed.path}?page=2"},
            }
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
PY

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy || true
export NO_PROXY=127.0.0.1,localhost
export no_proxy=127.0.0.1,localhost
export PATH="${TMP}/bin:${PATH}"
export META_TOKEN=secret-token-xyz
export META_AD_ACCOUNT=act_1
unset META_GRAPH_API_VERSION || true

python3 "${TMP}/server.py" "$LOG" "$MODE_FILE" >"${TMP}/port" 2>"${TMP}/server.err" &
SERVER_PID=$!

ready=0
port=""
for _ in $(seq 1 50); do
  if [[ -s "${TMP}/port" ]]; then
    port="$(tr -d '[:space:]' < "${TMP}/port")"
    if [[ -n "$port" ]] && curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
  fi
  sleep 0.05
done
if [[ "$ready" -ne 1 ]]; then
  echo "FAIL: test server did not start"
  cat "${TMP}/server.err" >&2 || true
  exit 1
fi
export META_GRAPH_BASE_URL="http://127.0.0.1:${port}"

capture() {
  local out="$1"
  local err="$2"
  shift 2
  set +e
  "$HELPER" "$@" >"$out" 2>"$err"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

reset_log() { : > "$LOG"; echo ok > "$MODE_FILE"; }

TIME_ENC='%7B%22since%22%3A%222026-01-01%22%2C%22until%22%3A%222026-01-07%22%7D'
WINDOWS_ENC='%5B%227d_click%22%2C%221d_view%22%5D'
BASE_QUERY="fields=spend%2Cactions&level=ad&time_range=${TIME_ENC}&limit=50"
WINDOWS_QUERY="${BASE_QUERY}&breakdowns=publisher_platform&action_attribution_windows=${WINDOWS_ENC}&access_token=${META_TOKEN}"
UNIFIED_QUERY="${BASE_QUERY}&use_unified_attribution_setting=true&access_token=${META_TOKEN}"
PLAIN_QUERY="${BASE_QUERY}&access_token=${META_TOKEN}"

reset_log
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --level ad --fields spend,actions --breakdowns publisher_platform --limit 50 --attribution-windows '7d_click,1d_view')"
actual="$(head -n 1 "$LOG" || true)"
expected="/v19.0/act_1/insights?${WINDOWS_QUERY}"
if [[ "$rc" -eq 0 && "$actual" == "$expected" && "$(wc -l < "$LOG" | tr -d ' ')" -eq 2 && "$(sed -n '2p' "$LOG")" == "/v19.0/act_1/insights?page=2" ]]; then
  pass "params forwarded exactly"
else
  fail "params forwarded exactly (rc=${rc})"
  printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
  echo "--- stderr ---" >&2
  cat "$ERR" >&2 || true
  echo "--- log ---" >&2
  cat "$LOG" >&2 || true
fi
if [[ "$rc" -eq 0 ]] && jq -e '(.data | length) == 2 and .data[0].ad_id == "a" and .data[1].ad_id == "b"' "$OUT" >/dev/null; then
  pass "pages merged"
else
  fail "pages merged"
  cat "$OUT" >&2 || true
fi
if [[ "$rc" -eq 0 ]] && jq -e '
  .attribution == {
    action_attribution_windows: ["7d_click","1d_view"],
    use_unified_attribution_setting: null,
    api_version: "v19.0",
    pages: 2,
    rows: 2,
    window_values_present: true
  }
' "$OUT" >/dev/null; then
  pass "attribution contract"
else
  fail "attribution contract"
  cat "$OUT" >&2 || true
fi

reset_log
echo sparse > "$MODE_FILE"
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --level ad --fields spend,actions --limit 50 --attribution-windows '7d_click,1d_view')"
if [[ "$rc" -eq 0 ]] && jq -e '.attribution.window_values_present == true' "$OUT" >/dev/null; then
  pass "zero-value and unattributable entries do not hide a windowed response"
else
  fail "zero-value and unattributable entries do not hide a windowed response (rc=${rc})"
  cat "$OUT" >&2 || true
fi

reset_log
echo unwindowed > "$MODE_FILE"
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --level ad --fields spend,actions --limit 50 --attribution-windows '7d_click,1d_view')"
if [[ "$rc" -eq 0 ]] && jq -e '.attribution.window_values_present == false' "$OUT" >/dev/null; then
  pass "a response with no requested window anywhere is not windowed"
else
  fail "a response with no requested window anywhere is not windowed (rc=${rc})"
  cat "$OUT" >&2 || true
fi

reset_log
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --level ad --fields spend,actions --limit 50 --unified-attribution true)"
actual="$(head -n 1 "$LOG" || true)"
expected="/v19.0/act_1/insights?${UNIFIED_QUERY}"
if [[ "$rc" -eq 0 && "$actual" == "$expected" ]] && jq -e '
  .attribution.action_attribution_windows == null
  and .attribution.use_unified_attribution_setting == true
  and .attribution.window_values_present == null
  and .attribution.pages == 2
  and .attribution.rows == 2
  and .attribution.api_version == "v19.0"
' "$OUT" >/dev/null; then
  pass "unified attribution forwarded"
else
  fail "unified attribution forwarded (rc=${rc})"
  printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
  cat "$OUT" >&2 || true
  cat "$ERR" >&2 || true
fi

reset_log
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --level ad --fields spend,actions --limit 50)"
actual="$(head -n 1 "$LOG" || true)"
expected="/v19.0/act_1/insights?${PLAIN_QUERY}"
if [[ "$rc" -eq 0 && "$actual" == "$expected" ]] && jq -e '(has("attribution") | not) and ((.data | length) == 2)' "$OUT" >/dev/null; then
  pass "no attribution key without flags"
else
  fail "no attribution key without flags (rc=${rc})"
  cat "$OUT" >&2 || true
  printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
fi

reset_log
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --attribution-windows '7d_click,nope')"
if [[ "$rc" -eq 2 ]] && grep -Fxq 'ERROR: unsupported attribution window: nope' "$ERR" && [[ ! -s "$LOG" ]]; then
  pass "invalid window exits 2"
else
  fail "invalid window exits 2 (rc=${rc})"
  cat "$ERR" >&2 || true
fi

reset_log
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --attribution-windows '7d_click,7d_click')"
if [[ "$rc" -eq 2 ]] && grep -Fxq 'ERROR: unsupported attribution window: 7d_click' "$ERR"; then
  pass "duplicate window exits 2"
else
  fail "duplicate window exits 2 (rc=${rc})"
  cat "$ERR" >&2 || true
fi

reset_log
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --attribution-windows '7d_click,')"
if [[ "$rc" -eq 2 ]] && grep -Fxq 'ERROR: unsupported attribution window: ' "$ERR"; then
  pass "empty window exits 2"
else
  fail "empty window exits 2 (rc=${rc})"
  cat "$ERR" >&2 || true
fi

reset_log
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --attribution-windows '7d_click' --unified-attribution true)"
if [[ "$rc" -eq 2 && ! -s "$LOG" && -s "$ERR" ]]; then
  pass "both flags exit 2"
else
  fail "both flags exit 2 (rc=${rc})"
  cat "$ERR" >&2 || true
fi

reset_log
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --unified-attribution maybe)"
if [[ "$rc" -eq 2 && ! -s "$LOG" ]]; then
  pass "bad unified value exits 2"
else
  fail "bad unified value exits 2 (rc=${rc})"
  cat "$ERR" >&2 || true
fi

reset_log
rc="$(capture "$OUT" "$ERR" custom --attribution-windows '7d_click')"
if [[ "$rc" -eq 2 && ! -s "$LOG" ]]; then
  pass "flags require explicit dates"
else
  fail "flags require explicit dates (rc=${rc})"
  cat "$ERR" >&2 || true
fi

reset_log
rc="$(capture "$OUT" "$ERR" overview --since 2026-01-01 --until 2026-01-07 --unified-attribution false)"
if [[ "$rc" -eq 2 && ! -s "$LOG" ]]; then
  pass "flags rejected outside custom"
else
  fail "flags rejected outside custom (rc=${rc})"
  cat "$ERR" >&2 || true
fi

reset_log
rc="$(META_GRAPH_API_VERSION=nope capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07)"
if [[ "$rc" -eq 2 && ! -s "$LOG" ]] && grep -q 'META_GRAPH_API_VERSION' "$ERR"; then
  pass "bad api version exits 2"
else
  fail "bad api version exits 2 (rc=${rc})"
  cat "$ERR" >&2 || true
  cat "$LOG" >&2 || true
fi

reset_log
echo error > "$MODE_FILE"
rc="$(capture "$OUT" "$ERR" custom --since 2026-01-01 --until 2026-01-07 --level ad --fields spend,actions --limit 50 --unified-attribution false)"
if [[ "$rc" -ne 0 ]] \
  && grep -Fq 'bad window' "$ERR" \
  && grep -Fq 'ERROR: Meta Insights HTTP 400: bad window' "$ERR" \
  && ! grep -Fq 'secret-token-xyz' "$ERR" \
  && ! grep -Fq 'access_token' "$ERR" \
  && ! grep -Fq '127.0.0.1' "$ERR" \
  && ! grep -Fq "$META_TOKEN" "$OUT" \
  && grep -Fq 'use_unified_attribution_setting=false' "$LOG"; then
  pass "http error reports message without token"
else
  fail "http error reports message without token (rc=${rc})"
  echo "--- stderr ---" >&2
  cat "$ERR" >&2 || true
  echo "--- stdout ---" >&2
  cat "$OUT" >&2 || true
  echo "--- log ---" >&2
  cat "$LOG" >&2 || true
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo FAIL
  exit 1
fi
echo PASS
exit 0
