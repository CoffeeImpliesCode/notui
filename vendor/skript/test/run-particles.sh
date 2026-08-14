#!/usr/bin/env sh
# run-particles.sh — concatenate library and demo, pipe to skript
cd "$(dirname "$0")"/..
cat lib/raylib.pt test/particles.pt | zig build run -Doptimize=ReleaseSafe -- -
