#!/usr/bin/env bash
# NOTE: This script must be executable. Run: chmod +x start.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Determine directories
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    COLOR_INFO="\033[1;34m"   # bold blue
    COLOR_WARN="\033[1;33m"   # bold yellow
    COLOR_ERROR="\033[1;31m"  # bold red
    COLOR_SUCCESS="\033[1;32m" # bold green
    COLOR_DIM="\033[0;37m"    # dim white
    COLOR_RESET="\033[0m"
else
    COLOR_INFO="" COLOR_WARN="" COLOR_ERROR="" COLOR_SUCCESS="" COLOR_DIM="" COLOR_RESET=""
fi

info()    { printf "${COLOR_INFO}[INFO]${COLOR_RESET}  %s\n" "$*"; }
warn()    { printf "${COLOR_WARN}[WARN]${COLOR_RESET}  %s\n" "$*" >&2; }
error()   { printf "${COLOR_ERROR}[ERROR]${COLOR_RESET} %s\n" "$*" >&2; }
success() { printf "${COLOR_SUCCESS}[OK]${COLOR_RESET}    %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<'HELP'
Usage: start.sh [OPTIONS]

Launch the Claude Code development environment.

Options:
  -b, --build            Force rebuild the Docker image
  -c, --claude           Start Claude Code directly (instead of bash)
  -d, --detach           Run in detached/background mode
  -p, --profile NAME     Enable a compose profile (e.g., database)
  -s, --shell SHELL      Use a different shell (default: bash)
      --down             Stop and remove the environment
  -h, --help             Show this help message

Examples:
  start.sh                     # Start bash in the dev environment
  start.sh --claude            # Start Claude Code directly
  start.sh --build --claude    # Rebuild image and start Claude Code
  start.sh --profile database  # Start with database services
  start.sh --down              # Stop the environment
HELP
}

# ---------------------------------------------------------------------------
# Parse CLI flags
# ---------------------------------------------------------------------------
BUILD=0
DETACH=0
DOWN=0
CUSTOM_CMD=""
PROFILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--build)
            BUILD=1
            shift
            ;;
        -p|--profile)
            if [[ -z "${2:-}" ]]; then
                error "Option $1 requires a profile name."
                exit 1
            fi
            PROFILES+=("$2")
            shift 2
            ;;
        -d|--detach)
            DETACH=1
            shift
            ;;
        -c|--claude)
            CUSTOM_CMD="claude"
            shift
            ;;
        --down)
            DOWN=1
            shift
            ;;
        -s|--shell)
            if [[ -z "${2:-}" ]]; then
                error "Option $1 requires a shell name."
                exit 1
            fi
            CUSTOM_CMD="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
    # Docker installed?
    if ! command -v docker &>/dev/null; then
        error "Docker is not installed or not in PATH."
        error "Install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi

    # Docker daemon running?
    if ! docker info &>/dev/null 2>&1; then
        error "Docker daemon is not running."
        error "Please start Docker Desktop or the Docker service and try again."
        exit 1
    fi

    # Docker Compose available? (plugin first, then standalone)
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null && docker-compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
        warn "Using standalone docker-compose. Consider upgrading to the Docker Compose plugin."
    else
        error "Docker Compose is not available."
        error "Install the Compose plugin: https://docs.docker.com/compose/install/"
        exit 1
    fi

    # Docker socket accessible?
    local docker_sock="/var/run/docker.sock"
    if [[ -e "$docker_sock" ]] && [[ ! -r "$docker_sock" ]]; then
        warn "Docker socket ($docker_sock) exists but is not readable."
        warn "You may need to add your user to the 'docker' group or run with sudo."
    fi

    success "Prerequisites satisfied ($(docker --version | head -1))"
}

check_prerequisites

# ---------------------------------------------------------------------------
# WSL detection
# ---------------------------------------------------------------------------
IS_WSL=0
if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
    IS_WSL=1
    info "Windows Subsystem for Linux (WSL) detected."
fi

# ---------------------------------------------------------------------------
# Source .env file (from SCRIPT_DIR, not PROJECT_DIR)
# ---------------------------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    info "Loading environment from $ENV_FILE"
    set -o allexport
    # Source only non-comment, non-empty lines
    # shellcheck disable=SC1090
    source <(grep -E '^[A-Za-z_][A-Za-z_0-9]*=' "$ENV_FILE" | sed 's/\r$//')
    set +o allexport
else
    info "No .env file found at $ENV_FILE — continuing with defaults."
fi

# ---------------------------------------------------------------------------
# SSH agent forwarding
# ---------------------------------------------------------------------------
SSH_VOLUMES=()
SSH_ENVS=()

if [[ -n "${SSH_AUTH_SOCK:-}" ]] && [[ -S "$SSH_AUTH_SOCK" ]]; then
    info "SSH agent detected — enabling forwarding into the container."
    SSH_VOLUMES=(-v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock")
    SSH_ENVS=(-e "SSH_AUTH_SOCK=/tmp/ssh-agent.sock")
elif [[ $IS_WSL -eq 1 ]]; then
    warn "SSH agent forwarding in WSL may require npiperelay or socat bridge."
    warn "See: https://stuartleeks.com/posts/wsl-ssh-key-forward-to-windows/"
else
    info "No SSH agent socket found — SSH forwarding disabled."
fi

# ---------------------------------------------------------------------------
# Export key variables
# ---------------------------------------------------------------------------
export PROJECT_DIR
export HOME="${HOME}"
export CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# ---------------------------------------------------------------------------
# Ensure ~/.claude directory exists on host
# ---------------------------------------------------------------------------
if [[ ! -d "$CLAUDE_HOME" ]]; then
    info "Creating Claude home directory: $CLAUDE_HOME"
    mkdir -p "$CLAUDE_HOME"
fi

# ---------------------------------------------------------------------------
# Build the compose command
# ---------------------------------------------------------------------------
COMPOSE=(${COMPOSE_CMD})
COMPOSE+=(-f "$SCRIPT_DIR/docker-compose.yml")

if [[ -f "$ENV_FILE" ]]; then
    COMPOSE+=(--env-file "$ENV_FILE")
fi

# Add profiles
for profile in "${PROFILES[@]+"${PROFILES[@]}"}"; do
    COMPOSE+=(--profile "$profile")
done

# Handle --down: stop and remove containers, then exit
if [[ $DOWN -eq 1 ]]; then
    info "Stopping and removing containers..."
    "${COMPOSE[@]}" down --remove-orphans
    success "Environment stopped."
    exit 0
fi

# Build flag
if [[ $BUILD -eq 1 ]]; then
    COMPOSE+=(--build)
fi

# Run mode
if [[ $DETACH -eq 1 ]]; then
    COMPOSE+=(up -d)
else
    COMPOSE+=(run --rm)
    COMPOSE+=(--service-ports)

    # Pass SSH volumes and env vars into the run command
    for vol in "${SSH_VOLUMES[@]+"${SSH_VOLUMES[@]}"}"; do
        COMPOSE+=("$vol")
    done
    for env_var in "${SSH_ENVS[@]+"${SSH_ENVS[@]}"}"; do
        COMPOSE+=("$env_var")
    done

    # Service name — default is "dev"
    COMPOSE+=(dev)

    # Custom command override
    if [[ -n "$CUSTOM_CMD" ]]; then
        COMPOSE+=("$CUSTOM_CMD")
    fi
fi

# ---------------------------------------------------------------------------
# Handle Ctrl+C cleanly
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    warn "Caught interrupt — cleaning up..."
    # If running in detach mode, offer to stop
    if [[ $DETACH -eq 1 ]]; then
        info "Containers may still be running. Use '$0 --down' to stop them."
    fi
    exit 130
}
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Print banner
# ---------------------------------------------------------------------------
echo ""
printf "${COLOR_INFO}╔══════════════════════════════════════════════════════════╗${COLOR_RESET}\n"
printf "${COLOR_INFO}║         Claude Code Development Environment             ║${COLOR_RESET}\n"
printf "${COLOR_INFO}╚══════════════════════════════════════════════════════════╝${COLOR_RESET}\n"
echo ""
info "Project directory : $PROJECT_DIR"
info "Script directory  : $SCRIPT_DIR"
info "Claude home       : $CLAUDE_HOME"

if [[ ${#PROFILES[@]} -gt 0 ]]; then
    info "Profiles enabled  : ${PROFILES[*]}"
fi

if [[ -n "$CUSTOM_CMD" ]]; then
    info "Command override  : $CUSTOM_CMD"
fi

if [[ $DETACH -eq 1 ]]; then
    info "Mode              : detached (background)"
else
    info "Mode              : interactive"
fi

echo ""
info "Starting environment..."
echo ""

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
exec "${COMPOSE[@]}"
