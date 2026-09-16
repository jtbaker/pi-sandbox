#!/bin/sh
# Seed the ephemeral VM-local pi agent directory from the host's ~/.pi.
#
# The host's ~/.pi is mounted read-only at /root/.pi-host (see pi-sandbox.sh).
# The result, in $PI_CODING_AGENT_DIR (/root/.pi-agent), is ephemeral: it is
# recreated on every boot and destroyed when the VM exits. VM runs therefore
# never share or modify the host's ~/.pi.
#
# Invoked from /root/.zshenv, so it runs for EVERY zsh in the container
# (login or not). A marker makes the first run do the copy and every
# later run a fast no-op.
set -eu

SRC="${PI_HOST_DIR:-/root/.pi-host}"
DEST="${PI_CODING_AGENT_DIR:-/root/.pi-agent}"
PROFILE="/opt/pi-sandbox/sandbox.json.autonomous"
LOCK="${DEST}.lock"

# If the host agent dir isn't mounted, do nothing: pi falls back to
# defaults for $PI_CODING_AGENT_DIR (extension keys from env vars still work).
[ -d "$SRC/agent" ] || exit 0

# Already seeded this boot: fast no-op (DEST is VM-local, dies with the VM).
if [ -f "$DEST/.seeded" ]; then
    exit 0
fi

# Another zsh is seeding concurrently: wait (bounded) for it to finish.
if [ -d "$LOCK" ]; then
    i=0
    while [ ! -f "$DEST/.seeded" ]; do
        i=$((i + 1))
        [ "$i" -ge 60 ] && exit 0   # ~30s, don't block the shell forever
        sleep 0.5
    done
    exit 0
fi

mkdir -p "$DEST"
mkdir "$LOCK"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Wipe and recopy: deterministic, never serve stale state.
find "$DEST" -mindepth 1 -delete
cp -a "$SRC/agent/." "$DEST/"

# Autonomous runs should not list or resume host session history.
rm -rf "$DEST/sessions"

# Install the autonomous sandbox profile: blocked actions auto-abort in a
# few seconds instead of waiting for a human (see sandbox.json.autonomous).
if [ -f "$PROFILE" ]; then
    cp "$PROFILE" "$DEST/sandbox.json"
fi

touch "$DEST/.seeded"