#!/usr/bin/env bash
#
# KubeVirt PPC64LE Cross-Compilation Build Script
# 
# This script automates the cross-compilation of KubeVirt for ppc64le architecture
# from an x86_64 machine. It handles dependency checks, builds binaries and container
# images, and pushes them to a container registry.
#
# Usage:
#   ./scripts/build-ppc64le-cross.sh [OPTIONS]
#
# Options:
#   --registry REGISTRY    Container registry (default: quay.io/pkenchap)
#   --tag TAG             Image tag (default: auto-generated from git)
#   --skip-build          Skip binary build step
#   --skip-images         Skip image build step
#   --skip-push           Skip image push step
#   --help                Show this help message
#
# Environment Variables:
#   DOCKER_PREFIX         Container registry prefix (overrides --registry)
#   DOCKER_TAG            Image tag (overrides --tag)
#   KUBEVIRT_CENTOS_STREAM_VERSION  CentOS Stream version (default: 10)
#
# Author: Punith Kenchappa (pkenchap@in.ibm.com)
# Branch: ppc64le-2025

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Try to find KubeVirt root directory
if [[ -d "${SCRIPT_DIR}/../.git" ]]; then
    # Script is in a subdirectory of the repo
    KUBEVIRT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
elif [[ -d "${SCRIPT_DIR}/.git" ]]; then
    # Script is in the repo root
    KUBEVIRT_DIR="${SCRIPT_DIR}"
else
    # Assume current directory is the repo root
    KUBEVIRT_DIR="$(pwd)"
fi

# Default values
DEFAULT_REGISTRY="quay.io/pkenchap"
DEFAULT_BUILDER_IMAGE="quay.io/pkenchap/builder-cross:2607310525-5ceec62cd7"
DEFAULT_CENTOS_VERSION="10"
SKIP_BUILD=false
SKIP_IMAGES=false
SKIP_PUSH=false

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

# Function to show usage
show_usage() {
    cat << EOF
KubeVirt PPC64LE Cross-Compilation Build Script

Usage: $0 [OPTIONS]

Options:
  --registry REGISTRY    Container registry (default: ${DEFAULT_REGISTRY})
  --tag TAG             Image tag (default: auto-generated from git)
  --skip-build          Skip binary build step
  --skip-images         Skip image build step
  --skip-push           Skip image push step
  --help                Show this help message

Environment Variables:
  DOCKER_PREFIX                    Container registry prefix (overrides --registry)
  DOCKER_TAG                       Image tag (overrides --tag)
  KUBEVIRT_CENTOS_STREAM_VERSION   CentOS Stream version (default: ${DEFAULT_CENTOS_VERSION})

Examples:
  # Build everything with default settings
  $0

  # Build with custom registry and tag
  $0 --registry quay.io/myuser --tag v1.0.5-ppc64le

  # Build only binaries (skip images and push)
  $0 --skip-images --skip-push

  # Build and push images (skip binary build)
  $0 --skip-build

EOF
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    local missing_deps=()
    
    # Check architecture
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        print_error "This script must be run on an x86_64 machine. Current architecture: $arch"
        exit 1
    fi
    print_success "Running on x86_64 architecture"
    
    # Check required commands
    local required_commands=("git" "make" "rsync")
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
            print_error "Missing required command: $cmd"
        else
            print_success "Found: $cmd"
        fi
    done
    
    # Check container runtime (podman or docker)
    if command_exists podman; then
        export KUBEVIRT_CRI="podman"
        print_success "Found container runtime: podman"
    elif command_exists docker; then
        export KUBEVIRT_CRI="docker"
        print_success "Found container runtime: docker"
    else
        missing_deps+=("podman or docker")
        print_error "No container runtime found. Please install podman or docker"
    fi
    
    # Check optional but recommended commands
    if ! command_exists skopeo; then
        print_warning "skopeo not found - required for pushing images"
        if [[ "$SKIP_PUSH" == false ]]; then
            missing_deps+=("skopeo")
        fi
    else
        print_success "Found: skopeo"
    fi
    
    if ! command_exists jq; then
        print_warning "jq not found - optional but recommended for debugging"
    else
        print_success "Found: jq"
    fi
    
    # Check if we're in a git repository
    if [[ ! -d "${KUBEVIRT_DIR}/.git" ]]; then
        print_error "Not in a git repository. Please run from KubeVirt source directory"
        exit 1
    fi
    print_success "Git repository detected"
    
    # Check if on correct branch
    local current_branch=$(git -C "${KUBEVIRT_DIR}" branch --show-current)
    if [[ "$current_branch" != "ppc64le-2025" ]]; then
        print_warning "Not on ppc64le-2025 branch. Current branch: $current_branch"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "On ppc64le-2025 branch"
    fi
    
    # If there are missing dependencies, exit
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        print_info "Install missing dependencies:"
        echo "  Fedora/RHEL/CentOS: sudo dnf install ${missing_deps[*]}"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        exit 1
    fi
    
    print_success "All prerequisites satisfied"
}

# Function to setup environment
setup_environment() {
    print_header "Setting Up Build Environment"
    
    # Change to KubeVirt directory
    cd "${KUBEVIRT_DIR}"
    
    # Set builder image
    export KUBEVIRT_BUILDER_IMAGE="${DEFAULT_BUILDER_IMAGE}"
    print_info "Builder image: ${KUBEVIRT_BUILDER_IMAGE}"
    
    # Set target architecture
    export BUILD_ARCH="crossbuild-ppc64le"
    print_info "Target architecture: ${BUILD_ARCH}"
    
    # Set CentOS Stream version
    export KUBEVIRT_CENTOS_STREAM_VERSION="${KUBEVIRT_CENTOS_STREAM_VERSION:-${DEFAULT_CENTOS_VERSION}}"
    print_info "CentOS Stream version: ${KUBEVIRT_CENTOS_STREAM_VERSION}"
    
    # Set container registry
    if [[ -z "${DOCKER_PREFIX}" ]]; then
        export DOCKER_PREFIX="${REGISTRY:-${DEFAULT_REGISTRY}}"
    fi
    print_info "Container registry: ${DOCKER_PREFIX}"
    
    # Set image tag
    if [[ -z "${DOCKER_TAG}" ]]; then
        # Auto-generate tag from git
        local git_tag=$(git describe --always --tags 2>/dev/null || echo "unknown")
        export DOCKER_TAG="${TAG:-${git_tag}-ppc64le}"
    fi
    print_info "Image tag: ${DOCKER_TAG}"
    
    print_success "Environment configured"
}

# Function to build binaries
build_binaries() {
    print_header "Building PPC64LE Binaries"
    
    print_info "Starting cross-compilation for ppc64le..."
    print_info "This may take 15-30 minutes depending on your system"
    
    if BUILD_ARCH=crossbuild-ppc64le make bazel-build; then
        print_success "Binaries built successfully"
        
        # Verify binary architecture
        if [[ -f "_out/cmd/virtctl/virtctl" ]]; then
            local arch_info=$(file _out/cmd/virtctl/virtctl | grep -o "PowerPC\|ppc64")
            if [[ -n "$arch_info" ]]; then
                print_success "Verified: Binary is built for ppc64le architecture"
            else
                print_warning "Could not verify binary architecture"
            fi
        fi
    else
        print_error "Binary build failed"
        exit 1
    fi
}

# Function to build container images
build_images() {
    print_header "Building PPC64LE Container Images"
    
    print_info "Building container images for ppc64le..."
    print_info "This may take 20-40 minutes depending on your system"
    
    if DOCKER_TAG="${DOCKER_TAG}" BUILD_ARCH=crossbuild-ppc64le make bazel-build-images; then
        print_success "Container images built successfully"
        
        # List built images
        print_info "Built images:"
        ${KUBEVIRT_CRI} images | grep -E "virt-|${DOCKER_TAG}" || true
        
        # Verify image architecture
        local test_image="${DOCKER_PREFIX}/virt-operator:${DOCKER_TAG}"
        if ${KUBEVIRT_CRI} image exists "${test_image}" 2>/dev/null; then
            local img_arch=$(${KUBEVIRT_CRI} inspect "${test_image}" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
            if [[ "$img_arch" == "ppc64le" ]]; then
                print_success "Verified: Images are built for ppc64le architecture"
            else
                print_warning "Image architecture: $img_arch (expected: ppc64le)"
            fi
        fi
    else
        print_error "Image build failed"
        exit 1
    fi
}

# Function to push images
push_images() {
    print_header "Pushing Images to Registry"
    
    # Check if logged in to registry
    local registry_host=$(echo "${DOCKER_PREFIX}" | cut -d'/' -f1)
    print_info "Checking authentication for ${registry_host}..."
    
    if ! skopeo login --get-login "${registry_host}" >/dev/null 2>&1; then
        print_warning "Not logged in to ${registry_host}"
        print_info "Attempting to login..."
        if ! skopeo login "${registry_host}"; then
            print_error "Failed to login to ${registry_host}"
            print_info "Please run: skopeo login ${registry_host}"
            exit 1
        fi
    fi
    print_success "Authenticated to ${registry_host}"
    
    print_info "Pushing images to ${DOCKER_PREFIX}..."
    print_info "This may take several minutes depending on your network speed"
    
    if make bazel-push-images; then
        print_success "Images pushed successfully"
        
        # Verify pushed image
        local test_image="docker://${DOCKER_PREFIX}/virt-operator:${DOCKER_TAG}"
        print_info "Verifying pushed image..."
        if skopeo inspect "${test_image}" >/dev/null 2>&1; then
            local remote_arch=$(skopeo inspect "${test_image}" | jq -r '.Architecture' 2>/dev/null || echo "unknown")
            if [[ "$remote_arch" == "ppc64le" ]]; then
                print_success "Verified: Remote image is ppc64le"
            else
                print_warning "Remote image architecture: $remote_arch"
            fi
        fi
    else
        print_error "Image push failed"
        exit 1
    fi
}

# Function to display summary
display_summary() {
    print_header "Build Summary"
    
    echo "Registry: ${DOCKER_PREFIX}"
    echo "Tag: ${DOCKER_TAG}"
    echo "Architecture: ppc64le (cross-compiled from x86_64)"
    echo "CentOS Stream: ${KUBEVIRT_CENTOS_STREAM_VERSION}"
    echo ""
    
    if [[ "$SKIP_BUILD" == false ]]; then
        echo "✓ Binaries built"
    fi
    if [[ "$SKIP_IMAGES" == false ]]; then
        echo "✓ Container images built"
    fi
    if [[ "$SKIP_PUSH" == false ]]; then
        echo "✓ Images pushed to registry"
    fi
    
    echo ""
    print_success "Cross-compilation completed successfully!"
    echo ""
    print_info "Next steps:"
    echo "  1. Transfer to ppc64le machine or use remote deployment"
    echo "  2. Run deployment script: ./scripts/deploy-ppc64le.sh"
    echo "  3. Verify deployment: kubectl get pods -n kubevirt"
    echo ""
    print_info "Images available at:"
    echo "  ${DOCKER_PREFIX}/virt-operator:${DOCKER_TAG}"
    echo "  ${DOCKER_PREFIX}/virt-api:${DOCKER_TAG}"
    echo "  ${DOCKER_PREFIX}/virt-controller:${DOCKER_TAG}"
    echo "  ${DOCKER_PREFIX}/virt-handler:${DOCKER_TAG}"
    echo "  ${DOCKER_PREFIX}/virt-launcher:${DOCKER_TAG}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-images)
            SKIP_IMAGES=true
            shift
            ;;
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_header "KubeVirt PPC64LE Cross-Compilation Build"
    
    check_prerequisites
    setup_environment
    
    if [[ "$SKIP_BUILD" == false ]]; then
        build_binaries
    else
        print_info "Skipping binary build (--skip-build)"
    fi
    
    if [[ "$SKIP_IMAGES" == false ]]; then
        build_images
    else
        print_info "Skipping image build (--skip-images)"
    fi
    
    if [[ "$SKIP_PUSH" == false ]]; then
        push_images
    else
        print_info "Skipping image push (--skip-push)"
    fi
    
    display_summary
}

# Run main function
main
