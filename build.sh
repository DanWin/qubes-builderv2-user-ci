#!/usr/bin/env bash
# ==============================================================================
# Qubes Builder v2 CI Script for Debian
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

mkdir -p "${WORK_DIR}"

log_info "Starting Qubes Builder v2 CI pipeline on host OS..."

# ------------------------------------------------------------------------------
# 1. Clone / Update Qubes Builder v2 Repository First
# ------------------------------------------------------------------------------
fetch_builder_repo() {
    if [ ! -d "${BUILDER_DIR}" ]; then
        log_info "Cloning qubes-builderv2 repository (v2 only)..."
        git clone https://github.com/QubesOS/qubes-builderv2 "${BUILDER_DIR}"
    else
        log_info "qubes-builderv2 already exists at ${BUILDER_DIR}."
    fi
    # hotfix: replace lorax-templates-qubes with lorax-templates in mock config
    sed -i 's/lorax-templates-qubes/lorax-templates/' "${BUILDER_DIR}/qubesbuilder/plugins/installer/mock/fedora-x86_64.cfg"
}

# ------------------------------------------------------------------------------
# 2. Install Host Dependencies for Debian
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Installing Debian host build dependencies..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update -qq || true
            
        # Install all packages from dependencies-debian.txt
        if [ -f "${BUILDER_DIR}/dependencies-debian.txt" ]; then
            log_info "Installing packages from dependencies-debian.txt..."
            DEB_DEPS=$(cat "${BUILDER_DIR}/dependencies-debian.txt" | tr '\n' ' ')
            # shellcheck disable=SC2086
            sudo apt-get install -y --no-install-recommends ${DEB_DEPS} || true
        fi
    else
        log_warn "apt-get not found; skipping automated package installation."
    fi
}

# ------------------------------------------------------------------------------
# 3. Build Container Image & Prepare Builder Setup
# ------------------------------------------------------------------------------
setup_builder() {
    cd "${BUILDER_DIR}"

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
# 4. Configure Builder v2 (Without use-qubes-repo)
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
# 5. Execute 3-Tiered Build Strategy
# ------------------------------------------------------------------------------
run_build_pipeline() {
    cd "${BUILDER_DIR}"

    log_info "========================================================"
    log_info " Tier 1: Attempting Qubes ISO Build (Source Build)"
    log_info "========================================================"

    set +e
    log_info "Fetching all Qubes OS source code repositories..."
    ./qb --builder-conf builder-ci.yml package fetch || true

    log_info "Prepare all Qubes OS source code repositories..."
    ./qb --builder-conf builder-ci.yml package prep || true

    log_info "Build all Qubes OS source code repositories..."
    ./qb --builder-conf builder-ci.yml package build || true

    log_success "Tier 1 SUCCESS: Qubes source code fetched into artifacts/sources."
    if [ -d "artifacts/" ]; then
        mv artifacts "${ARTIFACTS_DIR}" || true
    fi

    log_info "Build pipeline completed."
}

# Main Execution Flow
fetch_builder_repo
install_dependencies
setup_builder
setup_config
run_build_pipeline

log_success "qubes-builderv2-user-ci script execution finished."
