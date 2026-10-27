#!/usr/bin/env bash

set -euo pipefail

CACHE_DIR="$HOME/.cache/pi-sandbox"
IMAGE_TAR="$CACHE_DIR/pi-sandbox.tar"
IMAGE_NAME="jasonbaker/pi-sandbox:latest"
AGENT_ARG=""

# Parse flags and arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: pi-sandbox [options] [target_directory]"
            echo "Runs the pi.dev (or omp / oh-my-pi) coding agent inside a secure smolvm microVM sandbox."
            echo ""
            echo "Options:"
            echo "  --agent NAME        Agent to run in the VM: pi (default) or omp (oh-my-pi)."
            echo "                      Equivalent to AGENT=omp ./pi-sandbox.sh"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  AGENT               Agent to run: pi (default) or omp (--agent overrides)."
            echo "  LLM_BASE_URL        Custom LLM endpoint (e.g. http://localhost:8001/v1 for OMLX)"
            echo "                      When set, cloud API keys are not forwarded."
            echo "  ANTHROPIC_API_KEY   Anthropic API key (ignored if LLM_BASE_URL is set)"
            echo "  OPENAI_API_KEY      OpenAI API key (ignored if LLM_BASE_URL is set)"
            echo ""
            echo "Building and pushing the image (first time or after Dockerfile changes):"
            echo "  ./build.sh"
            exit 0
            ;;
        --agent)
            AGENT_ARG="${2:-}"
            if [[ "$AGENT_ARG" != "pi" && "$AGENT_ARG" != "omp" ]]; then
                echo "Error: --agent must be 'pi' or 'omp'."
                exit 1
            fi
            shift 2
            ;;
        -*)
            echo "Error: unknown option: $1"
            echo "Run 'pi-sandbox --help' for usage."
            exit 1
            ;;
        *)
            TARGET_ARG="$1"
            shift
            ;;
    esac
done

# Resolve target directory with fallback to current working directory
TARGET_PATH="${TARGET_ARG:-$(pwd)}"
TARGET_DIR=$(realpath "$TARGET_PATH" 2>/dev/null || echo "$TARGET_PATH")

# Safety fallback if TARGET_DIR is somehow still empty
if [[ -z "${TARGET_DIR:-}" ]]; then
    TARGET_DIR="$(pwd)"
fi

echo "Mounting host directory: $TARGET_DIR"

# Ensure ~/.pi exists on host. It is mounted read-only into the VM and seeded
# into an ephemeral VM-local agent dir at boot (see pi-agent-seed.sh in the
# image), so VM runs get host login state/extensions without sharing files.
HOST_PI_DIR="$HOME/.pi"
HOST_OMP_DIR="$HOME/.omp"
mkdir -p "$HOST_PI_DIR" "$HOST_OMP_DIR"
mkdir -p "$CACHE_DIR"

# Ensure smolvm is installed
if ! command -v smolvm &> /dev/null; then
    echo "Error: smolvm CLI not found."
    echo "Install it via: curl -sSL https://smolmachines.com/install.sh | bash"
    exit 1
fi

IMAGE_ID_FILE="$CACHE_DIR/.image_id"
docker pull "$IMAGE_NAME"

# Cache validity keys on the exported tar's content hash: a plain image-id
# check can't work because `docker inspect .Id` is the manifest-list digest
# and stays identical across pulls of a new push, so stale tars would be
# served forever. The hash check catches a fresh push; the size floor catches
# an index-only tar — what `docker save` of a multi-arch tag writes in a
# containerd store (OrbStack, Docker Desktop): index metadata, no layer
# blobs (~20KB vs hundreds of MB). That is the tar smolvm rejects at boot
# with "file not found in tar"; rejecting it here turns that mystery boot
# error into an automatic re-export.
tar_is_complete() {
    [[ -f "$IMAGE_TAR" ]] || return 1
    local size
    size=$(stat -f %z "$IMAGE_TAR" 2>/dev/null || stat -c %s "$IMAGE_TAR" 2>/dev/null || echo 0)
    [[ "$size" -gt 1048576 ]]
}

NEW_IMAGE_ID=$(sha256sum "$IMAGE_TAR" 2>/dev/null | cut -d' ' -f1 || true)

if [[ -f "$IMAGE_ID_FILE" ]] && [[ -f "$IMAGE_TAR" ]] && [[ "$NEW_IMAGE_ID" == "$(cat "$IMAGE_ID_FILE")" ]] && tar_is_complete; then
    echo "Using existing local image cache: $IMAGE_TAR"
else
    # Docker Hub reports the manifest-list id, and in a containerd store
    # (OrbStack, Docker Desktop) `docker save` of the default multi-arch
    # view writes a tar of index references — no layer blobs — which smolvm
    # rejects at boot ("file not found in tar"). So: save, check, and on
    # failure pull the LOCAL platform explicitly before saving. A tag's
    # id is the list digest regardless of which platform was pulled, so the
    # single-platform tag must be deleted and re-pulled: that is what makes
    # the save emit real blobs.
    echo "Exporting $IMAGE_NAME..."
    docker save "$IMAGE_NAME" -o "$IMAGE_TAR"
    if ! tar_is_complete; then
        ARCH=$(uname -m); [[ "$ARCH" == x86_64 ]] && ARCH=amd64; [[ "$ARCH" == aarch64 ]] && ARCH=arm64
        echo "Multi-arch save lacks layer blobs; pulling linux/$ARCH explicitly..."
        docker image rm -f "$IMAGE_NAME" >/dev/null 2>&1 || true
        docker pull --platform "linux/$ARCH" "$IMAGE_NAME" >/dev/null 2>&1 \
            || { echo "Error: could not pull linux/$ARCH of $IMAGE_NAME"; exit 1; }
        docker save "$IMAGE_NAME" -o "$IMAGE_TAR"
        tar_is_complete \
            || { echo "Error: exported tar still lacks layer blobs; check the docker store (containerd image store + multi-arch tag)."; exit 1; }
    fi
    sha256sum "$IMAGE_TAR" | cut -d" " -f1 > "$IMAGE_ID_FILE"
fi

# Notify about SSH agent (crucial for secure git inside the sandbox)
if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    echo "Warning: SSH_AUTH_SOCK is empty. Git commands inside the sandbox won't use host keys."
else
    echo "SSH agent detected. Enforcing secure SSH key forwarding..."
fi

# Resolve LLM endpoint (if using a local model server)
VM_LLM_URL="${LLM_BASE_URL:-}"
if [[ -n "$VM_LLM_URL" ]]; then
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' \
        || ifconfig 2>/dev/null | grep -Eo 'inet (10|172|192)\.[0-9.]+' | head -1 | awk '{print $2}')

    if [[ -n "${HOST_IP:-}" ]]; then
        VM_LLM_URL="${VM_LLM_URL//localhost/$HOST_IP}"
        VM_LLM_URL="${VM_LLM_URL//127.0.0.1/$HOST_IP}"
    fi

    echo "Using local LLM endpoint: $VM_LLM_URL"
fi

# Choose the agent inside the VM: pi (default) or omp (oh-my-pi). Both run
# through the same login shell (the image ENTRYPOINT). .zshenv seeds the
# agent dirs from the host mounts before either runs.
# --agent overrides AGENT; the value was validated during arg parsing.
AGENT="${AGENT_ARG:-${AGENT:-pi}}"

# Run the ephemeral microVM sandbox from the local tar file
smolvm machine run -it \
    --net \
    --ssh-agent \
    --mem 2048 \
    --cpus 4 \
    -v "$TARGET_DIR:/workspace" \
    -v "$HOST_PI_DIR:/root/.pi-host:ro" \
    -v "$HOST_OMP_DIR:/root/.omp-host:ro" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    -e OPENAI_BASE_URL="${VM_LLM_URL:-}" \
    -e LLM_BASE_URL="${VM_LLM_URL:-}" \
    --image "$IMAGE_TAR" \
    -- zsh -l -c "exec $AGENT"
