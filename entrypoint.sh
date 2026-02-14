#!/usr/bin/env bash
set -e

# =============================================================================
# Claude Code Development Environment - Entrypoint Script
# =============================================================================
# This script runs on container start and handles:
# 1. Corporate proxy certificate installation
# 2. Git configuration from host mount
# 3. SSH key setup (agent forwarding or key copying)
# 4. Docker socket permissions
# 5. Custom entrypoint extensions
# =============================================================================

USER_NAME="${USER_NAME:-developer}"
USER_HOME="/home/${USER_NAME}"

# -----------------------------------------------------------------------------
# 1. Corporate Proxy Certificates
# -----------------------------------------------------------------------------
install_proxy_certs() {
    local certs_dir="/certs"
    local cert_dest="/usr/local/share/ca-certificates/custom"
    local certs_found=0

    if [ -d "$certs_dir" ] && [ "$(ls -A "$certs_dir"/*.pem 2>/dev/null)" ]; then
        echo "[entrypoint] Installing corporate proxy certificates..."
        sudo mkdir -p "$cert_dest"

        for cert in "$certs_dir"/*.pem; do
            if [ -f "$cert" ]; then
                local cert_name
                cert_name="$(basename "$cert" .pem).crt"
                sudo cp "$cert" "$cert_dest/$cert_name"
                certs_found=$((certs_found + 1))
                echo "[entrypoint]   Installed: $cert_name"
            fi
        done

        # Also handle .crt files
        for cert in "$certs_dir"/*.crt; do
            if [ -f "$cert" ]; then
                sudo cp "$cert" "$cert_dest/"
                certs_found=$((certs_found + 1))
                echo "[entrypoint]   Installed: $(basename "$cert")"
            fi
        done

        if [ "$certs_found" -gt 0 ]; then
            sudo update-ca-certificates 2>/dev/null

            # Create a combined CA bundle for tools that need a single file
            local combined_bundle="/etc/ssl/certs/custom-ca-certificates.crt"
            sudo cat /etc/ssl/certs/ca-certificates.crt > /dev/null 2>&1

            # Set environment variables for various tools
            export NODE_EXTRA_CA_CERTS="/etc/ssl/certs/ca-certificates.crt"
            export REQUESTS_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
            export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
            export CURL_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
            export GIT_SSL_CAINFO="/etc/ssl/certs/ca-certificates.crt"

            # Persist these for the user's shell sessions
            {
                echo "export NODE_EXTRA_CA_CERTS=\"/etc/ssl/certs/ca-certificates.crt\""
                echo "export REQUESTS_CA_BUNDLE=\"/etc/ssl/certs/ca-certificates.crt\""
                echo "export SSL_CERT_FILE=\"/etc/ssl/certs/ca-certificates.crt\""
                echo "export CURL_CA_BUNDLE=\"/etc/ssl/certs/ca-certificates.crt\""
                echo "export GIT_SSL_CAINFO=\"/etc/ssl/certs/ca-certificates.crt\""
            } >> "$USER_HOME/.bashrc.d/proxy-certs.sh"

            echo "[entrypoint] Installed $certs_found certificate(s) and configured CA bundles."
        fi
    fi
}

# -----------------------------------------------------------------------------
# 2. Git Configuration
# -----------------------------------------------------------------------------
setup_git_config() {
    local host_gitconfig="$USER_HOME/.gitconfig-host"

    if [ -f "$host_gitconfig" ] && [ ! -f "$USER_HOME/.gitconfig" ]; then
        echo "[entrypoint] Linking host git configuration..."
        ln -sf "$host_gitconfig" "$USER_HOME/.gitconfig"
    elif [ -f "$host_gitconfig" ] && [ -f "$USER_HOME/.gitconfig" ]; then
        echo "[entrypoint] Git config already exists, skipping host config link."
    fi
}

# -----------------------------------------------------------------------------
# 3. SSH Setup
# -----------------------------------------------------------------------------
setup_ssh() {
    local ssh_host_dir="$USER_HOME/.ssh-host"
    local ssh_dir="$USER_HOME/.ssh"

    # Option A: SSH Agent Forwarding
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
        echo "[entrypoint] SSH agent socket detected at $SSH_AUTH_SOCK"
        # Ensure the socket is accessible
        if [ ! -r "${SSH_AUTH_SOCK}" ]; then
            echo "[entrypoint] Warning: SSH agent socket is not readable. Trying to fix..."
            sudo chmod 777 "$(dirname "${SSH_AUTH_SOCK}")" 2>/dev/null || true
        fi
    fi

    # Option B: Copy SSH keys from read-only mount
    if [ -d "$ssh_host_dir" ] && [ "$(ls -A "$ssh_host_dir" 2>/dev/null)" ]; then
        echo "[entrypoint] Setting up SSH keys from host mount..."
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"

        # Copy all files, preserving structure
        for item in "$ssh_host_dir"/*; do
            if [ -f "$item" ]; then
                local filename
                filename="$(basename "$item")"
                cp "$item" "$ssh_dir/$filename"

                # Set correct permissions based on file type
                case "$filename" in
                    *.pub|known_hosts|authorized_keys|config)
                        chmod 644 "$ssh_dir/$filename"
                        ;;
                    *)
                        chmod 600 "$ssh_dir/$filename"
                        ;;
                esac
            fi
        done

        # Ensure known_hosts exists for common hosts
        if [ ! -f "$ssh_dir/known_hosts" ]; then
            ssh-keyscan github.com gitlab.com bitbucket.org >> "$ssh_dir/known_hosts" 2>/dev/null || true
            chmod 644 "$ssh_dir/known_hosts"
        fi

        echo "[entrypoint] SSH keys configured."
    fi
}

# -----------------------------------------------------------------------------
# 4. Docker Socket Permissions
# -----------------------------------------------------------------------------
setup_docker_socket() {
    local docker_sock="/var/run/docker.sock"

    if [ -S "$docker_sock" ]; then
        # Get the GID of the docker socket
        local sock_gid
        sock_gid="$(stat -c '%g' "$docker_sock" 2>/dev/null || echo "")"

        if [ -n "$sock_gid" ] && [ "$sock_gid" != "0" ]; then
            # If the socket GID doesn't match the container's docker group, fix it
            local docker_gid
            docker_gid="$(getent group docker | cut -d: -f3 2>/dev/null || echo "999")"

            if [ "$sock_gid" != "$docker_gid" ]; then
                echo "[entrypoint] Adjusting Docker socket group (host GID: $sock_gid)..."
                sudo groupmod -g "$sock_gid" docker 2>/dev/null || true
            fi
        else
            # Socket owned by root, make it accessible
            sudo chmod 666 "$docker_sock" 2>/dev/null || true
        fi
    fi
}

# -----------------------------------------------------------------------------
# 5. Workspace Ownership
# -----------------------------------------------------------------------------
setup_workspace() {
    # Only fix ownership if workspace is empty or owned by root
    if [ -d "/workspace" ]; then
        local ws_owner
        ws_owner="$(stat -c '%u' /workspace 2>/dev/null || echo "0")"
        if [ "$ws_owner" = "0" ]; then
            echo "[entrypoint] Fixing workspace ownership..."
            sudo chown "${USER_NAME}:${USER_NAME}" /workspace 2>/dev/null || true
        fi
    fi
}

# -----------------------------------------------------------------------------
# 6. Initialize bashrc.d
# -----------------------------------------------------------------------------
setup_bashrc() {
    local bashrc_d="$USER_HOME/.bashrc.d"
    mkdir -p "$bashrc_d"

    # Add bashrc.d sourcing to .bashrc if not already present
    if ! grep -q "bashrc.d" "$USER_HOME/.bashrc" 2>/dev/null; then
        cat >> "$USER_HOME/.bashrc" << 'BASHRC'

# Source all scripts in ~/.bashrc.d/
if [ -d "$HOME/.bashrc.d" ]; then
    for script in "$HOME/.bashrc.d"/*.sh; do
        [ -f "$script" ] && source "$script"
    done
fi
BASHRC
    fi
}

# -----------------------------------------------------------------------------
# 7. Custom Entrypoint Extension
# -----------------------------------------------------------------------------
run_custom_entrypoint() {
    local custom_script="/usr/local/bin/custom-entrypoint.sh"
    if [ -f "$custom_script" ] && [ -x "$custom_script" ]; then
        echo "[entrypoint] Running custom entrypoint extension..."
        source "$custom_script"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "[entrypoint] Initializing Claude Code development environment..."

    # Create bashrc.d directory for environment persistence
    setup_bashrc

    # Install proxy certs (needs sudo, so do first)
    install_proxy_certs

    # Set up git config
    setup_git_config

    # Set up SSH
    setup_ssh

    # Fix Docker socket permissions
    setup_docker_socket

    # Fix workspace ownership
    setup_workspace

    # Run custom entrypoint if present
    run_custom_entrypoint

    echo "[entrypoint] Environment ready. Starting: $*"
    echo ""

    # Hand off to the user's command
    exec "$@"
}

main "$@"
