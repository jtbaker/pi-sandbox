# Pi Sandbox

A secure, ephemeral microVM sandbox for running the [Pi](https://pi.dev) coding agent against any project directory on your host machine.

## Overview

Pi Sandbox launches the Pi coding agent inside an isolated smolvm microVM. Your workspace is mounted read-write inside the VM, while your host system remains untouched. The agent has network access (for LLM APIs) and optional SSH agent forwarding (for private git repos), all without exposing your full system.

## Prerequisites

- **smolvm** — Install via:
  ```bash
  curl -sSL https://smolmachines.com/install.sh | bash
  ```

- **Docker** (or OrbStack, Podman) — to build the container image

## Quick Start

```bash
# 1. Build and push the multi-platform image (uses buildx)
./build.sh

# 2. Run the sandbox (pulls from Docker Hub automatically)
./pi-sandbox.sh
```

## Usage

```bash
# Run against the current directory
./pi-sandbox.sh

# Run against a specific project directory
./pi-sandbox.sh /path/to/project

# Show help
./pi-sandbox.sh --help
```

Rebuild and re-export the tar whenever you change `Dockerfile.pi`.

## Installing Globally

To run `pi-sandbox` from anywhere without `./`, symlink the script into a directory on your `PATH`:

```bash
ln -s /path/to/pi-sandbox.sh /usr/local/bin/pi-sandbox
```

Now you can invoke it from any directory:

```bash
pi-sandbox /path/to/project
```

> **Tip:** Omit the `.sh` extension in the symlink name so it reads like a regular command. The script's shebang line handles execution regardless of the name.

## LLM Backends

Pi Sandbox supports two modes. The script picks the mode based on your environment:

- **Cloud mode** (default): Passes `ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` into the VM.
- **Local model mode**: When `LLM_BASE_URL` is set, cloud keys are skipped and the agent points at your local server.

### Cloud Mode (Anthropic / OpenAI)

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
./pi-sandbox.sh
```

### Local Model Mode (e.g. OMLX)

Inside the microVM, `localhost` refers to the VM itself, not your host machine. The Rust smolvm CLI (v1.6.x) has no `port expose` command to bridge the two (that feature only exists in the Python SDK). The script works around this by detecting your host's LAN IP and rewriting `localhost` in the URL.

#### Step-by-step for OMLX

1. **Start OMLX bound to all interfaces** (not just `127.0.0.1`):
   ```
   OMLX listening on http://0.0.0.0:8001/v1
   ```

2. **Set the endpoint and run**:
   ```bash
   export LLM_BASE_URL="http://localhost:8001/v1"
   ./pi-sandbox.sh
   ```

3. **That's it** — the script detects your host IP, rewrites the URL to `http://<host-ip>:8001/v1`, and passes it into the VM. The script prints the resolved URL on startup so you can verify it's correct.

#### Troubleshooting

- **"Could not detect host LAN IP"** — the script couldn't find a routable IP. Make sure you're on a network with an active interface (Wi-Fi or Ethernet). If the detected IP looks wrong, set `LLM_BASE_URL` with the full IP:
  ```bash
  export LLM_BASE_URL="http://192.168.1.42:8001/v1"
  ```

- **Connection refused / timeout** — OMLX is likely bound to `127.0.0.1` instead of `0.0.0.0`. Restart it bound to all interfaces.

- **Firewall blocking** — on macOS, check `System Settings → Network → Firewall` and allow incoming connections for your model server.

## How It Works

1. The script resolves the target directory (defaults to `pwd`) and mounts it at `/workspace` inside the VM.
2. Your `~/.pi` directory is mounted to persist login state, themes, and templates across runs.
3. **Cloud mode:** API keys are passed as environment variables. The agent calls cloud LLM APIs over outbound HTTPS.
4. **Local model mode:** The script detects your host's LAN IP, rewrites `localhost` in `LLM_BASE_URL`, and passes the result as both `OPENAI_BASE_URL` and `LLM_BASE_URL` into the VM.
5. If an SSH agent is detected, credentials are securely forwarded for git operations inside the sandbox.
6. The microVM boots with the `pi-sandbox` image and runs the `pi` entrypoint.

## Container Image

The sandbox image is defined in `Dockerfile.pi` and includes:

- **Node.js 22** (Bullseye slim)
- System utilities: `git`, `curl`, `ripgrep`, `build-essential`
- The `@oh-my-pi/pi-coding-agent` package installed globally

The image is published to Docker Hub as `jasonbaker/pi-sandbox`. The script pulls it automatically on each run.

### Building & Pushing

```bash
./build.sh
```

This builds a cross-platform image (`linux/amd64`, `linux/arm64`) and pushes it to the registry.

```bash
# Build with a specific tag
./build.sh v1.0

# Build for a single platform
PLATFORMS=linux/amd64 ./build.sh
```

## Environment Variables

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | API key for Anthropic models (cloud mode) |
| `OPENAI_API_KEY` | API key for OpenAI models (cloud mode) |
| `LLM_BASE_URL` | Custom LLM endpoint (e.g. `http://localhost:8001/v1`). When set, overrides cloud mode. |

## Security

- The microVM is ephemeral — no state persists after the agent exits.
- Only the specified workspace directory and `~/.pi` are mounted.
- SSH keys never leave the host; they are proxied securely via the agent socket.
- Network access is required for LLM API communication.

## File Structure

```
├── Dockerfile.pi      # Container image definition
├── build.sh           # Build script — multi-platform image via buildx, pushes to Docker Hub
├── pi-sandbox.sh      # Entry script — launch the sandbox
├── julia-and-rust.md  # Sample reference document
└── README.md          # This file
```
