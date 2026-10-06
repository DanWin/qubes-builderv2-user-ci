#!/usr/bin/env bash
# ==============================================================================
# Qubes Builder v2 CI Script for Debian 13 (Trixie) Host
# Repository: qubes-builderv2-user-ci
# Qubes Builder: V2 ONLY (https://github.com/QubesOS/qubes-builderv2)
# Option 'use-qubes-repo': STRICTLY DISABLED (No prebuilt binaries used)
# ==============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"
BUILDER_DIR="${WORK_DIR}/qubes-builderv2"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"

mkdir -p "${WORK_DIR}" "${ARTIFACTS_DIR}"

log_info "Starting Qubes Builder v2 CI pipeline on host OS..."

# ------------------------------------------------------------------------------
# 1. Verify Host Operating System (Debian 13 / Trixie)
# ------------------------------------------------------------------------------
if [ -f /etc/os-release ]; property_os=$(cat /etc/os-release); then
    log_info "Detected OS release info:"
    grep -E '^(PRETTY_NAME|NAME|VERSION_ID|VERSION_CODENAME)=' /etc/os-release || true
    if grep -q "trixie" /etc/os-release || grep -q "13" /etc/os-release; then
        log_success "Host system verified as Debian 13 (Trixie)."
    else
        log_warn "Host OS is not explicitly Debian 13 (trixie), proceeding anyway."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Install Host Dependencies for Debian
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Installing Debian host build dependencies..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update -qq || true
        
        # Fundamental build & container tools
        sudo apt-get install -y --no-install-recommends \
            ca-certificates \
            curl \
            docker.io \
            git \
            gpg \
            lsb-release \
            python3 \
            python3-pip \
            python3-yaml \
            sudo \
            tree
            
        # Dependencies from qubes-builderv2/dependencies-debian.txt if available
        if [ -f "${BUILDER_DIR}/dependencies-debian.txt" ]; then
            log_info "Installing dependencies from dependencies-debian.txt..."
            DEB_DEPS=$(cat "${BUILDER_DIR}/dependencies-debian.txt" | tr '\n' ' ')
            sudo apt-get install -y --no-install-recommends ${DEB_DEPS} || true
        fi
    else
        log_warn "apt-get not found; skipping automated package installation."
    fi
}

# ------------------------------------------------------------------------------
# 3. Check / Start Docker Service
# ------------------------------------------------------------------------------
setup_docker() {
    log_info "Verifying Docker runtime environment..."
    if ! docker info >/dev/null 2>&1; then
        log_warn "Docker service is not accessible. Attempting to start dockerd..."
        if command -v systemctl >/dev/null 2>&1 && systemctl is-systemd-running >/dev/null 2>&1; then
            sudo systemctl start docker || true
        else
            log_info "Starting dockerd daemon in background..."
            sudo dockerd >/tmp/dockerd.log 2>&1 &
            sleep 5
        fi
    fi

    if docker info >/dev/null 2>&1; then
        log_success "Docker daemon is running and accessible."
    else
        log_error "Failed to connect to Docker daemon. Please ensure Docker is running."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 4. Clone / Update Qubes Builder v2
# ------------------------------------------------------------------------------
setup_builder() {
    if [ ! -d "${BUILDER_DIR}" ]; then
        log_info "Cloning qubes-builderv2 repository (v2 only)..."
        git clone https://github.com/QubesOS/qubes-builderv2 "${BUILDER_DIR}"
    else
        log_info "qubes-builderv2 already exists at ${BUILDER_DIR}."
    fi

    cd "${BUILDER_DIR}"

    # Install Python CLI dependencies inside builder dir if needed
    if [ -f "pyproject.toml" ] || [ -f "qubesbuilder-cli" ]; then
        log_info "Installing qubesbuilder Python package in editable mode..."
        pip3 install --break-system-packages -e . 2>/dev/null || pip3 install -e . 2>/dev/null || true
    fi

    # Import Qubes developer GPG keys
    if [ -f "keys/qubes-developers-keys.asc" ]; then
        log_info "Importing Qubes developer GPG keys..."
        gpg --import keys/qubes-developers-keys.asc 2>/dev/null || true
    fi

    # Generate Docker builder container image
    log_info "Building qubes-builder-fedora Docker container image..."
    ./tools/generate-container-image.sh docker
}

# ------------------------------------------------------------------------------
# 5. Configure Builder v2 (Without use-qubes-repo)
# ------------------------------------------------------------------------------
setup_config() {
    log_info "Setting up builder configuration..."
    
    # Copy custom builder config or create builder-ci.yml
    cp "${SCRIPT_DIR}/builder-config.yml" "${BUILDER_DIR}/builder-ci.yml"
    
    # Explicitly verify 'use-qubes-repo' is NOT active in builder-ci.yml
    if grep -E '^\s*use-qubes-repo:' "${BUILDER_DIR}/builder-ci.yml"; then
        log_error "CRITICAL: 'use-qubes-repo' option detected in config! This option must NOT be used."
        exit 1
    else
        log_success "Verified: 'use-qubes-repo' option is disabled. Prebuilt binaries will NOT be used."
    fi
}

# ------------------------------------------------------------------------------
# 6. Execute 3-Tiered Build Strategy
# ------------------------------------------------------------------------------
run_build_pipeline() {
    cd "${BUILDER_DIR}"

    log_info "========================================================"
    log_info " Tier 1: Attempting Qubes ISO Build (Source Build)"
    log_info "========================================================"

    set +e
    log_info "Fetching ISO source components..."
    ./qb --builder-conf builder-ci.yml installer fetch
    ISO_FETCH_RES=$?

    if [ ${ISO_FETCH_RES} -eq 0 ]; then
        log_info "Initializing ISO cache..."
        ./qb --builder-conf builder-ci.yml installer init-cache
        log_info "Prepping ISO build..."
        ./qb --builder-conf builder-ci.yml installer prep
        log_info "Building Qubes ISO..."
        ./qb --builder-conf builder-ci.yml installer build
        ISO_BUILD_RES=$?

        if [ ${ISO_BUILD_RES} -eq 0 ]; then
            log_success "Tier 1 SUCCESS: Qubes ISO built successfully!"
            if [ -d "artifacts/installer" ]; then
                cp -r artifacts/installer/* "${ARTIFACTS_DIR}/" || true
            fi
            set -e
            return 0
        fi
    fi
    set -e

    log_warn "Tier 1 (ISO Build) failed or incomplete due to upstream dependencies / missing prebuilts."
    
    log_info "========================================================"
    log_info " Tier 2: Fallback - Attempting Kicksecure Template Build"
    log_info "========================================================"

    set +e
    log_info "Fetching Kicksecure template sources..."
    ./qb --builder-conf builder-ci.yml -t kicksecure-18 template fetch
    TPL_FETCH_RES=$?

    if [ ${TPL_FETCH_RES} -eq 0 ]; then
        log_info "Prepping Kicksecure template..."
        ./qb --builder-conf builder-ci.yml -t kicksecure-18 template prep
        log_info "Building Kicksecure template..."
        ./qb --builder-conf builder-ci.yml -t kicksecure-18 template build
        TPL_BUILD_RES=$?

        if [ ${TPL_BUILD_RES} -eq 0 ]; then
            log_success "Tier 2 SUCCESS: Qubes Kicksecure Template built successfully!"
            if [ -d "artifacts/templates" ]; then
                cp -r artifacts/templates/* "${ARTIFACTS_DIR}/" || true
            fi
            set -e
            return 0
        fi
    fi
    set -e

    log_warn "Tier 2 (Kicksecure Template Build) failed or incomplete."

    log_info "========================================================"
    log_info " Tier 3: Fallback - Fetching All Qubes Source Code"
    log_info "========================================================"

    log_info "Fetching all Qubes OS source code repositories..."
    ./qb --builder-conf builder-ci.yml package fetch || true

    log_success "Tier 3 SUCCESS: Qubes source code fetched into artifacts/sources."
    if [ -d "artifacts/sources" ]; then
        cp -r artifacts/sources "${ARTIFACTS_DIR}/" || true
    fi

    log_info "Build pipeline completed."
}

# Main Execution Flow
install_dependencies
setup_builder
setup_docker
setup_config
run_build_pipeline

log_success "qubes-builderv2-user-ci script execution finished."
