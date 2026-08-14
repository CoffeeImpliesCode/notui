#!/usr/bin/env bash
# Run the API and demo corpus, then compiler-optimization parity.
# The first argument is the CLI executable. Every child has a hard deadline;
# a nonzero child status or a missing API ALL-OK marker fails the run.

set -u
export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

if [ "$#" -lt 1 ]; then
    echo "api-run: usage: $0 <skript-cli>" >&2
    exit 2
fi
if [ "$#" -gt 1 ]; then
    echo "api-run: unexpected arguments after CLI path" >&2
    exit 2
fi

CLI=$1
case "$CLI" in
    /*) ;;
    *) CLI="$PWD/$CLI" ;;
esac
if [ ! -x "$CLI" ]; then
    echo "api-run: CLI is not executable: $CLI" >&2
    exit 1
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "api-run: required timeout command is unavailable" >&2
    exit 1
fi
if ! timeout --kill-after=1s 1s true >/dev/null 2>&1; then
    echo "api-run: timeout lacks required kill-after support" >&2
    exit 1
fi

cd "$ROOT_DIR" || exit 1

API_TIMEOUT=30
CLI_TIMEOUT=5
DEMO_TIMEOUT=30
PARITY_TIMEOUT=300
PARITY="$ROOT_DIR/test/regvm-parity.sh"

api_files=( "$ROOT_DIR"/test/api/*.pt )
demo_files=( "$ROOT_DIR"/demo/*.pt )
if [ ! -f "${api_files[0]}" ]; then
    echo "api-run: no API programs found" >&2
    exit 1
fi
if [ ! -f "${demo_files[0]}" ]; then
    echo "api-run: no demo programs found" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d) || {
    echo "api-run: cannot create temp dir" >&2
    exit 1
}
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

total=0
cli_checks=0
failures=0

run_command() {
    label=$1
    require_all_ok=$2
    timeout_seconds=$3
    shift 3

    total=$((total + 1))
    stdout_file="$TMP_DIR/$total.out"
    stderr_file="$TMP_DIR/$total.err"
    if timeout --kill-after=1s "${timeout_seconds}s" "$@" \
        > "$stdout_file" 2> "$stderr_file"; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 0 ]; then
        failures=$((failures + 1))
        if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
            echo "FAIL (timeout): $label (exit=$status)" >&2
        else
            echo "FAIL: $label (exit=$status)" >&2
        fi
        cat "$stdout_file" >&2
        cat "$stderr_file" >&2
        return
    fi

    if [ "$require_all_ok" -eq 1 ] && ! grep -Fxq 'ALL-OK' "$stdout_file"; then
        failures=$((failures + 1))
        echo "FAIL (missing ALL-OK): $label" >&2
        cat "$stdout_file" >&2
        cat "$stderr_file" >&2
        return
    fi

    echo "PASS: $label"
}

run_cli_capture() {
    CLI_LABEL=$1
    stdin_file=$2
    shift 2

    cli_checks=$((cli_checks + 1))
    CLI_STDOUT="$TMP_DIR/cli-$cli_checks.out"
    CLI_STDERR="$TMP_DIR/cli-$cli_checks.err"
    if timeout --kill-after=1s "${CLI_TIMEOUT}s" "$@" \
        < "$stdin_file" > "$CLI_STDOUT" 2> "$CLI_STDERR"; then
        CLI_STATUS=0
    else
        CLI_STATUS=$?
    fi
}

cli_fail() {
    failures=$((failures + 1))
    echo "FAIL: $CLI_LABEL ($1, exit=$CLI_STATUS)" >&2
    cat "$CLI_STDOUT" >&2
    cat "$CLI_STDERR" >&2
}

cli_pass() {
    echo "PASS: $CLI_LABEL"
}

cli_expect_usage() {
    help_flag=$1
    run_cli_capture "cli/$help_flag" /dev/null \
        "$CLI" "$help_flag" "$TMP_DIR/help-source.pt"
    if [ "$CLI_STATUS" -ne 0 ]; then
        cli_fail "help failed"
    elif ! grep -q '^Usage:' "$CLI_STDOUT"; then
        cli_fail "usage missing"
    elif grep -Fq 'HELP-SOURCE-EXECUTED' "$CLI_STDOUT"; then
        cli_fail "help executed source"
    else
        cli_pass
    fi
}

cli_expect_input() {
    run_cli_capture "$@"
    if [ "$CLI_STATUS" -ne 0 ]; then
        cli_fail "input failed"
    elif ! grep -Fxq 'CLI-INPUT-OK' "$CLI_STDOUT"; then
        cli_fail "input was not executed"
    else
        cli_pass
    fi
}

printf '%s\n' '(display "CLI-INPUT-OK\n")' > "$TMP_DIR/input.pt"
printf '%s\n' '(display "CLI-INPUT-OK\n")' > "$TMP_DIR/-literal.pt"
printf '%s\n' '(display "CLI-INPUT-OK\n")' > "$TMP_DIR/-"
printf '%s\n' '(display "HELP-SOURCE-EXECUTED\n")' > "$TMP_DIR/help-source.pt"
printf '%s\n' '(display "DUPLICATE-INPUT-EXECUTED\n")' > "$TMP_DIR/duplicate.pt"

run_cli_capture "cli/no-args" /dev/null "$CLI"
if [ "$CLI_STATUS" -ne 0 ]; then
    cli_fail "no-argument usage failed"
elif ! grep -q '^Usage:' "$CLI_STDOUT"; then
    cli_fail "usage missing"
else
    cli_pass
fi

cli_expect_usage "--help"
cli_expect_usage "-h"

run_cli_capture "cli/unknown-option" /dev/null "$CLI" --unsupported-cli-option
if [ "$CLI_STATUS" -eq 0 ]; then
    cli_fail "unsupported option accepted"
elif [ ! -s "$CLI_STDERR" ]; then
    cli_fail "diagnostic missing"
elif grep -Eq 'FileNotFound|src/main\.zig:' "$CLI_STDERR"; then
    cli_fail "Zig error traceback"
else
    cli_pass
fi

run_cli_capture "cli/duplicate-input" /dev/null \
    "$CLI" "$TMP_DIR/duplicate.pt" "$TMP_DIR/duplicate.pt"
if [ "$CLI_STATUS" -eq 0 ]; then
    cli_fail "duplicate input accepted"
elif [ ! -s "$CLI_STDERR" ]; then
    cli_fail "diagnostic missing"
elif grep -Fq 'DUPLICATE-INPUT-EXECUTED' "$CLI_STDOUT"; then
    cli_fail "source executed before argument rejection"
elif grep -Eq 'FileNotFound|src/main\.zig:' "$CLI_STDERR"; then
    cli_fail "Zig error traceback"
else
    cli_pass
fi

cli_expect_input "cli/file-input" /dev/null "$CLI" "$TMP_DIR/input.pt"
cli_expect_input "cli/stdin-input" "$TMP_DIR/input.pt" "$CLI" -
cli_expect_input "cli/supported-options" /dev/null "$CLI" \
    --regvm --no-bytecode-opts --repl-no-highlight "$TMP_DIR/input.pt"
cli_expect_input "cli/end-of-options" /dev/null \
    bash -c 'cd -- "$1" || exit 1; exec "$2" -- -literal.pt' \
    bash "$TMP_DIR" "$CLI"
cli_expect_input "cli/end-of-options-dash" /dev/null \
    bash -c 'cd -- "$1" || exit 1; exec "$2" -- -' \
    bash "$TMP_DIR" "$CLI"

printf '%s\n' \
    '(defn (leaf)' \
    '  (fst 42))' \
    '(defn (middle)' \
    '  (+ 1 (leaf)))' \
    '(middle)' > "$TMP_DIR/error-context.pt"
run_cli_capture "cli/uncaught-system-trace" /dev/null \
    "$CLI" "$TMP_DIR/error-context.pt"
if [ "$CLI_STATUS" -ne 1 ]; then
    cli_fail "system error did not exit with status 1"
elif ! grep -Fq 'TypeMismatch' "$CLI_STDERR"; then
    cli_fail "system error name missing"
elif ! grep -Fq "$TMP_DIR/error-context.pt:2" "$CLI_STDERR"; then
    cli_fail "failing Skript source location missing"
elif ! grep -Eq '(^|[[:space:]])(at |in )?leaf([[:space:](]|:|$)' "$CLI_STDERR"; then
    cli_fail "leaf call frame missing"
elif ! grep -Eq '(^|[[:space:]])(at |in )?middle([[:space:](]|:|$)' "$CLI_STDERR"; then
    cli_fail "middle call frame missing"
elif grep -Fq '.zig' "$CLI_STDERR"; then
    cli_fail "Zig host frame exposed"
else
    cli_pass
fi

printf '%s\n' '(raise "marker")' > "$TMP_DIR/uncaught-raise.pt"
run_cli_capture "cli/uncaught-raise" /dev/null \
    "$CLI" "$TMP_DIR/uncaught-raise.pt"
if [ "$CLI_STATUS" -ne 1 ]; then
    cli_fail "uncaught raise did not exit with status 1"
elif ! grep -Eiq '(^|[[:space:]])(error|raised|payload|uncaught).*marker' "$CLI_STDERR"; then
    cli_fail "raised payload missing"
elif grep -Fq '.zig' "$CLI_STDERR"; then
    cli_fail "Zig host frame exposed"
else
    cli_pass
fi

for path in "${api_files[@]}"; do
    run_command "api/$(basename "$path")" 1 "$API_TIMEOUT" "$CLI" "$path"
done

for path in "${demo_files[@]}"; do
    run_command "demo/$(basename "$path")" 0 "$DEMO_TIMEOUT" "$CLI" "$path"
done

run_command "test/regvm-parity.sh" 0 "$PARITY_TIMEOUT" \
    env SKRIPT="$CLI" sh "$PARITY"

echo "api-run summary: total=$total cli_checks=$cli_checks failures=$failures"
if [ "$failures" -eq 0 ]; then
    exit 0
fi
exit 1
