# Claude Code Development Environment

A sandboxed, Docker-based development environment with Claude Code and multi-language support.

## Overview

This project provides a fully configured Docker container pre-loaded with **Claude Code**, **Node.js 24**, **PHP 8.5**, **Python 3.14**, **Go**, **Rust**, **TypeScript**, **Terraform**, **AWS CLI**, **Docker CLI**, and a comprehensive set of common development tools. It gives you a reproducible, isolated environment where Claude Code can assist with your projects without touching your host system directly.

The sandbox model is straightforward: your source code is mounted into an isolated Docker container, and Claude Code runs inside that sandbox with controlled access. Sensitive host resources (SSH keys, git config) are mounted read-only, while your project directory is read-write so Claude Code can edit files. The container runs as a non-root user with security restrictions applied, providing a clear boundary between the AI assistant and your host operating system.

This environment works cross-platform on **Linux**, **macOS**, and **Windows** (via Docker Desktop with WSL2).

## Prerequisites

- **Docker Engine 24+** or **Docker Desktop**
- **Docker Compose v2**
- An **Anthropic API key** OR a **Claude Pro/Max subscription**
- (Optional) SSH agent running on the host for git operations
- (Windows) **WSL2** with Docker Desktop WSL integration enabled

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/your-org/Claude-Code-Environment.git
cd Claude-Code-Environment

# 2. Configure environment
cp .env.example .env
# Edit .env and add your ANTHROPIC_API_KEY

# 3. Launch the environment
chmod +x start.sh
./start.sh

# Or start Claude Code directly
./start.sh --claude
```

For Windows:

```cmd
start.bat
start.bat /claude
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | (none) | Your Anthropic API key (`sk-ant-...`) |
| `CLAUDE_OAUTH_PORT` | `7777` | Host port for OAuth callback during browser login |
| `NODE_VERSION` | `24` | Node.js major version to install |
| `PHP_VERSION` | `8.5` | PHP version to install |
| `PYTHON_VERSION` | `3.14` | Python version to install |
| `GO_VERSION` | `1.26` | Go version to install |
| `TERRAFORM_VERSION` | `1.11.2` | Terraform version to install |
| `MEMORY_LIMIT` | `16g` | Container memory limit |
| `CPU_LIMIT` | `8` | Container CPU core limit |
| `POSTGRES_USER` | `dev` | PostgreSQL username (database profile) |
| `POSTGRES_PASSWORD` | `devpass` | PostgreSQL password (database profile) |
| `POSTGRES_DB` | `devdb` | PostgreSQL database name (database profile) |
| `MYSQL_ROOT_PASSWORD` | `devpass` | MySQL root password (database profile) |
| `MYSQL_DATABASE` | `devdb` | MySQL database name (database profile) |
| `CLAUDE_CODE_USE_BEDROCK` | (unset) | Set to `1` to use AWS Bedrock |
| `CLAUDE_CODE_USE_VERTEX` | (unset) | Set to `1` to use Google Vertex |

### Build-Time Version Overrides

The language and tool versions are defined as Docker build arguments (`ARG`). These only take effect when the image is built, not at runtime. If you change a version in `.env`, you must rebuild the image for it to apply:

```bash
./start.sh --build  # Rebuilds with versions from .env

# Or manually override a specific version:
docker compose build --build-arg NODE_VERSION=22
```

### Corporate Proxy Certificates

If you are behind a corporate proxy that performs TLS inspection, you can add custom CA certificates:

1. Place your `.pem` certificate files in the `certs/` directory
2. The entrypoint script automatically:
   - Installs them to the system CA store (`/usr/local/share/ca-certificates/`)
   - Sets `NODE_EXTRA_CA_CERTS` for Node.js/npm
   - Sets `REQUESTS_CA_BUNDLE` for Python
   - Sets `SSL_CERT_FILE` for general use
3. All tools (git, curl, pip, composer, etc.) will respect the certs

## Volume Mounts Reference

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| Your project directory (CWD) | `/workspace` | read-write | Source code you're working on |
| `~/.claude` | `/home/developer/.claude` | read-write | Claude Code config, credentials, custom commands |
| `~/.ssh` | `/home/developer/.ssh-host` | read-only | SSH keys for git push/pull to remotes |
| `~/.gitconfig` | `/home/developer/.gitconfig-host` | read-only | Git user name, email, and configuration |
| `/var/run/docker.sock` | `/var/run/docker.sock` | read-write | Docker socket for running containers |
| `./certs/` | `/certs` | read-only | Corporate proxy CA certificates (.pem files) |
| Docker volume: `claude-dev-home` | `/home/developer` | read-write | Persistent home dir (bash history, tool configs) |

**Important notes about volumes:**

- The `claude-dev-home` named volume persists your home directory between restarts. This means bash history, tool configurations, etc. survive container restarts.
- The `.claude` bind mount takes precedence over the named volume for that specific subdirectory.
- SSH keys are copied (not symlinked) by the entrypoint to fix permission issues. The originals remain read-only.
- Git config is symlinked from the read-only mount if not already configured.

## Authentication

### API Key (Recommended)

1. Get a key from [https://console.anthropic.com](https://console.anthropic.com)
2. Add to `.env`: `ANTHROPIC_API_KEY=sk-ant-...`
3. The key is passed as an environment variable to the container

### OAuth Browser Login

1. Set `CLAUDE_OAUTH_PORT=7777` in `.env` (or leave the default)
2. Start the environment: `./start.sh --claude`
3. Claude Code will provide a URL to open in your browser
4. Complete the OAuth flow in your browser
5. Port 7777 is mapped from container to host for the callback

### AWS Bedrock / Google Vertex

Set the appropriate environment variables in `.env`:

- `CLAUDE_CODE_USE_BEDROCK=1` for AWS Bedrock
- `CLAUDE_CODE_USE_VERTEX=1` for Google Vertex

## Git Integration

### SSH Agent Forwarding (Recommended)

The most secure option -- your SSH keys never enter the container.

**Linux/macOS:**

```bash
# Ensure ssh-agent is running
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519  # or your key

# Start the environment — SSH agent is forwarded automatically
./start.sh
```

**macOS specific:** Add to `~/.ssh/config`:

```
Host *
  AddKeysToAgent yes
  UseKeychain yes
```

### SSH Key Mounting (Fallback)

If SSH agent forwarding is not available, the entrypoint copies SSH keys from the read-only mount:

- `~/.ssh` is mounted read-only at `/home/developer/.ssh-host`
- The entrypoint copies keys to `/home/developer/.ssh` with correct permissions (700/600)
- Original host keys are never modified

### Git Config

- `~/.gitconfig` is mounted read-only at `/home/developer/.gitconfig-host`
- The entrypoint symlinks it to `~/.gitconfig` if no existing config is present
- Your `git user.name`, `user.email`, and other settings are available inside the container

### GPG Signing

For commit signing, you will need to:

1. Mount your GPG keys: add to `docker-compose.yml`: `- ${HOME}/.gnupg:/home/developer/.gnupg-host:ro`
2. The entrypoint does not handle GPG automatically -- configure it manually inside the container or add a custom entrypoint extension

## Docker Access (Socket Mount)

The host's Docker socket is mounted into the container, allowing you to:

- Build Docker images
- Run containers (they run on the host, as siblings)
- Use docker compose

**Security note:** Docker socket access is equivalent to root access on the host. This is a conscious trade-off for development convenience. The container itself runs as a non-root user.

## Optional Services

Enable database services with the `database` profile:

```bash
./start.sh --profile database
```

This starts:

| Service | Port | Credentials |
|---------|------|-------------|
| PostgreSQL 17 | 5432 | dev / devpass / devdb |
| MySQL 8.4 | 3306 | root / devpass / devdb |
| Redis 7 | 6379 | (no auth) |
| Adminer (Web UI) | 8080 | (use db credentials) |

Configure credentials in `.env`. Access databases from the dev container using service names as hostnames (e.g., `postgres`, `mysql`, `redis`).

## Security & Sandboxing

### Container Isolation Model

- Claude Code runs inside a Docker container -- this IS the sandbox
- Your project files are mounted read-write (Claude needs to edit code)
- Sensitive files (SSH keys, git config) are mounted read-only
- The container runs as a non-root user (`developer`) with sudo available
- `no-new-privileges` security option prevents privilege escalation
- Resource limits (memory/CPU) prevent runaway processes

### What Claude Code CAN access:

- Your mounted project directory (`/workspace`)
- Internet access (for package installs, API calls)
- Docker socket (for container management)
- Claude Code config directory

### What Claude Code CANNOT access:

- Files outside the mounted directories
- Other host processes or users
- Kernel-level operations (no privileged mode)
- Host network interfaces directly

### Secrets Management

- **API Key**: Passed via environment variable, never written to disk in the image
- **SSH Keys**: Mounted read-only; copied to container with restrictive permissions
- **Git Config**: Read-only mount
- **Database Passwords**: Set via environment variables in `.env` (gitignored)
- **The `.env` file is gitignored** -- never committed to version control

## Installed Tools

| Tool | Default Version | Purpose |
|------|----------------|---------|
| Claude Code | Latest (native) | AI coding assistant |
| Node.js | 24 LTS | JavaScript/TypeScript runtime |
| npm | (bundled) | Node package manager |
| Yarn | (via corepack) | Alternative Node package manager |
| pnpm | (via corepack) | Fast Node package manager |
| TypeScript | Latest | TypeScript compiler |
| ts-node / tsx | Latest | TypeScript execution |
| PHP | 8.5 | PHP runtime with common extensions |
| Composer | Latest | PHP package manager |
| Python | 3.14 | Python runtime |
| pip | Latest | Python package manager |
| pipx | Latest | Install Python CLI tools in isolation |
| poetry | Latest | Python dependency management |
| uv | Latest | Fast Python package installer |
| Go | 1.26 | Go runtime and tools |
| Rust / Cargo | Stable | Rust toolchain |
| Terraform | 1.11.2 | Infrastructure as code |
| AWS CLI | v2 | AWS cloud management |
| Docker CLI | Latest | Container management (via socket) |
| git | Latest | Version control |
| jq / yq | Latest | JSON/YAML processing |
| ripgrep (rg) | Latest | Fast code search |
| fd | Latest | Fast file finder |
| fzf | Latest | Fuzzy finder |
| tmux | Latest | Terminal multiplexer |
| vim / nano | Latest | Text editors |
| curl / wget | Latest | HTTP clients |
| htop | Latest | Process viewer |

## Cross-Platform Usage

### Linux

```bash
chmod +x start.sh
./start.sh
```

Everything works natively. SSH agent forwarding works out of the box.

### macOS

```bash
chmod +x start.sh
./start.sh
```

Works with Docker Desktop for Mac. SSH agent forwarding requires the agent to be running. Note: Docker socket path is handled automatically by Docker Desktop.

### Windows

```cmd
start.bat
```

**Requirements:**

- Docker Desktop with WSL2 backend
- Run from CMD or PowerShell

**Limitations:**

- SSH agent forwarding is not supported from native Windows. Use WSL2 instead.
- If using WSL2, prefer the `start.sh` script from within WSL.

## Troubleshooting

### "Permission denied" on Docker socket

```bash
# The entrypoint should handle this, but if not:
sudo chmod 666 /var/run/docker.sock  # Inside the container
```

### SSH keys not working

```bash
# Check if ssh-agent is running on the host
ssh-add -l
# If empty, add your key
ssh-add ~/.ssh/id_ed25519
```

### Claude Code can't find API key

- Ensure `ANTHROPIC_API_KEY` is set in `.env`
- Check it is not commented out
- Restart the container after changing `.env`

### "Cannot connect to the Docker daemon"

- Ensure Docker Desktop is running
- On Linux: `sudo systemctl start docker`

### Container runs out of memory

Increase `MEMORY_LIMIT` in `.env`:

```env
MEMORY_LIMIT=32g
```

### PHP/Python version not available

The deadsnakes PPA (Python) and Ondrej PPA (PHP) may not have the exact version you want. Check available versions:

```bash
# Inside the container
apt-cache policy python3.14
apt-cache policy php8.5-cli
```

### Proxy certificates not being picked up

- Ensure `.pem` files are in the `certs/` directory (not subdirectories)
- Restart the container after adding new certs
- Check logs: `docker compose logs claude-dev`

## Customization

### Adding more tools

Create a `Dockerfile.custom` that extends the base image:

```dockerfile
FROM claude-dev-environment:latest
USER root
RUN apt-get update && apt-get install -y your-tool && rm -rf /var/lib/apt/lists/*
USER developer
```

### Custom entrypoint logic

Mount a script to `/usr/local/bin/custom-entrypoint.sh` and it will be sourced by the main entrypoint if present.

### Persistent tool installations

Tools installed inside the container persist across restarts thanks to the `claude-dev-home` named volume. To reset:

```bash
docker volume rm claude-dev-home
```

## License

MIT
