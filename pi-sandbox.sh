#!/usr/bin/env bash

set -euo pipefail

CACHE_DIR="$HOME/.cache/pi-sandbox"
IMAGE_TAR="$CACHE_DIR/pi-sandbox.tar"
IMAGE_NAME="jasonbaker/pi-sandbox:latest"
TARGET_ARG=""

# Parse flags and arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: pi-sandbox [options] [target_directory]"
            echo "Runs the pi.dev coding agent inside a secure smolvm microVM sandbox."
            echo ""
            echo "Options:"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  LLM_BASE_URL        Custom LLM endpoint (e.g. http://localhost:8001/v1 for OMLX)"
            echo "                      When set, cloud API keys are not forwarded."
            echo "  ANTHROPIC_API_KEY   Anthropic API key (ignored if LLM_BASE_URL is set)"
            echo "  OPENAI_API_KEY      OpenAI API key (ignored if LLM_BASE_URL is set)"
            echo ""
            echo "Building and pushing the image (first time or after Dockerfile changes):"
            echo "  ./build.sh"
            exit 0
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

# Ensure ~/.pi exists on host to persist login state, themes, and templates
HOST_PI_DIR="$HOME/.pi"
mkdir -p "$HOST_PI_DIR"
mkdir -p "$CACHE_DIR"

# Ensure smolvm is installed
if ! command -v smolvm &> /dev/null; then
    echo "Error: smolvm CLI not found."
    echo "Install it via: curl -sSL https://smolmachines.com/install.sh | bash"
    exit 1
fi

IMAGE_ID_FILE="$CACHE_DIR/.image_id"
docker pull "$IMAGE_NAME"
NEW_IMAGE_ID=$(docker inspect --format='{{.Id}}' "$IMAGE_NAME")

if [[ -f "$IMAGE_ID_FILE" ]] && [[ -f "$IMAGE_TAR" ]]; then
    OLD_IMAGE_ID=$(cat "$IMAGE_ID_FILE")
    if [[ "$NEW_IMAGE_ID" == "$OLD_IMAGE_ID" ]]; then
        echo "Using existing local image cache: $IMAGE_TAR"
    else
        echo "Image updated. Re-exporting $IMAGE_NAME..."
        docker save "$IMAGE_NAME" -o "$IMAGE_TAR"
        echo "$NEW_IMAGE_ID" > "$IMAGE_ID_FILE"
    fi
else
    echo "Pulling and exporting $IMAGE_NAME..."
    docker save "$IMAGE_NAME" -o "$IMAGE_TAR"
    echo "$NEW_IMAGE_ID" > "$IMAGE_ID_FILE"
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

# Run the ephemeral microVM sandbox from the local tar file
smolvm machine run -it \
    --net \
    --ssh-agent \
    -v "$TARGET_DIR:/workspace" \
    -v "$HOST_PI_DIR:/root/.pi" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    -e OPENAI_BASE_URL="${VM_LLM_URL:-}" \
    -e LLM_BASE_URL="${VM_LLM_URL:-}" \
    --image "$IMAGE_TAR" \
    -- zsh