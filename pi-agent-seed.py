#!/usr/bin/python3
"""Snapshot read-only host configuration into private, VM-local agent roots."""

from contextlib import closing
import fcntl
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import sys
import tempfile
import time

HOST_ROOTS = ((Path("/root/.pi-host"), Path("/root/.pi")),
              (Path("/root/.omp-host"), Path("/root/.omp")))
SKIP_DIRS = {"sessions", "terminal-sessions", "cache", "caches", "logs", "bin",
             "__pycache__", ".git"}
# Host runtime trees are not configuration. Limit this rule to config roots
# so portable extension/package directories with these names remain intact.
RUNTIME_DIRS = {"run", "ssh-control", "puppeteer", "natives", ".supervisor"}
PROFILE = Path("/opt/pi-sandbox/sandbox.json.autonomous")
MARKER = Path("/run/pi-sandbox.seeded")
NETWORK_MARKER = Path("/run/pi-sandbox-network.json")


def backup_database(source, destination):
    # SQLite's backup API includes committed WAL data without copying a live
    # database and its journal at different instants. Never open the host RW.
    deadline = time.monotonic() + 30

    def progress(status, remaining, total):
        if time.monotonic() > deadline:
            raise TimeoutError("database snapshot exceeded 30 seconds")

    try:
        with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as src:
            # Pin one committed WAL snapshot for the entire backup. Without a
            # read transaction, each batch can restart when the host writes.
            src.execute("BEGIN")
            src.execute("SELECT 1 FROM sqlite_schema LIMIT 1").fetchall()
            with closing(sqlite3.connect(destination)) as dst:
                src.backup(dst, pages=256, progress=progress)
    except (sqlite3.Error, TimeoutError) as error:
        raise RuntimeError(f"SQLite snapshot failed for {source}: {error}") from error


def copy_tree(source, destination, relative=Path()):
    destination.mkdir(mode=0o700)
    config_root = not relative.parts or (
        len(relative.parts) == 2 and relative.parts[0] == "profiles")
    for entry in source.iterdir():
        mode = entry.lstat().st_mode
        target = destination / entry.name
        # Do not follow host symlinks or import sockets/devices/FIFOs.
        if stat.S_ISDIR(mode):
            if entry.name not in SKIP_DIRS and not (
                    config_root and entry.name in RUNTIME_DIRS):
                copy_tree(entry, target, relative / entry.name)
        elif stat.S_ISREG(mode):
            if (entry.name.startswith(("history.db", "trust.db"))
                    or entry.name in {"trust.json", ".seeded"}
                    or entry.name.endswith((".db-wal", ".db-shm", ".db-journal"))):
                continue
            if entry.suffix == ".db":
                backup_database(entry, target)
            else:
                # O_NOFOLLOW also rejects a file replaced by a symlink since
                # lstat; O_NONBLOCK avoids hanging if it became a FIFO.
                fd = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as src:
                    if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
                        raise RuntimeError("configuration source is not a regular file")
                    with target.open("xb") as dst:
                        shutil.copyfileobj(src, dst)
            os.chmod(target, 0o700 if mode & stat.S_IXUSR else 0o600)


def seed():
    if not NETWORK_MARKER.is_file():
        raise RuntimeError("network policy was not initialized; launch through pi-sandbox.sh")
    os.umask(0o077)
    with open("/run/pi-sandbox-seed.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if MARKER.exists():
            return
        # Stage both roots before installing either. Failure stops boot rather
        # than opening a shell with a partial or mixed authentication snapshot.
        with tempfile.TemporaryDirectory(prefix=".pi-sandbox-seed-", dir="/root") as tmp:
            staged = []
            for source, destination in HOST_ROOTS:
                if destination.exists() or destination.is_symlink():
                    raise RuntimeError(f"refusing to replace existing {destination}")
                snapshot = Path(tmp) / destination.name
                if source.exists():
                    if not source.is_dir() or source.is_symlink():
                        raise RuntimeError(f"configuration mount is not a directory: {source}")
                    copy_tree(source, snapshot)
                else:
                    snapshot.mkdir(mode=0o700)
                agent = snapshot / "agent"
                agent.mkdir(mode=0o700, exist_ok=True)
                if destination.name == ".pi":
                    shutil.copyfile(PROFILE, agent / "sandbox.json")
                    os.chmod(agent / "sandbox.json", 0o600)
                staged.append((snapshot, destination))
            for snapshot, destination in staged:
                snapshot.rename(destination)
        MARKER.touch(mode=0o600)


if __name__ == "__main__":
    try:
        seed()
    except Exception as error:
        # Our RuntimeError messages describe paths/operations, never file data.
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"pi-sandbox: configuration seeding failed: {detail}", file=sys.stderr)
        sys.exit(1)
    command = sys.argv[1:] or ["zsh", "-l"]
    # Keep only filesystem permissions needed to edit host-owned workspace
    # files. Network, raw-socket, namespace, and privilege-escalation capabilities
    # must not reach agents, extensions, or shell commands.
    os.execv("/usr/bin/setpriv", [
        "setpriv", "--bounding-set=-all,+dac_override,+fowner", "--inh-caps=-all",
        "--ambient-caps=-all", "--no-new-privs", "--", *command,
    ])
