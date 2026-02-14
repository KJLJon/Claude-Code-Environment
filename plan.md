# Claude Code Development Environment - Implementation Plan

## Summary

Create a fully-featured, sandboxed Docker-based development environment for Claude Code with multi-language support, configurable tooling, secure credential handling, and cross-platform launch scripts.

---

## Decisions Made (from Q&A)

| Decision | Choice |
|----------|--------|
| Base image | Ubuntu 24.04 LTS |
| Docker access | Socket mount (host Docker socket) |
| Claude API auth | Both: API key via env var + OAuth browser login |
| Git credentials | Both: SSH agent forwarding + mounted .ssh/.gitconfig fallback |

## Assumptions (remaining questions — please flag any you disagree with)

| Decision | Assumed Choice | Rationale |
|----------|---------------|-----------|
| Container user | **Non-root `developer` user with passwordless sudo** | Best security/usability balance; Docker socket access via `docker` group |
| Claude Code install | **Native installer** (`claude install`) | Anthropic's recommended method; includes auto-updates; user preference |
| Sandboxing | **Container-as-sandbox** (the Docker container IS the sandbox) | Simple, effective; Claude Code's nested sandbox is "weaker" inside Docker per Anthropic docs |
| Compose extras | **Redis, PostgreSQL, MySQL/MariaDB, Adminer** as optional profiles | All disabled by default, enabled via `--profile` flag |

---

## File Structure

```
Claude-Code-Environment/
├── Dockerfile                    # Multi-stage Docker image
├── docker-compose.yml            # Main compose file with profiles
├── .env.example                  # Example environment variables
├── entrypoint.sh                 # Entrypoint script (proxy certs, git config, etc.)
├── start.sh                      # Bash launch script (Linux/macOS)
├── start.bat                     # Batch launch script (Windows)
├── .dockerignore                 # Ignore unnecessary files in build context
├── .gitignore                    # Git ignore for local config
├── README.md                     # Full documentation
└── certs/                        # Directory for optional proxy certs (gitignored)
    └── .gitkeep
```

---

## Implementation Details

### 1. Dockerfile

**Base:** `ubuntu:24.04`

**Build ARGs (all version-configurable):**
```
ARG NODE_VERSION=24
ARG PHP_VERSION=8.5
ARG PYTHON_VERSION=3.14
ARG GO_VERSION=1.26
ARG RUST_VERSION=stable
ARG TERRAFORM_VERSION=1.11.2
ARG CLAUDE_CODE_VERSION=latest
ARG USER_NAME=developer
ARG USER_UID=1000
ARG USER_GID=1000
```

**Tools installed:**

| Category | Tools |
|----------|-------|
| **Core** | git, curl, wget, jq, yq, vim, nano, htop, tmux, ripgrep, fd-find, fzf, zip/unzip, ca-certificates, gnupg, sudo, openssh-client, bash-completion |
| **Node.js 24** | Via NodeSource (includes npm, corepack → yarn, pnpm) |
| **PHP 8.5** | Via Ondrej PPA (php8.5-cli, php8.5-common, common extensions: mbstring, xml, curl, zip, mysql, pgsql, redis, gd, intl) + Composer |
| **Python 3.14** | Via deadsnakes PPA (python3.14, python3.14-venv, python3.14-dev) + pip, pipx, poetry, uv |
| **Go** | Official tarball from go.dev |
| **Rust** | Via rustup (includes cargo) |
| **TypeScript** | Global npm install: typescript, ts-node, tsx |
| **Terraform** | Official HashiCorp binary |
| **AWS CLI** | Official v2 installer |
| **Docker CLI** | Docker CE CLI + docker-compose plugin (for controlling host Docker via socket) |
| **Claude Code** | Native installer (npm used as bootstrap, then `claude install` for native binary) |

**User setup:**
- Create `developer` user (UID/GID configurable) with home dir
- Add to `sudo` group with NOPASSWD
- Add to `docker` group for socket access
- Set bash as default shell
- Create workspace dir at `/workspace`

**Security hardening:**
- Non-root default user
- No unnecessary SUID/SGID binaries (audit and remove)
- Minimal installed packages (no desktop/GUI deps)
- Read-only root filesystem compatible (data in volumes)
- Docker socket access constrained to `docker` group
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` env var set

### 2. entrypoint.sh

Runs on container start before executing the user's command:

1. **Corporate proxy certs:** Check `/certs/*.pem` — if present, copy to `/usr/local/share/ca-certificates/`, run `update-ca-certificates`, set `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE` env vars
2. **Git config:** If `~/.gitconfig-host` mounted, symlink to `~/.gitconfig` (if not already present)
3. **SSH setup:** If `SSH_AUTH_SOCK` is set, ensure it's accessible. If `~/.ssh-host` is mounted, copy to `~/.ssh` with correct permissions (since host mount may be root-owned)
4. **Docker socket permissions:** If `/var/run/docker.sock` exists, ensure the `developer` user can access it (adjust group)
5. **Fix workspace ownership:** Ensure `/workspace` ownership matches the container user
6. **Execute CMD:** `exec "$@"` to hand off to the user's command (default: `bash`)

### 3. docker-compose.yml

**Main service: `claude-dev`**
- Build from local Dockerfile with all ARGs passthrough
- Volumes:
  - `${PROJECT_DIR:-.}:/workspace` (your code)
  - `${HOME}/.claude:/home/developer/.claude` (Claude Code config/state)
  - `${HOME}/.ssh:/home/developer/.ssh-host:ro` (SSH keys, read-only)
  - `${HOME}/.gitconfig:/home/developer/.gitconfig-host:ro` (git config, read-only)
  - `/var/run/docker.sock:/var/run/docker.sock` (Docker socket)
  - `claude-dev-home:/home/developer` (persistent home for installed tools between sessions)
  - `./certs:/certs:ro` (optional proxy certs)
- Environment:
  - `ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}`
  - `ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-}`
  - `ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-}`
  - `HTTPS_PROXY=${HTTPS_PROXY:-}`
  - `HTTP_PROXY=${HTTP_PROXY:-}`
  - `NO_PROXY=${NO_PROXY:-}`
- Ports:
  - `${CLAUDE_OAUTH_PORT:-7777}:7777` (for OAuth browser login, optional)
- Working dir: `/workspace`
- Default command: `bash`
- stdin_open: true, tty: true
- Security options:
  - `security_opt: ["no-new-privileges:true"]`
  - Drop unnecessary capabilities
  - Resource limits (memory, cpus)

**Optional profile services:**

- `redis` (profile: `database`) — Redis latest, port 6379
- `postgres` (profile: `database`) — PostgreSQL 17, port 5432, with env vars
- `mysql` (profile: `database`) — MySQL 8.4, port 3306, with env vars
- `adminer` (profile: `database`) — Adminer, port 8080

All database services use named volumes for persistence.

### 4. start.sh (Linux/macOS)

```bash
#!/usr/bin/env bash
# Launch Claude Code dev environment from current directory
```

Functionality:
- Detect current working directory → set as `PROJECT_DIR`
- Detect if `.env` file exists in project root, source it
- Check for Docker and docker-compose availability
- Check if Docker socket is accessible
- Handle SSH agent forwarding (`SSH_AUTH_SOCK`)
- Support CLI flags:
  - `--build` / `-b`: Force rebuild the image
  - `--profile <name>`: Enable a compose profile (e.g., `--profile database`)
  - `--detach` / `-d`: Run in background
  - `--claude` / `-c`: Start Claude Code directly instead of bash
  - `--help` / `-h`: Show usage
- Export `PROJECT_DIR`, `HOME`, env vars
- Run `docker compose` with appropriate flags
- Clean up on exit

### 5. start.bat (Windows)

Equivalent functionality to `start.sh` for Windows CMD:
- Detect current directory → set `PROJECT_DIR`
- Check for Docker Desktop
- Support flags: `/build`, `/profile`, `/detach`, `/claude`, `/help`
- Translate paths for Docker (Windows → Linux path format)
- Handle `.env` file
- Run `docker compose` with appropriate flags

### 6. .env.example

```env
# Required: Anthropic API Key
ANTHROPIC_API_KEY=

# Optional: Custom API endpoint
# ANTHROPIC_BASE_URL=

# Optional: Model override
# ANTHROPIC_MODEL=

# Optional: Corporate proxy settings
# HTTPS_PROXY=
# HTTP_PROXY=
# NO_PROXY=localhost,127.0.0.1

# Optional: OAuth port for browser-based auth
# CLAUDE_OAUTH_PORT=7777

# Optional: Build-time version overrides
# NODE_VERSION=24
# PHP_VERSION=8.5
# PYTHON_VERSION=3.14
# GO_VERSION=1.26
# RUST_VERSION=stable
# TERRAFORM_VERSION=1.11.2
# CLAUDE_CODE_VERSION=latest

# Database credentials (for optional profiles)
# POSTGRES_USER=dev
# POSTGRES_PASSWORD=devpass
# POSTGRES_DB=devdb
# MYSQL_ROOT_PASSWORD=devpass
# MYSQL_DATABASE=devdb
```

### 7. README.md

Comprehensive documentation covering:

1. **Overview** — What this is, why to use it
2. **Prerequisites** — Docker, Docker Compose, API key
3. **Quick Start** — 3-step: clone, configure .env, run start script
4. **Configuration**
   - Environment variables
   - Build-time version ARGs
   - Proxy certificate setup
5. **Volume Mounts Reference** — Table of all volumes with source, target, mode, purpose
6. **Authentication**
   - API key setup
   - OAuth browser login flow
7. **Git Integration**
   - SSH agent forwarding setup (Linux/macOS/Windows WSL)
   - SSH key mounting fallback
   - Git config mounting
   - GPG key considerations
8. **Docker-in-Docker** — How the socket mount works, security implications
9. **Optional Services** — How to enable Redis, PostgreSQL, MySQL, Adminer
10. **Security & Sandboxing**
    - Container isolation model
    - What Claude Code can/cannot access
    - Network restrictions
    - Secrets management best practices
11. **Cross-Platform Usage**
    - Linux
    - macOS
    - Windows (WSL + Docker Desktop)
12. **Troubleshooting** — Common issues and solutions
13. **Customization** — How to extend the image

### 8. Supporting Files

- **`.dockerignore`**: Ignore `.git`, `.env`, `*.md`, etc. to keep build context small
- **`.gitignore`**: Ignore `.env`, `certs/*.pem`, local state
- **`certs/.gitkeep`**: Placeholder for proxy cert directory

---

## Parallelization Strategy (Agent Teams)

The implementation can be parallelized across **4 concurrent agents**:

| Agent | Files | Dependencies |
|-------|-------|-------------|
| **Agent 1: Dockerfile + entrypoint** | `Dockerfile`, `entrypoint.sh`, `.dockerignore` | None |
| **Agent 2: Docker Compose + env** | `docker-compose.yml`, `.env.example` | None |
| **Agent 3: Launch scripts** | `start.sh`, `start.bat` | None |
| **Agent 4: Documentation + git** | `README.md`, `.gitignore`, `certs/.gitkeep` | Needs awareness of all file structures |

Agents 1-3 are fully independent. Agent 4 should run in parallel but may need a final pass after the others to ensure docs match implementation.

---

## Volume Mounts Summary (for README)

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| Current project dir | `/workspace` | rw | Your source code |
| `~/.claude` | `/home/developer/.claude` | rw | Claude Code config, credentials, commands |
| `~/.ssh` | `/home/developer/.ssh-host` | ro | SSH keys for git operations |
| `~/.gitconfig` | `/home/developer/.gitconfig-host` | ro | Git user configuration |
| `/var/run/docker.sock` | `/var/run/docker.sock` | rw | Docker socket for container management |
| `./certs/` | `/certs` | ro | Optional corporate proxy CA certificates |
| Named: `claude-dev-home` | `/home/developer` | rw | Persistent home dir (tool configs, histories) |

---

## Security Model

1. **Container boundary** is the primary sandbox — Claude Code runs inside a Docker container with controlled volume mounts
2. **Non-root user** with sudo — day-to-day operations are non-root; sudo available when needed
3. **Read-only sensitive mounts** — SSH keys and git config are mounted read-only
4. **No new privileges** — `security_opt: no-new-privileges:true` prevents privilege escalation
5. **Resource limits** — Memory and CPU limits prevent runaway processes
6. **Docker socket** is the one deliberate "escape hatch" for container management — documented as a conscious trade-off
7. **Proxy certs** are handled at entrypoint time and propagated to all language runtimes

---

## Open Items / Notes

- The Dockerfile will be large (~2-3GB image) due to multi-language support. This is expected for a full dev environment.
- Python 3.14 and PHP 8.5 may need specific PPA versions — the Dockerfile will handle fallback logic.
- The `claude-dev-home` named volume persists the developer home between container restarts, preserving bash history, tool configs, etc. The `.claude` bind mount takes precedence within it.
- Windows start.bat assumes Docker Desktop with WSL2 backend.
