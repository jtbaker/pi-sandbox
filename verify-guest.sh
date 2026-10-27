#!/usr/bin/env bash
# Build and boot the working tree without publishing. Only synthetic host
# configuration is mounted; neither ~/.pi nor ~/.omp is read or changed.
# Reuse a local Docker archive with PI_SANDBOX_VERIFY_IMAGE_TAR=/path/image.tar.
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pi-sandbox-verify.XXXXXXXX")"
cleanup() {
    local result=$?
    if [[ "$result" != 0 ]]; then
        printf 'Synthetic fixture diagnostics retained at %s\n' "$TMP" >&2
    else
        rm -rf -- "$TMP"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "FAIL: verifier command failed at line %s\n" "$LINENO" >&2' ERR

command -v smolvm >/dev/null 2>&1 || fail 'smolvm is required'
IMAGE_TAR="${PI_SANDBOX_VERIFY_IMAGE_TAR:-}"
if [[ -n "$IMAGE_TAR" ]]; then
    [[ -f "$IMAGE_TAR" ]] || fail 'PI_SANDBOX_VERIFY_IMAGE_TAR is not a file'
    IMAGE_TAR="$(cd "$(dirname "$IMAGE_TAR")" && pwd)/$(basename "$IMAGE_TAR")"
else
    command -v docker >/dev/null 2>&1 || fail 'docker with buildx is required'
    case "$(uname -m)" in
        arm64|aarch64) ARCH=arm64 ;;
        x86_64|amd64) ARCH=amd64 ;;
        *) fail 'unsupported host architecture' ;;
    esac
    IMAGE_TAR="$TMP/image.tar"
    # Use the existing selected builder without creating, selecting, or removing
    # any builder. Docker output embeds the manifest and layers smolvm needs.
    if ! docker buildx build --progress quiet --platform "linux/$ARCH" \
        -f "$REPO/Dockerfile.pi" --output "type=docker,dest=$IMAGE_TAR" \
        "$REPO" > "$TMP/build.log" 2>&1; then
        fail 'working-tree Docker image build failed'
    fi
    printf 'PASS: working-tree image built locally without publishing\n'
fi
if ! tar -tf "$IMAGE_TAR" > "$TMP/archive-members" 2>/dev/null; then
    fail 'image archive cannot be read'
fi
grep -Eq '^(\./)?manifest\.json$' "$TMP/archive-members" \
    || fail 'image archive is not Docker-compatible (manifest.json missing)'
printf 'PASS: Docker-compatible image archive\n'

mkdir -p "$TMP/fixtures" "$TMP/control" "$TMP/workspace" "$TMP/default-workspace" "$TMP/preparation-workspace"
for workspace in "$TMP/workspace" "$TMP/default-workspace" "$TMP/preparation-workspace"; do
    printf 'host workspace content\n' > "$workspace/editable-host-file"
done
printf '{"tailnetHost":"100.64.0.10","httpsPort":443}\n' > "$TMP/control/network.json"
cat > "$TMP/Smolfile" <<'SMOLFILE'
net = true

[dev]
init = [
    "/usr/local/bin/pi-network-policy.py /verify/network.json",
    "/usr/bin/python3 /verify/network-fixtures.py init",
]
SMOLFILE
cat > "$TMP/control/network-fixtures.py" <<'NETWORK'
import errno
import json
import socket
import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path


PROOF = Path("/run/pi-sandbox-fixture-network.json")
PAYLOAD = b"pi-sandbox-local-network-fixture\n"
DROP = [
    "/usr/bin/setpriv", "--bounding-set=-all,+dac_override,+fowner", "--inh-caps=-all",
    "--ambient-caps=-all", "--no-new-privs", "/usr/bin/python3", __file__,
]


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def reject_packets():
    ruleset = json.loads(command("nft", "-j", "list", "chain", "inet", "pi_sandbox", "egress"))
    return sum(
        expression["counter"]["packets"]
        for item in ruleset["nftables"] if "rule" in item
        for expression in item["rule"]["expr"] if "counter" in expression
        if any("reject" in part for part in item["rule"]["expr"])
    )


def probe(address, port, allowed):
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        try:
            client.connect((address, port))
        except OSError as error:
            if allowed:
                raise AssertionError("configured TCP443 fixture was not reachable") from error
            return
        assert allowed, "forbidden fixture connection succeeded"
        assert client.recv(128) == PAYLOAD, "fixture listener payload mismatch"


def workload():
    status = dict(
        line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines()
        if ":" in line
    )
    for name in ("CapEff", "CapBnd", "CapPrm"):
        assert int(status[name].strip(), 16) == 0xA, f"{name} exceeds filesystem-only permissions"
    for name in ("CapAmb", "CapInh"):
        assert int(status[name].strip(), 16) == 0, f"{name} is not zero"
    assert status["NoNewPrivs"].strip() == "1", "NoNewPrivs is not enabled"
    editable = Path("/workspace/editable-host-file")
    editable.write_text("guest workspace edit\n")
    editable.chmod(0o600)
    assert editable.read_text() == "guest workspace edit\n"
    denied = subprocess.run(
        ["nft", "add", "table", "inet", "pi_sandbox_bypass"],
        capture_output=True, text=True,
    )
    assert denied.returncode != 0, "capability-dropped workload modified nftables"
    assert any(text in denied.stderr.lower() for text in ("not permitted", "permission denied")), (
        "nft modification failed for a reason other than missing privilege"
    )
    for family, kind, protocol in (
        (socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3)),
        (socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP),
        (socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6),
    ):
        try:
            raw = socket.socket(family, kind, protocol)
        except OSError as error:
            assert error.errno in (errno.EPERM, errno.EACCES), (
                "raw socket failed for a reason other than missing privilege"
            )
        else:
            raw.close()
            raise AssertionError("capability-dropped workload created a packet/raw socket")
    proof = json.loads(PROOF.read_text())
    assert proof["allowedTCP443"] is True
    assert proof["allowedPublicTCP443"] is True
    assert proof["deniedIPv4"] == ["100.64.0.10:22", "100.64.0.11:443"]
    assert all(delta >= 1 for delta in proof["rejectCounterDeltas"])
    assert len(proof["rejectCounterDeltas"]) == 2 + int(proof["ipv6Route"])
    marker = json.loads(Path("/run/pi-sandbox-network.json").read_text())
    assert marker["tailnetHost"] == "100.64.0.10"
    assert marker["httpsPort"] == 443
    assert marker["allowedIPv4"] == ["100.64.0.10"] and marker["allowedIPv6"] == []
    print("PASS: network: local Tailscale-address fixture accepts only configured TCP443")
    print("PASS: network: simulated public IPv4 fixture accepts TCP443 through kernel policy")
    print("PASS: network: forbidden Tailscale IPv4 probes increment kernel reject counters")
    if proof["ipv6Route"]:
        print("PASS: network: forbidden Tailscale IPv6 probe increments kernel reject counter")
    else:
        print("PASS: network: IPv6 route absence recorded; IPv4 kernel reject proofs enforced")
    print("PASS: network: filesystem-only capabilities preserve workspace edits; nft and raw sockets denied")


def trusted_init():
    # This disposable network exists only during trusted init. It is not an
    # external server, a real tailnet peer, or a privileged background daemon.
    namespace = "pi-verify-peer"
    host = "pi-verify-host"
    peer = "pi-verify-peer"
    server = None
    created_namespace = False
    created_link = False
    try:
        command("ip", "netns", "add", namespace)
        created_namespace = True
        command("ip", "link", "add", host, "type", "veth", "peer", "name", peer)
        created_link = True
        command("ip", "link", "set", peer, "netns", namespace)
        command("ip", "address", "add", "100.64.0.1/24", "dev", host)
        command("ip", "link", "set", host, "up")
        command("ip", "netns", "exec", namespace, "ip", "link", "set", "lo", "up")
        command("ip", "netns", "exec", namespace, "ip", "address", "add",
                "100.64.0.10/24", "dev", peer)
        command("ip", "netns", "exec", namespace, "ip", "link", "set", peer, "up")
        # 1.1.1.1 is assigned solely inside this guest-owned namespace. Its
        # exact /32 route points across our veth, never to the real Internet.
        command("ip", "netns", "exec", namespace, "ip", "address", "add",
                "1.1.1.1/32", "dev", "lo")
        command("ip", "route", "add", "1.1.1.1/32", "via", "100.64.0.10", "dev", host)
        server = subprocess.Popen(
            ["ip", "netns", "exec", namespace, "/usr/bin/python3", __file__, "serve"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        assert server.stdout.readline() == "ready\n", "local fixture listener did not start"
        subprocess.run([*DROP, "probe", "100.64.0.10", "443", "allow"], check=True)
        subprocess.run([*DROP, "probe", "1.1.1.1", "443", "allow"], check=True)
        assert server.wait(timeout=5) == 0, "local fixture listener did not complete"
        proof = {
            "allowedTCP443": True, "allowedPublicTCP443": True,
            "deniedIPv4": [], "rejectCounterDeltas": [],
            "ipv6Route": False,
        }
        for address, port in (("100.64.0.10", 22), ("100.64.0.11", 443)):
            before = reject_packets()
            subprocess.run([*DROP, "probe", address, str(port), "deny"], check=True)
            delta = reject_packets() - before
            assert delta >= 1, "forbidden IPv4 probe did not hit a kernel reject rule"
            proof["rejectCounterDeltas"].append(delta)
            proof["deniedIPv4"].append(f"{address}:{port}")
        # An explicit fixture route makes IPv6 deterministic when the kernel
        # enables it. Disabled IPv6 has no route and is recorded, not faked.
        ipv6_disabled = Path("/proc/sys/net/ipv6/conf/all/disable_ipv6")
        if ipv6_disabled.exists() and ipv6_disabled.read_text().strip() == "0":
            command("ip", "-6", "address", "add", "fd7a:115c:a1e0::a/64",
                    "dev", host, "nodad")
        route = subprocess.run(
            ["ip", "-6", "route", "get", "fd7a:115c:a1e0::b"],
            capture_output=True, text=True,
        )
        if route.returncode == 0:
            before = reject_packets()
            subprocess.run(
                [*DROP, "probe", "fd7a:115c:a1e0::b", "443", "deny"], check=True,
            )
            delta = reject_packets() - before
            assert delta >= 1, "forbidden IPv6 probe did not hit a kernel reject rule"
            proof["rejectCounterDeltas"].append(delta)
            proof["ipv6Route"] = True
        PROOF.write_text(json.dumps(proof))
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            server.wait(timeout=5)
        if created_link:
            command("ip", "link", "delete", host)
        if created_namespace:
            command("ip", "netns", "delete", namespace)


if sys.argv[1] == "init":
    try:
        trusted_init()
    except Exception as error:
        Path("/workspace/failure").write_text(
            f"FAIL: trusted network fixture failed ({type(error).__name__}: {error})\n"
        )
        raise
elif sys.argv[1] == "serve":
    with ExitStack() as resources:
        listeners = []
        for address in ("100.64.0.10", "1.1.1.1"):
            listener = resources.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((address, 443))
            listener.listen(1)
            listener.settimeout(10)
            listeners.append(listener)
        print("ready", flush=True)
        for listener in listeners:
            connection, _ = listener.accept()
            with connection:
                connection.sendall(PAYLOAD)
elif sys.argv[1] == "probe":
    probe(sys.argv[2], int(sys.argv[3]), sys.argv[4] == "allow")
elif sys.argv[1] == "workload":
    workload()
else:
    raise SystemExit("unsupported network fixture operation")
NETWORK
# Deliberately permissive sources ensure private copies are not just inheriting
# safe host modes. These are markers, not credentials or executable host tools.
for agent in pi omp; do
    root="$TMP/fixtures/$agent"
    mkdir -p "$root/agent/extensions/nested" "$root/profiles/work"
    printf '{"origin":"%s-root"}\n' "$agent" > "$root/config-origin.json"
    printf '{"origin":"%s-agent"}\n' "$agent" > "$root/agent/config-origin.json"
    printf '{"origin":"%s-profile"}\n' "$agent" > "$root/profiles/work/config.json"
    printf 'synthetic root config\n' > "$root/root-config.txt"
    printf 'synthetic nested config\n' > "$root/agent/extensions/nested/config.txt"
    mkdir -p "$root/agent/extensions/run"
    printf 'portable extension source\n' > "$root/agent/extensions/run/config.txt"
    for config_root in "$root" "$root/profiles/work"; do
        for runtime in run ssh-control puppeteer natives .supervisor; do
            mkdir -p "$config_root/$runtime"
            printf 'host process state\n' > "$config_root/$runtime/fixture-marker"
        done
    done
    printf 'synthetic removable config\n' > "$root/agent/deletable.txt"
    printf 'synthetic read-only marker\n' > "$root/read-only-marker"
    printf '#!/bin/sh\nexit 0\n' > "$root/agent/extensions/fixture-tool.sh"
    printf '{}\n' > "$root/agent/settings.json"
    printf '{}\n' > "$root/agent/auth.json"
    printf '{}\n' > "$root/agent/config.yml"
    # A valid empty provider map does not point agents at any host service.
    printf '{"providers":{}}\n' > "$root/agent/models.json"
    # Real SQLite coverage lives at root state.db, never at an agent-owned
    # database path. History database markers below must always be excluded.
    for level in "$root" "$root/agent" "$root/agent/extensions/nested"; do
        for excluded in sessions terminal-sessions cache caches logs bin __pycache__ .git; do
            mkdir -p "$level/$excluded"
            printf 'must not be copied\n' > "$level/$excluded/fixture-marker"
        done
        for excluded in history.db history.db-wal history.db-shm history.db.backup trust.json trust.db trust.db-wal fixture.db-wal fixture.db-shm .seeded; do
            printf 'must not be copied\n' > "$level/$excluded"
        done
    done
    ln -s /etc/passwd "$root/symlink-file"
    ln -s /etc "$root/symlink-directory"
    ln -s absent-target "$root/broken-symlink"
    ln -s extensions/nested/config.txt "$root/agent/relative-symlink-file"
    ln -s extensions "$root/agent/relative-symlink-directory"
    find "$root" -type d -exec chmod 0777 {} +
    find "$root" -type f -exec chmod 0666 {} +
    chmod 0777 "$root/agent/extensions/fixture-tool.sh"
done
cat > "$TMP/control/sqlite-fixtures.py" <<'SQLITE'
import shutil
import sqlite3
import sys
import tempfile
from contextlib import closing
from pathlib import Path


if sys.argv[1] == "prepare":
    for agent in ("pi", "omp"):
        with tempfile.TemporaryDirectory(prefix="sqlite-fixture-") as temporary:
            database = Path(temporary) / "state.db"
            connection = sqlite3.connect(database)
            try:
                assert connection.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
                connection.execute("CREATE TABLE snapshot_fixture(value TEXT)")
                connection.commit()
                assert connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0] == 0
                connection.execute(
                    "INSERT INTO snapshot_fixture(value) VALUES (?)",
                    (f"{agent}-wal-committed",),
                )
                connection.commit()
                # Prove the committed row really requires WAL replay, rather
                # than accidentally testing an already-checkpointed database.
                with closing(sqlite3.connect(f"{database.as_uri()}?immutable=1", uri=True)) as main_only:
                    assert main_only.execute("SELECT count(*) FROM snapshot_fixture").fetchone() == (0,)
                assert Path(f"{database}-wal").stat().st_size > 32
                for suffix in ("", "-wal", "-shm"):
                    target = Path("/fixtures") / agent / f"state.db{suffix}"
                    shutil.copyfile(Path(f"{database}{suffix}"), target)
                    target.chmod(0o666)
                # A host runtime WAL database without its SHM must not be
                # opened through the read-only configuration mount at all.
                for root in (Path("/fixtures") / agent,
                             Path("/fixtures") / agent / "profiles" / "work"):
                    shutil.copyfile(database, root / "run" / "browser-cache.db")
            finally:
                connection.close()
    Path("/fixtures/sqlite-prepared").write_text("complete\n")
elif sys.argv[1] == "check":
    for agent in ("pi", "omp"):
        database = Path("/root") / f".{agent}" / "state.db"
        assert database.is_file()
        # Assert before connecting: opening a WAL-mode database can itself
        # create sidecars, which must not disguise files copied from the host.
        assert not Path(f"{database}-wal").exists()
        assert not Path(f"{database}-shm").exists()
        with closing(sqlite3.connect(f"{database.as_uri()}?mode=ro&immutable=1", uri=True)) as snapshot:
            assert snapshot.execute("PRAGMA quick_check").fetchall() == [("ok",)]
            assert snapshot.execute("SELECT value FROM snapshot_fixture").fetchall() == [
                (f"{agent}-wal-committed",)
            ]
elif sys.argv[1] == "stress":
    import runpy
    module = runpy.run_path("/usr/local/bin/pi-agent-seed.py")
    connect = sqlite3.connect
    with tempfile.TemporaryDirectory(prefix="sqlite-changing-") as temporary:
        source = Path(temporary) / "models.db"
        destination = Path(temporary) / "snapshot.db"
        with closing(connect(source)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE revision(value INTEGER)")
            writer.execute("INSERT INTO revision VALUES(0)")
            writer.execute("CREATE TABLE payload(data BLOB)")
            writer.executemany("INSERT INTO payload VALUES(?)", [(b"x" * 4096,)] * 4096)
            writer.commit()
            steps = []

            class ChangingSource(sqlite3.Connection):
                def backup(self, target, *, pages, progress):
                    def advance(status, remaining, total):
                        steps.append(remaining)
                        assert len(steps) <= 40, "snapshot restarted under concurrent writes"
                        if remaining:
                            writer.execute("UPDATE revision SET value=value+1")
                            writer.commit()
                        progress(status, remaining, total)
                    return super().backup(target, pages=pages, progress=advance)

            def changing_connect(database, *args, **kwargs):
                if str(database).endswith("?mode=ro"):
                    kwargs["factory"] = ChangingSource
                return connect(database, *args, **kwargs)

            # Commit a real write between every backup batch. This makes the
            # host-writer race deterministic without relying on thread timing.
            sqlite3.connect = changing_connect
            try:
                module["backup_database"](source, destination)
            finally:
                sqlite3.connect = connect
            with closing(connect(destination)) as snapshot:
                assert snapshot.execute("SELECT value FROM revision").fetchone() == (0,)
                assert snapshot.execute("SELECT count(*) FROM payload").fetchone() == (4096,)
                assert snapshot.execute("PRAGMA quick_check").fetchall() == [("ok",)]
            assert writer.execute("SELECT value FROM revision").fetchone()[0] > 0
else:
    raise SystemExit("unsupported fixture operation")
SQLITE

# Prepare genuine live-WAL snapshots using only the image's Python standard
# library. Writable host mounts contain only disposable synthetic fixtures.
if ! (cd "$TMP" && smolvm machine run --unprivileged --net-backend virtio-net \
    --smolfile "$TMP/Smolfile" --no-init-cache --timeout 120s --mem 2048 --cpus 2 \
    -v "$TMP/control:/verify:ro" -v "$TMP/preparation-workspace:/workspace" \
    -v "$TMP/fixtures:/fixtures" --image "$IMAGE_TAR" \
    -- /usr/local/bin/pi-agent-seed.py /usr/bin/python3 /verify/sqlite-fixtures.py prepare) \
    > "$TMP/sqlite-preparation.log" 2>&1; then
    if [[ -f "$TMP/preparation-workspace/failure" ]]; then
        IFS= read -r detail < "$TMP/preparation-workspace/failure"
        fail "SQLite preparation: $detail"
    fi
    fail 'SQLite WAL fixture preparation boot failed'
fi
[[ -f "$TMP/fixtures/sqlite-prepared" ]] || fail 'SQLite WAL fixture preparation did not finish'
printf 'PASS: genuine committed SQLite WAL fixtures prepared without host dependencies\n'
# Byte-for-byte snapshots also cover file modes, symlinks, names and mtimes.
# Reading a file may update atime, which ordinary tar headers do not include.
COPYFILE_DISABLE=1 tar -cf "$TMP/fixtures-before.tar" -C "$TMP/fixtures" pi omp

cat > "$TMP/control/checks.zsh" <<'GUEST'
set -eu
setopt PIPE_FAIL
fail() { print -r -- "FAIL: $1" > /workspace/failure; exit 1; }
pass() { print -r -- "PASS: $1" >> /workspace/assertions; }
trap 'print -r -- "FAIL: guest assertion or command failed" > /workspace/failure' ZERR
mode="$1"
/usr/bin/python3 /verify/network-fixtures.py workload >> /workspace/assertions \
    || fail 'network filter proof or capability-drop contract failed'
[[ ${+PI_CODING_AGENT_DIR} == 0 ]] || fail 'global PI_CODING_AGENT_DIR is set'
[[ "$HOME" == /root ]] || fail 'unexpected native config home'
[[ -d /root/.pi/agent && -d /root/.omp/agent ]] || fail 'native agent directories missing'
[[ ! -L /root/.pi && ! -L /root/.omp && ! -e /root/.pi-agent ]] || fail 'config roots are not separate native directories'
cmp -s /opt/pi-sandbox/sandbox.json.autonomous /root/.pi/agent/sandbox.json \
    || fail 'Pi autonomous sandbox profile missing or changed'
[[ ! -e /root/.omp/agent/sandbox.json ]] || fail 'Pi sandbox profile leaked into omp config'
pass "$mode: native independent config paths and Pi sandbox profile"

# Check before agent commands have a chance to create their own new files.
for root in /root/.pi /root/.omp; do
    [[ -z "$(find "$root" -type l -print -quit)" ]] || fail 'symlink copied into private config'
    [[ -z "$(find "$root" -type d ! -perm 0700 -print -quit)" ]] || fail 'copied directory permissions are not private 0700'
    [[ -z "$(find "$root" -type f ! -perm 0600 ! -perm 0700 -print -quit)" ]] || fail 'copied file permissions are not private 0600 or 0700'
done
pass "$mode: private config permissions and no copied symlinks"

if [[ "$mode" == fixture ]]; then
    /usr/bin/python3 /verify/sqlite-fixtures.py check \
        || fail 'SQLite backup omitted committed WAL data, copied sidecars, or failed quick_check'
    pass 'fixture: private SQLite snapshots include committed WAL data and pass quick_check'
    for agent in pi omp; do
        root="/root/.$agent"
        src="/root/.$agent-host"
        [[ "$(< "$root/config-origin.json")" == "{\"origin\":\"$agent-root\"}" ]] || fail 'same-named root config was merged or lost'
        [[ "$(< "$root/agent/config-origin.json")" == "{\"origin\":\"$agent-agent\"}" ]] || fail 'same-named agent config was merged or lost'
        [[ "$(< "$root/profiles/work/config.json")" == "{\"origin\":\"$agent-profile\"}" ]] || fail 'named profile was not copied'
        cmp -s "$src/root-config.txt" "$root/root-config.txt" || fail 'root-level configuration not copied'
        cmp -s "$src/agent/extensions/nested/config.txt" "$root/agent/extensions/nested/config.txt" || fail 'nested configuration not copied'
        cmp -s "$src/agent/extensions/run/config.txt" "$root/agent/extensions/run/config.txt" \
            || fail 'portable extension directory named run was incorrectly excluded'
        for config_root in "$root" "$root/profiles/work"; do
            for runtime in run ssh-control puppeteer natives .supervisor; do
                [[ ! -e "$config_root/$runtime" ]] || fail 'host daemon/browser/native runtime tree copied'
            done
        done
        [[ "$(stat -c %a "$root/agent/extensions/fixture-tool.sh")" == 700 ]] || fail 'copied executable is not private 0700'
        [[ "$(stat -c %a "$root/root-config.txt")" == 600 ]] || fail 'copied ordinary file is not private 0600'
        for level in "$root" "$root/agent" "$root/agent/extensions/nested"; do
            for excluded in sessions terminal-sessions cache caches logs bin __pycache__ .git history.db history.db-wal history.db-shm history.db.backup trust.json trust.db trust.db-wal fixture.db-wal fixture.db-shm .seeded; do
                [[ ! -e "$level/$excluded" && ! -L "$level/$excluded" ]] || fail 'host history, binaries, cache, or trust copied'
            done
        done
        for link in "$root/symlink-file" "$root/symlink-directory" "$root/broken-symlink" "$root/agent/relative-symlink-file" "$root/agent/relative-symlink-directory"; do
            [[ ! -e "$link" && ! -L "$link" ]] || fail 'symlink was followed or copied'
        done
        if (print -r -- forbidden > "$src/write-probe") 2>/dev/null; then
            fail 'source mount allowed file creation'
        fi
        if (print -r -- forbidden > "$src/config-origin.json") 2>/dev/null; then
            fail 'source mount allowed existing file modification'
        fi
        if rm "$src/read-only-marker" 2>/dev/null; then
            fail 'source mount allowed file deletion'
        fi
        if chmod 0600 "$src/config-origin.json" 2>/dev/null; then
            fail 'source mount allowed metadata modification'
        fi
        command -v mount >/dev/null || fail 'mount command is required for the remount regression'
        if mount -o remount,rw "$src" 2>/dev/null; then
            fail 'restricted guest remounted a host config source writable'
        fi
        if (print -r -- forbidden >> "$src/read-only-marker") 2>/dev/null; then
            fail 'source mount allowed writes after remount attempt'
        fi
    done
    pass 'fixture: same-named Pi and omp config, root files, and named profiles stay separate'
    pass 'fixture: histories, host binaries, caches, trust, and symlinks omitted'
    pass "$mode: host runtime trees omitted while portable extension run directories survive"
    pass "$mode: source mounts reject writes and metadata changes, including after remount attempts"
    # Nested login shells remain supported; privileged nested bubblewrap does
    # not, because restoring NET_ADMIN/SYS_ADMIN would undermine the filter.

    for agent in pi omp; do
        print -r -- '{"origin":"vm-edit"}' > "/root/.$agent/config-origin.json"
        print -r -- '{"origin":"vm-edit"}' > "/root/.$agent/agent/config-origin.json"
        touch -t 200001010000 "/root/.$agent/config-origin.json" "/root/.$agent/agent/config-origin.json"
        rm "/root/.$agent/agent/deletable.txt"
    done
    print '' >> /root/.pi/agent/sandbox.json
    cp /root/.pi/agent/sandbox.json /workspace/edited-sandbox.json
    zsh -l -c '
        set -eu
        [[ ${+PI_CODING_AGENT_DIR} == 0 ]]
        for agent in pi omp; do
            [[ "$(< /root/.$agent/config-origin.json)" == "{\"origin\":\"vm-edit\"}" ]]
            [[ "$(< /root/.$agent/agent/config-origin.json)" == "{\"origin\":\"vm-edit\"}" ]]
            [[ ! -e /root/.$agent/agent/deletable.txt ]]
        done
        cmp -s /root/.pi/agent/sandbox.json /workspace/edited-sandbox.json
    ' || fail 'nested login zsh reseeded config or replaced VM edits'
    pass 'fixture: nested login zsh preserves edits, deletions, and sandbox profile'
else
    [[ ! -e /root/.pi/config-origin.json && ! -e /root/.omp/config-origin.json ]] || fail 'unmounted boot retained fixture config'
    print -r -- synthetic > /root/.pi/agent/default-write-probe
    print -r -- synthetic > /root/.omp/agent/default-write-probe
    pass 'default: boot without host config mounts provides writable native config'
    /usr/bin/python3 /verify/sqlite-fixtures.py stress \
        || fail 'configuration snapshot cannot finish consistently under ongoing host writes'
    pass 'default: configuration snapshot completes consistently while source writes continue'
fi

for agent in pi omp; do
    command -v "$agent" >/dev/null || fail "$agent command is missing"
    version="$(timeout 30 "$agent" --version 2>/dev/null)" || fail "$agent --version failed"
    [[ "$version" == *[0-9]* ]] || fail "$agent --version did not return a version"
done
pass "$mode: actual pi --version and omp --version succeed"
print -r -- "$mode-complete" > /workspace/completed
GUEST

run_guest() {
    local mode="$1" workspace="$2" result=0 detail
    shift 2
    local args=(machine run --unprivileged --net-backend virtio-net
        --smolfile "$TMP/Smolfile" --no-init-cache --timeout 120s --mem 2048 --cpus 2)
    # No SSH agent, API keys, real home mounts, or writable repository mount.
    # Only local synthetic peer requests are needed; no external servers.
    # smolvm versions differ on command overrides: explicitly invoke the shipped
    # entrypoint so these checks cannot accidentally bypass configuration seeding.
    (cd "$TMP" && smolvm "${args[@]}" \
        -v "$TMP/control:/verify:ro" -v "$workspace:/workspace" \
        "$@" --image "$IMAGE_TAR" \
        -- /usr/local/bin/pi-agent-seed.py zsh -l -c 'source /verify/checks.zsh "$1"' verify "$mode") \
        > "$TMP/$mode-boot.log" 2>&1 || result=$?
    if [[ -f "$workspace/failure" ]]; then
        IFS= read -r detail < "$workspace/failure"
        case "$detail" in
            'FAIL: '*) fail "$mode: ${detail#FAIL: }" ;;
            *) fail "$mode: guest assertion failed" ;;
        esac
    fi
    [[ "$result" == 0 ]] || fail "$mode: smolvm boot or guest checks failed"
    [[ -f "$workspace/completed" ]] || fail "$mode: guest did not complete its assertions"
    [[ "$(< "$workspace/completed")" == "$mode-complete" ]] || fail "$mode: guest completion marker invalid"
    # Only our concise assertion records reach stdout, never VM logs/config.
    while IFS= read -r assertion; do
        case "$assertion" in
            'PASS: '*) printf '%s\n' "$assertion" ;;
            *) fail "$mode: unexpected guest assertion output" ;;
        esac
    done < "$workspace/assertions"
}

run_guest fixture "$TMP/workspace" \
    -v "$TMP/fixtures/pi:/root/.pi-host:ro" \
    -v "$TMP/fixtures/omp:/root/.omp-host:ro"
run_guest default "$TMP/default-workspace"
COPYFILE_DISABLE=1 tar -cf "$TMP/fixtures-after.tar" -C "$TMP/fixtures" pi omp
cmp -s "$TMP/fixtures-before.tar" "$TMP/fixtures-after.tar" \
    || fail 'synthetic host configuration changed'
printf 'PASS: synthetic host fixtures remain byte-for-byte unchanged\n'
