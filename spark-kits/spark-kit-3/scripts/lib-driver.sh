#!/usr/bin/env bash
# lib-driver.sh - NVIDIA driver version comparison used by deploy.sh.
# Sourced by deploy.sh and tests/run-tests.sh so the comparison has real
# offline test coverage (string compare, not arithmetic).

# driver_meets_min HOST_VERSION MIN_VERSION
# Exit 0 when HOST_VERSION >= MIN_VERSION. Uses sort -V so dotted versions
# order correctly ("580.178.04" >= "580.00"; "526.14" < "580.00"; equal
# versions sort head-first, so equality passes).
driver_meets_min() {
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}
