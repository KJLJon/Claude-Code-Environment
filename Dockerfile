# =============================================================================
# Claude Code Docker Development Environment
# Base: Ubuntu 24.04 LTS
# =============================================================================

FROM ubuntu:24.04

# ---- Build arguments with version defaults ----
ARG NODE_VERSION=24
ARG PHP_VERSION=8.5
ARG PYTHON_VERSION=3.14
ARG GO_VERSION=1.26
ARG RUST_VERSION=stable
ARG TERRAFORM_VERSION=1.11.2
ARG USER_NAME=developer
ARG USER_UID=1000
ARG USER_GID=1000

# ---- Environment variables ----
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    GOPATH=/home/${USER_NAME}/go \
    PATH="/usr/local/go/bin:/home/${USER_NAME}/go/bin:/home/${USER_NAME}/.cargo/bin:/home/${USER_NAME}/.local/bin:${PATH}" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    SHELL=/bin/bash \
    DEBIAN_FRONTEND=noninteractive

# =============================================================================
# 1. System packages
# =============================================================================
RUN set -eux && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        wget \
        jq \
        vim \
        nano \
        htop \
        tmux \
        ripgrep \
        fd-find \
        fzf \
        zip \
        unzip \
        ca-certificates \
        gnupg \
        sudo \
        openssh-client \
        bash-completion \
        build-essential \
        pkg-config \
        libssl-dev \
        software-properties-common \
        apt-transport-https \
        locales \
        less \
        man-db \
        procps \
        lsb-release \
        xz-utils \
        zlib1g-dev \
        libreadline-dev \
        libbz2-dev \
        libsqlite3-dev \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# 2. Set locale to en_US.UTF-8
# =============================================================================
RUN set -eux && \
    sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen en_US.UTF-8

# =============================================================================
# 3. Node.js via NodeSource
# =============================================================================
RUN set -eux && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    corepack enable && \
    npm install -g typescript ts-node tsx

# =============================================================================
# 4. PHP via Ondrej PPA + Composer
# =============================================================================
RUN set -eux && \
    add-apt-repository -y ppa:ondrej/php && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-common \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-pgsql \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-readline \
    && rm -rf /var/lib/apt/lists/* && \
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# =============================================================================
# 5. Python via deadsnakes PPA
# =============================================================================
RUN set -eux && \
    add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-venv \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-distutils \
    && rm -rf /var/lib/apt/lists/* && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 && \
    python${PYTHON_VERSION} -m ensurepip --upgrade && \
    python${PYTHON_VERSION} -m pip install --upgrade pip && \
    python${PYTHON_VERSION} -m pip install pipx poetry uv

# =============================================================================
# 6. Go
# =============================================================================
RUN set -eux && \
    curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz | tar -C /usr/local -xz

# =============================================================================
# 7. User setup (needed before Rust install as non-root)
# =============================================================================
RUN set -eux && \
    groupadd --gid ${USER_GID} ${USER_NAME} && \
    useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --home-dir /home/${USER_NAME} --shell /bin/bash ${USER_NAME} && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME} && \
    chmod 0440 /etc/sudoers.d/${USER_NAME} && \
    groupadd --gid 999 docker && \
    usermod -aG sudo,docker ${USER_NAME} && \
    mkdir -p /home/${USER_NAME}/go /home/${USER_NAME}/.local/bin && \
    chown -R ${USER_UID}:${USER_GID} /home/${USER_NAME}

# =============================================================================
# 7 (cont). Rust — must be installed as the developer user
# =============================================================================
USER ${USER_NAME}

RUN set -eux && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VERSION}

USER root

# =============================================================================
# 8. Terraform
# =============================================================================
RUN set -eux && \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip && \
    unzip /tmp/terraform.zip -d /usr/local/bin && \
    rm /tmp/terraform.zip

# =============================================================================
# 9. AWS CLI v2
# =============================================================================
RUN set -eux && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws

# =============================================================================
# 10. Docker CLI + Compose plugin
# =============================================================================
RUN set -eux && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# 11. Claude Code (npm bootstrap + native install attempt)
# =============================================================================
USER ${USER_NAME}

RUN set -eux && \
    npm install -g @anthropic-ai/claude-code && \
    claude install || echo "Native install failed; falling back to npm version"

USER root

# =============================================================================
# 12. yq
# =============================================================================
RUN set -eux && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# =============================================================================
# Workspace + entrypoint
# =============================================================================
RUN mkdir -p /workspace && chown ${USER_UID}:${USER_GID} /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

USER ${USER_NAME}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
