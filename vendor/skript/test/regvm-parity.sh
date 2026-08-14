#!/bin/sh
# regvm-parity.sh — compare the optimized register compiler with its
# --no-bytecode-opts mode.
#
# Every non-comment line in regvm-parity.pt runs twice. The two executions must
# have the same exit status and the same observable output. Both stdout and
# stderr are compared after removing the process-dependent address fragments
# and the CLI's stable "[regvm]" suffix. A matching nonzero result is valid
# only when its error output also matches; arbitrary "both failed" results do
# not pass. Every case has a required hard timeout.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORPUS="$SCRIPT_DIR/regvm-parity.pt"
SKRIPT=${SKRIPT:-zig-out/bin/skript}
CASE_TIMEOUT=10

if ! command -v timeout >/dev/null 2>&1; then
    echo "regvm-parity: required timeout command is unavailable" >&2
    exit 1
fi
if ! timeout --kill-after=1s 1s true >/dev/null 2>&1; then
    echo "regvm-parity: timeout lacks required kill-after support" >&2
    exit 1
fi

if ! command -v "$SKRIPT" >/dev/null 2>&1 && [ ! -x "$SKRIPT" ]; then
    echo "regvm-parity: cannot find executable: $SKRIPT" >&2
    exit 1
fi

tmp=$(mktemp -d) || {
    echo "regvm-parity: cannot create temp dir" >&2
    exit 1
}
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# run_case <stdin-file> <stdout-file> <stderr-file> [compiler-options...]
# Leaves the child status in RUN_STATUS. GNU timeout returns 124 when it
# reaches the deadline and 137 if its follow-up kill is required.
run_case() {
    stdin_file=$1
    stdout_file=$2
    stderr_file=$3
    shift 3

    timeout --kill-after=1s "${CASE_TIMEOUT}s" "$SKRIPT" "$@" - \
        < "$stdin_file" > "$stdout_file" 2> "$stderr_file"
    RUN_STATUS=$?
}

# normalize <input-file> <output-file>
# The address form is intentionally narrow: only hexadecimal values with a
# 0x prefix are unstable in the CLI's value/error rendering.
normalize() {
    sed -e 's/ \[regvm\]//g' \
        -e 's/0x[0-9A-Fa-f][0-9A-Fa-f]*/0xADDR/g' \
        "$1" > "$2"
}

is_timeout() {
    [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

total=0
pass=0
fail=0

while IFS= read -r case_text || [ -n "$case_text" ]; do
    case "$case_text" in
        '' | \#*) continue ;;
    esac

    total=$((total + 1))
    if [ "$case_text" = "__EMPTY__" ]; then
        : > "$tmp/stdin"
    else
        printf '%s\n' "$case_text" > "$tmp/stdin"
    fi

    run_case "$tmp/stdin" "$tmp/default.out" "$tmp/default.err"
    default_status=$RUN_STATUS
    run_case "$tmp/stdin" "$tmp/unoptimized.out" "$tmp/unoptimized.err" \
        --no-bytecode-opts
    unoptimized_status=$RUN_STATUS

    normalize "$tmp/default.out" "$tmp/default.norm"
    normalize "$tmp/unoptimized.out" "$tmp/unoptimized.norm"
    normalize "$tmp/default.err" "$tmp/default.err.norm"
    normalize "$tmp/unoptimized.err" "$tmp/unoptimized.err.norm"

    verdict=PASS
    reason=
    if is_timeout "$default_status" || is_timeout "$unoptimized_status"; then
        verdict=FAIL
        reason=timeout
    elif [ "$default_status" -ne "$unoptimized_status" ]; then
        verdict=FAIL
        reason=status
    elif ! cmp -s "$tmp/default.norm" "$tmp/unoptimized.norm"; then
        verdict=FAIL
        reason=stdout
    elif ! cmp -s "$tmp/default.err.norm" "$tmp/unoptimized.err.norm"; then
        verdict=FAIL
        reason=stderr
    fi

    if [ "$verdict" = PASS ]; then
        pass=$((pass + 1))
        if [ "$default_status" -eq 0 ]; then
            echo "PASS: $case_text"
        else
            echo "PASS (matching error): $case_text"
        fi
    else
        fail=$((fail + 1))
        echo "FAIL ($reason): $case_text"
        echo "  default status: $default_status"
        echo "  --no-bytecode-opts status: $unoptimized_status"
        echo "  default stdout:" >&2
        cat "$tmp/default.norm" >&2
        echo "  --no-bytecode-opts stdout:" >&2
        cat "$tmp/unoptimized.norm" >&2
        echo "  default stderr:" >&2
        cat "$tmp/default.err.norm" >&2
        echo "  --no-bytecode-opts stderr:" >&2
        cat "$tmp/unoptimized.err.norm" >&2
    fi
done < "$CORPUS"

echo
echo "regvm-parity summary: total=$total pass=$pass unexpected-fail=$fail"

if [ "$fail" -eq 0 ]; then
    exit 0
fi
exit 1
