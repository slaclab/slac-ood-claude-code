# ── Stage 0: build patched ttyd ──────────────────────────────────────────────
# Pins to 1.7.7 for supply-chain safety; patch adds --credential-file so the
# password never appears in ps aux / /proc/cmdline on shared interactive nodes.
#
# Builds libwebsockets from source with -DLWS_WITH_LIBUV=ON — the apt package
# ships without the uv event loop plugin that ttyd requires. Pin to v4.3.3
# (the version ttyd 1.7.7 was tested against, per its startup log).
FROM ubuntu:24.04 AS ttyd-builder
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    libjson-c-dev \
    libssl-dev \
    libuv1-dev \
    zlib1g-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build libwebsockets from source with libuv support
ARG LWS_VERSION=v4.3.3
RUN git clone https://github.com/warmcat/libwebsockets.git /lws \
    && git -C /lws checkout ${LWS_VERSION}
RUN cmake -S /lws -B /lws/build \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_BUILD_TYPE=Release \
        -DLWS_WITH_LIBUV=ON \
        -DLWS_WITH_EVLIB_PLUGINS=OFF \
        -DLWS_WITHOUT_TESTAPPS=ON \
        -DLWS_WITHOUT_TEST_SERVER=ON \
        -DLWS_WITHOUT_TEST_PING=ON \
        -DLWS_WITHOUT_TEST_CLIENT=ON \
    && cmake --build /lws/build --parallel \
    && cmake --install /lws/build

# Clone and patch ttyd
ARG TTYD_VERSION=1.7.7
RUN git clone https://github.com/tsl0922/ttyd.git /ttyd \
    && git -C /ttyd checkout ${TTYD_VERSION}

COPY ttyd-credential-file.patch /ttyd-credential-file.patch
RUN patch -p1 -d /ttyd < /ttyd-credential-file.patch

# Build ttyd against the locally-built libwebsockets
RUN cmake -S /ttyd -B /ttyd/build \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH=/usr/local \
    && cmake --build /ttyd/build --parallel \
    && cmake --install /ttyd/build
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: final image ──────────────────────────────────────────────────────
# Use Ubuntu 24.04 LTS as the base image
FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    bash \
    ca-certificates \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    # Build tools (needed for Python packages with C extensions)
    build-essential \
    # JSON processing
    jq \
    # Hex dump utility
    bsdextrautils \
    # Fast code search (used internally by Claude Code)
    ripgrep \
    # Text editors
    vim \
    nano \
    # SSH client for git over SSH remotes
    openssh-client \
    # Runtime libraries for ttyd (libwebsockets built from source with libuv support)
    libjson-c5 \
    libuv1t64 \
    && rm -rf /var/lib/apt/lists/*

# Install Python testing and deployment libraries via pip
RUN pip3 install --break-system-packages \
    # Testing
    pytest \
    pytest-cov \
    pytest-mock \
    pluggy \
    requests-mock \
    # HTTP / API clients
    requests \
    httpx \
    # Deployment / ops scripting
    pyyaml \
    python-dotenv \
    click \
    boto3 \
    # Data / validation
    pydantic \
    # MCP server: fetch URLs and convert to markdown (saves tokens)
    mcp-server-fetch \
    # Code knowledge graph generator
    graphifyy

# Install mempalace. MEMPALACE_VERSION is passed by the Makefile (resolved from
# PyPI at build time) and acts as a cache-buster — the layer reruns whenever a
# new release is published.
ARG MEMPALACE_VERSION=unknown
RUN echo "Installing mempalace (upstream version: ${MEMPALACE_VERSION})" \
    && pip3 install --break-system-packages mempalace

# Install Node.js (LTS) via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install GitNexus (code intelligence / knowledge graph engine)
RUN npm install -g gitnexus

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl (latest stable via official Kubernetes apt repo)
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
        | gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
        | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null \
    && apt-get update \
    && apt-get install -y kubectl \
    && rm -rf /var/lib/apt/lists/*

# Install HashiCorp Vault (via official HashiCorp apt repo)
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com noble main" \
        | tee /etc/apt/sources.list.d/hashicorp.list > /dev/null \
    && apt-get update \
    && apt-get install -y vault \
    && rm -rf /var/lib/apt/lists/*

# Install ttyd (patched build from ttyd-builder stage — supports --credential-file)
# Also copy the custom libwebsockets build (built with -DLWS_WITH_LIBUV=ON;
# the apt package lacks the uv event loop plugin ttyd requires).
COPY --from=ttyd-builder /usr/local/bin/ttyd /usr/local/bin/ttyd
COPY --from=ttyd-builder /usr/local/lib/libwebsockets.so* /usr/local/lib/
RUN ldconfig

# Create a non-root user to run Claude Code (recommended for security)
RUN useradd -ms /bin/bash claudeuser

# Switch to the non-root user
USER claudeuser
WORKDIR /home/claudeuser
RUN chmod ugo+rx /home/claudeuser

RUN mkdir -p /home/claudeuser/.local/bin/

# Install Marp CLI (Markdown presentation tool)
RUN curl -fsSL https://github.com/marp-team/marp-cli/releases/download/v4.3.1/marp-cli-v4.3.1-linux.tar.gz \
        | tar -xz -C /home/claudeuser/.local/bin/ marp

# Install uv (fast Python package manager).
# UV_VERSION is passed by the Makefile (resolved from PyPI at build time) and
# acts as a cache-buster — the layer reruns whenever a new uv release is out.
ARG UV_VERSION=unknown
RUN echo "Installing uv (upstream version: ${UV_VERSION})" \
    && curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Claude Code using the official native installer.
# CLAUDE_VERSION is passed by the Makefile (resolved from the npm registry at
# build time).  Its sole purpose is cache-busting: Docker invalidates this
# layer — and every layer after it — whenever a new version is published, so
# `make build` always installs the latest release without needing --no-cache.
ARG CLAUDE_VERSION=unknown
RUN echo "Installing Claude Code (upstream version: ${CLAUDE_VERSION})" \
    && curl -fsSL https://claude.ai/install.sh | bash

# Add Claude Code to PATH
ENV PATH="/home/claudeuser/.local/bin:${PATH}"

# Set the ANTHROPIC_API_KEY environment variable placeholder
# Pass your key at runtime: docker run -e ANTHROPIC_API_KEY=your_key_here ...
ENV ANTHROPIC_API_KEY=""

# Default working directory for projects (mount your project here)
WORKDIR /home/claudeuser/project

# Verify the installation
RUN claude --version

# Default entrypoint
ENTRYPOINT ["claude"]
CMD ["--help"]
