#!/bin/sh
# Seed the ephemeral VM-local pi agent directory from the host copies.
#
# The host's ~/.pi is mounted read-only at /root/.pi-host and the host's
# ~/.omp at /root/.omp-host (see pi-sandbox.sh). The pi agent dir
# ($PI_CODING_AGENT_DIR, /root/.pi-agent) is seeded from ~/.pi/agent. If the
# VM runs omp instead of pi, the same script seeds it from ~/.omp/agent: omp
# honors PI_CODING_AGENT_DIR for the default profile (named profiles ignore
# it). The result is ephemeral: recreated on every boot and destroyed when
# the VM exits, so VM runs never share or modify the host's agent state.
#
# Invoked from /root/.zshenv, so it runs for EVERY zsh in the container
# (login or not). A marker makes the first run do the copy and every
# later run a fast no-op.
set -eu

PROFILE="/opt/pi-sandbox/sandbox.json.autonomous"

seed_one() {
    src="$1"; dest="$2"

    # If the host dir isn't mounted, do nothing: the agent falls back to
    # defaults for its dir (keys from env vars still work).
    [ -d "$src" ] || return 0

    # Already seeded this boot: fast no-op (dest is VM-local, dies with the VM).
    [ -f "$dest/.seeded" ] && return 0

    # Another zsh is seeding concurrently: wait (bounded) for it to finish.
    if [ -d "$dest.lock" ]; then
        i=0
        while [ ! -f "$dest/.seeded" ]; do
            i=$((i + 1))
            [ "$i" -ge 60 ] && return 0   # ~30s, don't block the shell forever
            sleep 0.5
        done
        return 0
    fi

    mkdir -p "$dest"
    mkdir "$dest.lock"
    trap 'rmdir "$dest.lock" 2>/dev/null || true' RETURN

    # Wipe and recopy: deterministic, never serve stale state.
    find "$dest" -mindepth 1 -delete
    cp -a "$src/." "$dest/"

    # Autonomous runs should not list or resume host session history: pi
    # keeps it in $dest/sessions; omp in $dest/sessions plus $dest/history.db
    # (SQLite). WAL sidecars stay with the main file.
    rm -rf "$dest/sessions" "$dest/terminal-sessions"
    rm -f "$dest/history.db" "$dest/history.db"-*
}

# Seed the shared agent dir: from the host pi copy if mounted, otherwise from
# the host omp copy (an omp-only run still gets host login state and models).
if [ -d "${PI_HOST_DIR:-/root/.pi-host}/agent" ]; then
    seed_one "${PI_HOST_DIR:-/root/.pi-host}/agent" "${PI_CODING_AGENT_DIR:-/root/.pi-agent}"
elif [ -d "${OMP_HOST_DIR:-/root/.omp-host}/agent" ]; then
    seed_one "${OMP_HOST_DIR:-/root/.omp-host}/agent" "${PI_CODING_AGENT_DIR:-/root/.pi-agent}"
fi

# Install the autonomous sandbox profile for pi: blocked actions auto-abort in
# a few seconds instead of waiting for a human (see sandbox.json.autonomous).
if [ -f "$PROFILE" ] && [ -d "${PI_CODING_AGENT_DIR:-/root/.pi-agent}" ]; then
    cp "$PROFILE" "${PI_CODING_AGENT_DIR:-/root/.pi-agent}/sandbox.json"
fi
