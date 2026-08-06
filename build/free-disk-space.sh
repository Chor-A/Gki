#!/usr/bin/env bash
set -euo pipefail

# free-disk-space.sh - fast disk-space cleanup for GitHub Actions runners.
#
# In-repo replacement for the third-party endersonmenezes/free-disk-space@v3
# action. It frees the same space in a fraction of the time:
#
#   * the upstream runs `apt-get remove` + `autoremove` + `clean` per package
#     (dozens of apt transactions, each with dependency resolution and
#     maintainer scripts), and deletes trees sequentially;
#   * this script deletes the packages' install trees directly. The runner is
#     throwaway and nothing reinstalls them, so the apt/dpkg bookkeeping is
#     pure overhead (files gone is all that matters for disk space).
#   * like the upstream's optional "rmz" (SUPERCILEX/fuc) mode, unlink runs in
#     parallel -- but without downloading an external binary. A single
#     xargs -P worker pool covers the top-level entries of every target at
#     once, so the big toolchains are deleted concurrently, which rmz does not
#     do either.
#
# Removes (mirrors the knobs the kernel workflow enables on the action):
#   android     /usr/local/lib/android /opt/android /usr/local/android-sdk /home/runner/Android
#   dotnet      /usr/share/dotnet /usr/lib/dotnet
#   haskell     /opt/ghc /usr/local/.ghcup /opt/cabal /home/runner/.ghcup /home/runner/.cabal
#   tool cache  /opt/hostedtoolcache (AGENT_TOOLSDIRECTORY)
#   packages    azure-cli google-cloud-cli microsoft-edge-stable
#               google-chrome-stable firefox postgresql-* temurin-* mysql-* dotnet-sdk-*
#   caches      /var/cache/apt/archives/* /var/lib/apt/lists/*
#               (the workflow runs `apt-get update` right after, so the lists
#               are re-downloaded on demand)
#
# Idempotent and safe to re-run: every removal is guarded by an existence
# check; missing targets and non-root invocations (sudo) are handled.
# FD_PARALLEL overrides the worker count (default: nproc, capped at 8).

info() { printf '\033[1;34m[FREE]\033[0m %s\n' "$*"; }

SUDO=()
if [ "$(id -u)" -ne 0 ]; then
    SUDO=(sudo)
fi

NP="${FD_PARALLEL:-$(nproc 2>/dev/null || echo 4)}"
if [ "$NP" -gt 8 ]; then
    NP=8
fi

pool=$(mktemp)
trap 'rm -f "$pool"' EXIT

free_bytes() {
    df -B1 --output=avail / | awk 'NR == 2 { print $1 }'
}

# enqueue: add a tree's top-level entries to the parallel pool. Depth-2 entries
# are used when present so the SDK/toolcache internals split across workers;
# otherwise depth-1 covers the target. Disjoint, so no rm ever races another.
enqueue() {
    local root
    for root in "$@"; do
        [ -e "$root" ] || continue
        if find "$root" -mindepth 2 -maxdepth 2 -print -quit 2>/dev/null | grep -q .; then
            find "$root" -mindepth 2 -maxdepth 2 -print0 2>/dev/null >> "$pool"
        else
            find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null >> "$pool"
        fi
    done
}

# remove_pool: run the accumulated entries through the worker pool, then wipe
# the (now nearly empty) roots in one call each.
remove_pool() {
    local root
    if [ -s "$pool" ]; then
        "${SUDO[@]}" xargs -0 -r -n 1 -P "$NP" rm -rf -- < "$pool" 2>/dev/null || true
    fi
    : > "$pool"
    for root in "${ROOTS[@]}"; do
        "${SUDO[@]}" rm -rf -- "$root" 2>/dev/null || true
    done
    ROOTS=()
}

ROOTS=()

before=$(free_bytes)

info "removing preinstalled toolchains (workers=$NP)"
ROOTS+=(/usr/local/lib/android /opt/android /usr/local/android-sdk /home/runner/Android)
ROOTS+=(/usr/share/dotnet /usr/lib/dotnet)
ROOTS+=(/opt/ghc /usr/local/.ghcup /opt/cabal /home/runner/.ghcup /home/runner/.cabal)
ROOTS+=("${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}")
enqueue "${ROOTS[@]}"
remove_pool

info "removing application install trees"
ROOTS+=(/opt/az /usr/lib/google-cloud-sdk)
ROOTS+=(/opt/google/chrome /opt/microsoft/msedge /usr/lib/firefox)
ROOTS+=(/usr/lib/jvm/temurin-*)
ROOTS+=(/usr/lib/postgresql /var/lib/postgresql /usr/lib/mysql /var/lib/mysql)
enqueue "${ROOTS[@]}"
remove_pool

info "removing apt caches"
ROOTS+=(/var/cache/apt/archives /var/lib/apt/lists)
enqueue "${ROOTS[@]}"
remove_pool

after=$(free_bytes)
info "freed $(( (after - before) / 1048576 )) MiB ($(( before / 1048576 )) -> $(( after / 1048576 )) MiB free)"
