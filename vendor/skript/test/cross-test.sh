#!/usr/bin/env bash
set -uo pipefail

# Deterministic cross-target build and run harness.

die() {
  printf 'cross-test: %s\n' "$*" >&2
  exit 2
}

# Child processes inherit this limit; run workers also assert it before exec.
ulimit -c 0 || die 'cannot disable core dumps'

# target|runner. Runners are native, skip, wine, or an executable name.
MATRIX=(
  'x86_64-linux|native'
  'aarch64-freebsd|skip'
  'aarch64-linux|qemu-aarch64'
  'aarch64_be-linux|qemu-aarch64_be'
  'aarch64-macos|skip'
  'aarch64-netbsd|skip'
  'aarch64_be-netbsd|skip'
  'aarch64-openbsd|skip'
  'aarch64-windows|skip'
  'hexagon-linux|qemu-hexagon'
  'loongarch64-linux|qemu-loongarch64'
  'aarch64-linux-android|qemu-aarch64'
  'arm-linux|qemu-arm'
  'armeb-linux|qemu-armeb'
  'mips-linux|qemu-mips'
  'mipsel-linux|qemu-mipsel'
  'mips-netbsd|skip'
  'mipsel-netbsd|skip'
  'mips64-linux|qemu-mips64'
  'mips64el-linux|qemu-mips64el'
  'mips64-openbsd|skip'
  'mips64el-openbsd|skip'
  'powerpc-linux|qemu-ppc'
  'powerpc-netbsd|skip'
  'powerpc64-linux|qemu-ppc64'
  'powerpc64le-linux|qemu-ppc64le'
  'powerpc64-freebsd|skip'
  'powerpc64le-freebsd|skip'
  'powerpc64-openbsd|skip'
  'riscv32-linux|qemu-riscv32'
  'riscv64-linux|qemu-riscv64'
  'riscv64-openbsd|skip'
  's390x-linux|qemu-s390x'
  'thumb-windows|skip'
  # Zig 0.16's single-threaded test runner traps in Io.Threaded.futexWait at 32/911.
  # Atomics alone do not enable threads. A fixed threaded Zig stdlib and a
  # WASI-threads host (or nonblocking single-thread test IO) are required.
  'wasm32-wasi|skip'
  'x86-linux|native'
  'x86-netbsd|skip'
  'x86-openbsd|skip'
  'x86-windows|wine'
  'x86_64-freebsd|skip'
  'x86_64-maccatalyst|skip'
  'x86_64-macos|skip'
  'x86_64-netbsd|skip'
  'x86_64-openbsd|skip'
  'x86_64-windows|wine'
)

declare -a TARGET_ORDER=()
declare -A RUNNER_BY_TARGET=()
for entry in "${MATRIX[@]}"; do
  target=${entry%%|*}
  runner=${entry#*|}
  [[ "$entry" == *'|'* && -n "$target" && -n "$runner" ]] || die "invalid matrix row: $entry"
  [[ -z ${RUNNER_BY_TARGET[$target]+present} ]] || die "duplicate matrix target: $target"
  TARGET_ORDER+=("$target")
  RUNNER_BY_TARGET["$target"]="$runner"
done

# TARGETS accepts either a whitespace-separated value or an indexed Bash array.
target_decl="$(declare -p TARGETS 2>/dev/null || true)"
if [[ -z "$target_decl" ]]; then
  TARGETS=("${TARGET_ORDER[@]}")
else
  requested=()
  if [[ "$target_decl" == declare\ -a* ]]; then
    requested=("${TARGETS[@]}")
  elif [[ "$target_decl" == declare\ -A* ]]; then
    die 'TARGETS must be a scalar or indexed array'
  else
    read -r -a requested <<< "${TARGETS-}"
  fi
  ((${#requested[@]} > 0)) || die 'TARGETS must name at least one declared target'

  declare -A selected=()
  for target in "${requested[@]}"; do
    [[ -n ${RUNNER_BY_TARGET[$target]+present} ]] || die "unknown target: $target"
    [[ -z ${selected[$target]+present} ]] || die "duplicate target: $target"
    selected["$target"]=1
  done
  TARGETS=()
  for target in "${TARGET_ORDER[@]}"; do
    [[ -n ${selected[$target]+present} ]] && TARGETS+=("$target")
  done
fi

positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer (got '$2')"
}

if [[ -n ${CROSS_JOBS:-} ]]; then
  JOBS=$CROSS_JOBS
elif [[ -n ${MAX_JOBS:-} ]]; then
  JOBS=$MAX_JOBS
else
  JOBS=2
fi
ZIG_JOBS_PER_BUILD=${ZIG_JOBS:-1}
if [[ -n ${CROSS_TIMEOUT:-} ]]; then
  RUN_TIMEOUT_SECONDS=$CROSS_TIMEOUT
elif [[ -n ${RUN_TIMEOUT:-} ]]; then
  RUN_TIMEOUT_SECONDS=$RUN_TIMEOUT
else
  RUN_TIMEOUT_SECONDS=300
fi
positive_integer CROSS_JOBS "$JOBS"
positive_integer ZIG_JOBS "$ZIG_JOBS_PER_BUILD"
positive_integer CROSS_TIMEOUT "$RUN_TIMEOUT_SECONDS"
command -v timeout >/dev/null 2>&1 || die 'timeout command is required'
command -v awk >/dev/null 2>&1 || die 'awk command is required'

BUILD_DIR='./zig-out'
mkdir -p "$BUILD_DIR" || die "cannot create $BUILD_DIR"
RUN_ID=${CROSS_RUN_ID:-"$(date -u +%Y%m%d-%H%M%S)-$$"}
[[ "$RUN_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'CROSS_RUN_ID contains unsafe path characters'
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SUMMARY_PATH="$BUILD_DIR/cross-test-summary.json"
STATE_DIR="$BUILD_DIR/.cross-test-state-${RUN_ID}-$$"
mkdir "$STATE_DIR" || die "cannot create $STATE_DIR"

declare -A BUILD_STATUS BUILD_EXIT BUILD_REASON
declare -A RUN_STATUS RUN_EXIT RUN_TESTS RUN_REASON FINAL_STATUS
for target in "${TARGETS[@]}"; do
  BUILD_STATUS["$target"]='pending'
  BUILD_EXIT["$target"]=''
  BUILD_REASON["$target"]='pending'
  RUN_STATUS["$target"]='pending'
  RUN_EXIT["$target"]=''
  RUN_TESTS["$target"]=''
  RUN_REASON["$target"]='pending'
done
BOOKKEEPING_FAILURE=0
pass_count=0
fail_count=0
skip_count=0

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

json_number_or_null() {
  [[ -n $1 ]] && printf '%s' "$1" || printf 'null'
}

publish_summary() {
  local overall=$1 overall_exit=$2
  local temp="${SUMMARY_PATH}.tmp.${RUN_ID}.$$"
  local target first=1 tests bookkeeping=false
  ((BOOKKEEPING_FAILURE == 0)) || bookkeeping=true
  if ! {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "run_id": "%s",\n' "$(json_escape "$RUN_ID")"
    printf '  "generated_at": "%s",\n' "$(json_escape "$GENERATED_AT")"
    printf '  "build_jobs": %s,\n' "$JOBS"
    printf '  "zig_jobs_per_build": %s,\n' "$ZIG_JOBS_PER_BUILD"
    printf '  "timeout_seconds": %s,\n' "$RUN_TIMEOUT_SECONDS"
    printf '  "target_count": %d,\n' "${#TARGETS[@]}"
    printf '  "bookkeeping_failure": %s,\n' "$bookkeeping"
    printf '  "targets": [\n'
    for target in "${TARGETS[@]}"; do
      ((first == 1)) || printf ',\n'
      first=0
      tests=$(json_number_or_null "${RUN_TESTS[$target]}")
      printf '    {"target":"%s","build":{"status":"%s","exit":%s,"reason":"%s","log":"%s"},"run":{"status":"%s","exit":%s,"tests":%s,"reason":"%s","log":"%s"},"status":"%s"}' \
        "$(json_escape "$target")" \
        "$(json_escape "${BUILD_STATUS[$target]}")" "$(json_number_or_null "${BUILD_EXIT[$target]}")" \
        "$(json_escape "${BUILD_REASON[$target]}")" "$(json_escape "$BUILD_DIR/build-${target}-${RUN_ID}.log")" \
        "$(json_escape "${RUN_STATUS[$target]}")" "$(json_number_or_null "${RUN_EXIT[$target]}")" "$tests" \
        "$(json_escape "${RUN_REASON[$target]}")" "$(json_escape "$BUILD_DIR/run-${target}-${RUN_ID}.log")" \
        "$(json_escape "${FINAL_STATUS[$target]:-pending}")"
    done
    printf '\n  ],\n'
    printf '  "counts": {"pass":%d,"fail":%d,"skip":%d},\n' "$pass_count" "$fail_count" "$skip_count"
    printf '  "status": "%s",\n' "$(json_escape "$overall")"
    printf '  "exit_code": %s\n' "$(json_number_or_null "$overall_exit")"
    printf '}\n'
  } > "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  mv -f -- "$temp" "$SUMMARY_PATH" || { rm -f -- "$temp"; return 1; }
}

publish_summary running '' || die 'cannot publish current-run summary marker'
for target in "${TARGETS[@]}"; do
  for phase in build run; do
    printf 'run_id=%s target=%s phase=%s\n' "$RUN_ID" "$target" "$phase" \
      > "$BUILD_DIR/${phase}-${target}-${RUN_ID}.log" || die "cannot create $phase log for $target"
  done
done

exe_path() {
  case $1 in
    *-windows) printf '%s/bin/skript-test-%s.exe\n' "$BUILD_DIR" "$1" ;;
    wasm32-wasi) printf '%s/bin/skript-test-%s.wasm\n' "$BUILD_DIR" "$1" ;;
    *) printf '%s/bin/skript-test-%s\n' "$BUILD_DIR" "$1" ;;
  esac
}

print_command() {
  local arg
  for arg in "$@"; do printf '%q ' "$arg"; done
  printf '\n'
}

append_result() {
  local phase=$1 target=$2 status=$3 rc=$4 tests=$5 reason=$6
  if [[ "$phase" == build ]]; then
    printf 'build_status=%s exit=%s\nreason=%s\n' "$status" "$rc" "$reason" \
      >> "$BUILD_DIR/build-${target}-${RUN_ID}.log"
  else
    printf 'run_status=%s exit=%s tests=%s\nreason=%s\n' "$status" "$rc" "$tests" "$reason" \
      >> "$BUILD_DIR/run-${target}-${RUN_ID}.log"
  fi
}

write_status() {
  local phase=$1 target=$2 status=$3 rc=$4 tests=$5 reason=$6
  printf '%s\t%s\t%s\t%s\n' "$status" "$rc" "$tests" "$reason" \
    > "$STATE_DIR/${phase}-${target}.status"
}

finish_worker() {
  local phase=$1 target=$2 status=$3 rc=$4 tests=$5 reason=$6
  local log_rc=0 state_rc=0
  append_result "$phase" "$target" "$status" "$rc" "$tests" "$reason" || log_rc=$?
  write_status "$phase" "$target" "$status" "$rc" "$tests" "$reason" || state_rc=$?
  ((log_rc == 0 && state_rc == 0))
}

count_test_cases() {
  awk '$1 ~ /^[0-9]+\/[0-9]+$/ { split($1, fields, "/"); total = fields[2] } END { print total + 0 }' "$1"
}

build_target() {
  local target=$1 log="$BUILD_DIR/build-${1}-${RUN_ID}.log" exe rc
  exe=$(exe_path "$target")
  if ! {
    printf 'artifact=%s\ncommand=' "$exe"
    print_command zig build "-j${ZIG_JOBS_PER_BUILD}" test-compile "-Dtarget=$target" --prefix "$BUILD_DIR"
  } >> "$log"; then
    finish_worker build "$target" fail 125 - log_write_failed
    return 125
  fi
  if rm -f -- "$exe" >> "$log" 2>&1; then
    :
  else
    rc=$?
    finish_worker build "$target" fail "$rc" - artifact_remove_failed || return 125
    return "$rc"
  fi
  if zig build "-j${ZIG_JOBS_PER_BUILD}" test-compile "-Dtarget=$target" --prefix "$BUILD_DIR" >> "$log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if ((rc != 0)); then
    finish_worker build "$target" fail "$rc" - compiler_failed || return 125
    return "$rc"
  fi
  if [[ ! -f "$exe" ]]; then
    finish_worker build "$target" missing_binary 1 - compiler_succeeded_without_artifact || return 125
    return 1
  fi
  finish_worker build "$target" pass 0 - compiled || return 125
}

runner_available() {
  case $1 in
    native|skip) return 0 ;;
    wine) command -v wine >/dev/null 2>&1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

run_target() {
  local target=$1 runner=${RUNNER_BY_TARGET[$1]}
  local log="$BUILD_DIR/run-${1}-${RUN_ID}.log" exe rc tests status reason
  local -a command=()
  exe=$(exe_path "$target")
  if ! ulimit -c 0; then
    finish_worker run "$target" fail 125 - core_limit_failed
    return 125
  fi
  if [[ ! -f "$exe" ]]; then
    finish_worker run "$target" missing_binary 125 0 build_artifact_missing || return 125
    return 125
  fi
  if [[ "$runner" == native && ! -x "$exe" ]]; then
    finish_worker run "$target" unavailable 126 0 binary_not_executable || return 125
    return 126
  fi
  case $runner in
    native) command=("$exe") ;;
    wine) command=(env WINEDEBUG=-all wine "$exe") ;;
    skip)
      finish_worker run "$target" fail 125 - invalid_runner_state
      return 125
      ;;
    *) command=("$runner" "$exe") ;;
  esac
  if ! {
    printf 'artifact=%s timeout_seconds=%s\ncommand=' "$exe" "$RUN_TIMEOUT_SECONDS"
    print_command "${command[@]}"
  } >> "$log"; then
    finish_worker run "$target" fail 125 - log_write_failed
    return 125
  fi
  if timeout --kill-after=5s "${RUN_TIMEOUT_SECONDS}s" "${command[@]}" >> "$log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if ! tests=$(count_test_cases "$log") || [[ ! "$tests" =~ ^[0-9]+$ ]]; then
    tests=0
    rc=1
    status=fail
    reason=test_count_failed
  elif ((rc == 0)); then
    if ((tests == 0)); then
      rc=1
      status=fail
      reason=no_tests_executed
    else
      status=pass
      reason=tests_complete
    fi
  elif ((rc == 124)); then
    status=timeout
    reason=per_run_timeout
  else
    status=fail
    reason=runner_failed
  fi
  finish_worker run "$target" "$status" "$rc" "$tests" "$reason" || return 125
  return "$rc"
}

valid_status_record() {
  local phase=$1 status=$2 recorded_rc=$3 tests=$4 reason=$5 waited_rc=$6
  [[ "$recorded_rc" =~ ^[0-9]+$ && "$recorded_rc" -eq "$waited_rc" && -n "$reason" ]] || return 1
  case "$phase:$status" in
    build:pass) ((recorded_rc == 0)) && [[ "$tests" == - ]] ;;
    build:fail|build:missing_binary) ((recorded_rc != 0)) && [[ "$tests" == - ]] ;;
    run:pass) ((recorded_rc == 0)) && [[ "$tests" =~ ^[0-9]+$ ]] ;;
    run:timeout) ((recorded_rc == 124)) && [[ "$tests" =~ ^[0-9]+$ ]] ;;
    run:fail|run:unavailable|run:missing_binary)
      ((recorded_rc != 0)) && [[ "$tests" == - || "$tests" =~ ^[0-9]+$ ]]
      ;;
    *) return 1 ;;
  esac
}

declare -a PIDS=() PID_TARGETS=()
collect_batch() {
  local phase=$1 index pid target waited_rc state
  local status recorded_rc tests reason extra
  for index in "${!PIDS[@]}"; do
    pid=${PIDS[$index]}
    target=${PID_TARGETS[$index]}
    if wait "$pid"; then waited_rc=0; else waited_rc=$?; fi
    state="$STATE_DIR/${phase}-${target}.status"
    status= recorded_rc= tests= reason= extra=
    if [[ -r "$state" ]] &&
      IFS=$'\t' read -r status recorded_rc tests reason extra < "$state" &&
      [[ -z "$extra" ]] &&
      valid_status_record "$phase" "$status" "$recorded_rc" "$tests" "$reason" "$waited_rc"; then
      :
    else
      status=fail
      recorded_rc=$waited_rc
      tests=-
      reason=missing_status_record
      BOOKKEEPING_FAILURE=1
    fi
    if [[ "$phase" == build ]]; then
      BUILD_STATUS["$target"]=$status
      BUILD_EXIT["$target"]=$recorded_rc
      if [[ "$status" == missing_binary ]]; then
        BUILD_REASON["$target"]=missing_binary
      else
        BUILD_REASON["$target"]=$reason
      fi
      printf 'cross-test: target=%s build=%s exit=%s log=%s\n' \
        "$target" "$status" "$recorded_rc" "$BUILD_DIR/build-${target}-${RUN_ID}.log"
    else
      RUN_STATUS["$target"]=$status
      RUN_EXIT["$target"]=$recorded_rc
      if [[ "$status" == pass || "$status" == timeout ]] && [[ "$tests" =~ ^[0-9]+$ ]]; then
        RUN_TESTS["$target"]=$tests
      else
        RUN_TESTS["$target"]=''
      fi
      RUN_REASON["$target"]=$reason
      printf 'cross-test: target=%s run=%s exit=%s tests=%s log=%s\n' \
        "$target" "$status" "$recorded_rc" "${RUN_TESTS[$target]:-0}" "$BUILD_DIR/run-${target}-${RUN_ID}.log"
    fi
  done
  PIDS=()
  PID_TARGETS=()
}
record_parent_run() {
  local target=$1 status=$2 rc=$3 reason=$4
  local log_rc=$rc
  RUN_STATUS["$target"]=$status
  if [[ "$rc" == - ]]; then
    RUN_EXIT["$target"]=''
    log_rc=null
  else
    RUN_EXIT["$target"]=$rc
  fi
  RUN_TESTS["$target"]=''
  RUN_REASON["$target"]=$reason
  append_result run "$target" "$status" "$log_rc" 0 "$reason" || BOOKKEEPING_FAILURE=1
}

printf 'cross-test: run_id=%s targets=%d jobs=%s zig_jobs=%s timeout=%ss\n' \
  "$RUN_ID" "${#TARGETS[@]}" "$JOBS" "$ZIG_JOBS_PER_BUILD" "$RUN_TIMEOUT_SECONDS"
printf 'cross-test: build phase\n'
for target in "${TARGETS[@]}"; do
  (build_target "$target") &
  PIDS+=("$!")
  PID_TARGETS+=("$target")
  ((${#PIDS[@]} < JOBS)) || collect_batch build
done
((${#PIDS[@]} == 0)) || collect_batch build

printf 'cross-test: run phase\n'
for target in "${TARGETS[@]}"; do
  if [[ ${BUILD_STATUS[$target]} != pass ]]; then
    record_parent_run "$target" not_run - build_failed
    continue
  fi
  runner=${RUNNER_BY_TARGET[$target]}
  if [[ "$runner" == skip ]]; then
    record_parent_run "$target" skip 0 runner_policy_skip
    continue
  fi
  if ! runner_available "$runner"; then
    record_parent_run "$target" unavailable 127 runner_unavailable
    continue
  fi
  (run_target "$target") &
  PIDS+=("$!")
  PID_TARGETS+=("$target")
  ((${#PIDS[@]} < JOBS)) || collect_batch run
done
((${#PIDS[@]} == 0)) || collect_batch run

for target in "${TARGETS[@]}"; do
  if [[ ${BUILD_STATUS[$target]} != pass ]]; then
    FINAL_STATUS["$target"]=fail
  elif [[ ${RUN_STATUS[$target]} == pass ]]; then
    FINAL_STATUS["$target"]=pass
  elif [[ ${RUN_STATUS[$target]} == skip ]]; then
    FINAL_STATUS["$target"]=skip
  else
    FINAL_STATUS["$target"]=fail
  fi
  case ${FINAL_STATUS[$target]} in
    pass) ((pass_count += 1)) ;;
    fail) ((fail_count += 1)) ;;
    skip) ((skip_count += 1)) ;;
  esac
done

if ((BOOKKEEPING_FAILURE != 0 || fail_count > 0)); then
  overall_status=fail
  overall_exit=1
elif ((pass_count == 0)); then
  overall_status=skip
  overall_exit=0
else
  overall_status=pass
  overall_exit=0
fi

printf 'cross-test: summary\n'
for target in "${TARGETS[@]}"; do
  printf 'cross-test: target=%s build=%s run=%s status=%s\n' \
    "$target" "${BUILD_STATUS[$target]}" "${RUN_STATUS[$target]}" "${FINAL_STATUS[$target]}"
done
publish_summary "$overall_status" "$overall_exit" || {
  printf 'cross-test: cannot publish current-run summary at %s\n' "$SUMMARY_PATH" >&2
  exit 1
}
printf 'cross-test: status=%s pass=%d fail=%d skip=%d summary=%s\n' \
  "$overall_status" "$pass_count" "$fail_count" "$skip_count" "$SUMMARY_PATH"
exit "$overall_exit"
