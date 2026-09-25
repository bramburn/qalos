#!/usr/bin/env bash
# vendor/aqa/server/preflight.sh
#
# Host-side preflight for the aqa_server daemon. Compiles the sources, then
# asserts the routing and access-control contract against a locally running
# instance.
#
# Why this exists: the auth rule (loopback trusted, off-box requires the shared
# bearer token, missing token file rejects everything) is the security-critical
# part of this daemon and it is easy to break silently. These assertions are the
# executable form of the contract documented in README.md.
#
# Run on any Linux host with g++ and curl:
#   bash vendor/aqa/server/preflight.sh
#
# NOTE: /dev/uinput init is expected to FAIL on a host — that is reported by the
# daemon as a warning and does not fail this preflight. The token-success case
# needs /data/local/tmp and is skipped without passwordless sudo.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/src" && pwd)"
WORK="$(mktemp -d)"
PORT=8080
TOKEN_PATH=/data/local/tmp/qalos_token
FAILURES=0

cleanup() {
    [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }

expect_status() {
    local want="$1" desc="$2"; shift 2
    local got
    got=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null)
    if [ "$got" = "$want" ]; then pass "$desc (HTTP $got)"; else fail "$desc: want $want, got $got"; fi
}

start_server() {
    "$WORK/aqa_server" > "$WORK/srv.log" 2>&1 &
    SRV=$!
    # Wait for the listen line rather than sleeping a fixed amount.
    for _ in $(seq 1 50); do
        grep -q 'listening on' "$WORK/srv.log" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

stop_server() {
    [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
    wait "$SRV" 2>/dev/null
    SRV=""
}

echo "=== aqa_server preflight ==="

echo
echo "[1/3] compile"
if g++ -std=c++17 -Wall -O2 -pthread \
        "$SRC_DIR/main.cpp" "$SRC_DIR/uinput_injector.cpp" "$SRC_DIR/http_server.cpp" \
        -o "$WORK/aqa_server" 2> "$WORK/build.log"; then
    if [ -s "$WORK/build.log" ]; then
        fail "compiled but emitted warnings (see below)"
        sed 's/^/      /' "$WORK/build.log"
    else
        pass "clean compile with -Wall, no warnings"
    fi
else
    fail "compilation failed"
    sed 's/^/      /' "$WORK/build.log"
    exit 1
fi

echo
echo "[2/3] routing (loopback, no token file)"
rm -f "$TOKEN_PATH" 2>/dev/null || true
if start_server; then
    expect_status 200 "GET  /v1/health"            "http://127.0.0.1:$PORT/v1/health"
    expect_status 200 "GET  /v1/display"           "http://127.0.0.1:$PORT/v1/display"
    expect_status 400 "POST /v1/tap missing y"     -X POST -d '{"x":10}' "http://127.0.0.1:$PORT/v1/tap"
    expect_status 400 "POST /v1/swipe missing y2"  -X POST -d '{"x1":1,"y1":2,"x2":3}' "http://127.0.0.1:$PORT/v1/swipe"
    expect_status 400 "POST /v1/key missing field" -X POST -d '{}' "http://127.0.0.1:$PORT/v1/key"
    expect_status 404 "GET  /v1/nope"              "http://127.0.0.1:$PORT/v1/nope"

    body=$(curl -s --max-time 5 -X POST -d '{"x":10}' "http://127.0.0.1:$PORT/v1/tap")
    case "$body" in
        *'"code":"MISSING_FIELD"'*) pass "error envelope is {code,message,field}" ;;
        *) fail "unexpected error body: $body" ;;
    esac
    stop_server
else
    fail "server never reported listening"
fi

echo
echo "[3/3] access control"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$IP" ]; then
    skip "no non-loopback address on this host"
elif start_server; then
    expect_status 401 "off-box rejected with no token file" "http://$IP:$PORT/v1/display"
    expect_status 401 "off-box rejected with bogus Bearer"  -H 'Authorization: Bearer deadbeef' "http://$IP:$PORT/v1/display"
    stop_server

    if sudo -n mkdir -p "$(dirname "$TOKEN_PATH")" 2>/dev/null; then
        TOK=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        printf '%s\n' "$TOK" | sudo -n tee "$TOKEN_PATH" > /dev/null
        sudo -n chmod 0644 "$TOKEN_PATH"

        if start_server; then
            expect_status 401 "off-box rejected without header"  "http://$IP:$PORT/v1/display"
            expect_status 401 "off-box rejected with wrong token" -H 'Authorization: Bearer nope' "http://$IP:$PORT/v1/display"
            expect_status 200 "off-box accepted with right token" -H "Authorization: Bearer $TOK" "http://$IP:$PORT/v1/display"
            expect_status 200 "loopback still trusted"            "http://127.0.0.1:$PORT/v1/display"

            if grep -q 'auth=rejected' "$WORK/srv.log"; then
                pass "rejected attempts are audit-logged"
            else
                fail "rejected attempts were not audit-logged"
            fi
            stop_server
        else
            fail "server never reported listening (with token)"
        fi
        sudo -n rm -f "$TOKEN_PATH" 2>/dev/null || true
    else
        skip "token-success path needs passwordless sudo to create $TOKEN_PATH"
    fi
else
    fail "server never reported listening"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "=== preflight OK ==="
    exit 0
fi
echo "=== preflight FAILED ($FAILURES) ==="
exit 1