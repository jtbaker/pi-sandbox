#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="jasonbaker/pi-sandbox"
TAG="${1:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

echo "🐳 Building ${IMAGE_NAME}:${TAG} for ${PLATFORMS}..."

# Create a builder if one doesn't already exist
if ! docker buildx inspect pi-builder &>/dev/null; then
  echo "🔧 Creating buildx builder 'pi-builder'..."
  docker buildx create --name pi-builder --use --driver docker-container
  docker buildx inspect --bootstrap
else
  docker buildx use pi-builder
fi

# Build multi-platform image (zstd-compressed for optimal size/performance)
docker buildx build \
  --builder pi-builder \
  --platform "${PLATFORMS}" \
  -f Dockerfile.pi \
  -t "${IMAGE_NAME}:${TAG}" \
  --output "type=registry,compression=zstd,compression-level=22,force-compression=true,oci-mediatypes=true" \
  --push \
  .

echo "✅ Built and pushed ${IMAGE_NAME}:${TAG} for ${PLATFORMS}"
echo ""
echo "Run the sandbox: ./pi-sandbox.sh"
