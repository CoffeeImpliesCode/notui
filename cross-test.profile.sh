#!/usr/bin/env bash
# zig-gate section 9: the full test step on the native target, 32- and 64-bit
# little-endian, and 64-bit big-endian Linux. Non-native targets run under
# qemu-user; a missing runner fails the run instead of passing as build-only.
CROSS_MATRIX=(
  'x86_64-linux|auto'
  'x86-linux|auto'
  'aarch64-linux|auto'
  'powerpc64-linux|auto'
)
CROSS_BUILD_STEP=test
CROSS_JOBS=4
CROSS_BUILD_JOBS=2
# Emulated test runs are slow; the native suite takes about 20 s.
CROSS_TIMEOUT=900
CROSS_BUILD_TIMEOUT=2700
CROSS_PREFIX="${HOST_SCRATCH_ROOT:-${TMPDIR:?TMPDIR must name a private scratch root}}/notui-cross-test"
CROSS_REQUIRE_RUNNERS=1
