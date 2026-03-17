#!/bin/bash
set -euo pipefail

##############################################################################
# DoH Kubernetes — Single VPS Full Setup
# Auto-detects VPS IP, installs k3s + dependencies, deploys everything
#
# Usage:
#   bash scripts/install.sh                    # Auto-detect IP
#   bash scripts/install.sh 192.168.1.100      # Explicit IP
#   bash scripts/install.sh --help             # Show help
##############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============================================================================
# Helpers
# ============================================================================
print_header() {
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_step()    { echo -e "${CYAN}▶  $1${NC}"; }

# ============================================================================
# 1. Extract VPS IP
# ============================================================================
detect_vps_ip() {
    # Priority: explicit arg > env var > auto-detect > interactive
    
    # Explicit argument
    if [ -n "${1:-}" ] && [ "${1:-}" != "--help" ]; then
        VPS_IP="$1"
        if ! echo "$VPS_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-fA-F:]+$'; then
            print_error "Invalid IP address: $VPS_IP"
            exit 1
        fi
        print_success "Using provided IP: $VPS_IP"
        return 0
    fi
    
    # Environment variable
    if [ -n "${VPS_IP:-}" ]; then
        print_success "Using VPS_IP from environment: $VPS_IP"
        return 0
    fi
    
    # Auto-detect external IP
    print_step "Auto-detecting VPS IP..."
    
    # Try multiple methods to get external IP
    local external_ip=""
    
    # Method 1: Check for public IP services
    external_ip=$(curl -fsSL https://checkip.amazonaws.com 2>/dev/null || true)
    
    # Method 2: Fallback to local network
    if [ -z "$external_ip" ]; then
        external_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    
    # Method 3: Interactive prompt
    if [ -z "$external_ip" ]; then
        print_warn "Could not auto-detect IP"
        echo ""
        read -rp "Enter your VPS public IP address: " external_ip
    fi
    
    if [ -z "$external_ip" ]; then
        print_error "VPS_IP is required"
        exit 1
    fi
    
    VPS_IP="$external_ip"
    print_success "Detected VPS IP: $VPS_IP"
}

# ============================================================================
# 2. Check & Install Dependencies
# ============================================================================
check_and_install_dependencies() {
    print_header "Checking Dependencies"
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        print_error "Cannot detect OS"
        exit 1
    fi
    
    print_info "Detected OS: $OS"
    
    # Update package manager
    print_step "Updating package manager..."
    case "$OS" in
        ubuntu|debian)
            sudo apt-get update -qq &>/dev/null || true
            ;;
        rhel|centos|fedora)
            sudo yum update -y &>/dev/null || true
            ;;
    esac
    
    # Check and install curl
    if ! command -v curl &>/dev/null; then
        print_step "Installing curl..."
        case "$OS" in
            ubuntu|debian) sudo apt-get install -y curl &>/dev/null ;;
            rhel|centos|fedora) sudo yum install -y curl &>/dev/null ;;
        esac
    fi
    print_success "curl is available"
    
    # Check and install openssl
    if ! command -v openssl &>/dev/null; then
        print_step "Installing openssl..."
        case "$OS" in
            ubuntu|debian) sudo apt-get install -y openssl &>/dev/null ;;
            rhel|centos|fedora) sudo yum install -y openssl &>/dev/null ;;
        esac
    fi
    print_success "openssl is available"
    
    # Check and install dig (for DNS testing)
    if ! command -v dig &>/dev/null; then
        print_step "Installing dig..."
        case "$OS" in
            ubuntu|debian) sudo apt-get install -y dnsutils &>/dev/null ;;
            rhel|centos|fedora) sudo yum install -y bind-utils &>/dev/null ;;
        esac
    fi
    print_success "dig is available"
}

# ============================================================================
# 3. Install k3s (Lightweight Kubernetes)
# ============================================================================
install_k3s() {
    print_header "Installing Kubernetes (k3s)"
    
    if command -v k3s &>/dev/null; then
        print_success "k3s is already installed: $(k3s --version)"
        return 0
    fi
    
    print_step "Installing k3s..."
    curl -sfL https://get.k3s.io | sh - 2>&1 | tail -5
    
    # Wait for k3s to be ready
    print_step "Waiting for k3s to start..."
    for i in {1..30}; do
        if sudo k3s kubectl get nodes &>/dev/null; then
            print_success "k3s is ready"
            break
        fi
        [ $i -eq 30 ] && {
            print_error "k3s failed to start"
            exit 1
        }
        sleep 1
    done
}

# ============================================================================
# 4. Setup kubectl
# ============================================================================
setup_kubectl() {
    print_header "Setting up kubectl"
    
    # Create .kube directory
    mkdir -p ~/.kube
    
    # Copy k3s kubeconfig
    print_step "Configuring kubectl..."
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    chmod 600 ~/.kube/config
    
    # Verify kubectl works
    if kubectl cluster-info &>/dev/null; then
        print_success "kubectl is configured and working"
    else
        print_error "kubectl configuration failed"
        exit 1
    fi
}

# ============================================================================
# 5. Create .env with VPS_IP and optional DOMAIN
# ============================================================================
setup_env_file() {
    print_header "Creating Configuration File (.env)"
    
    # Ask for REQUIRED domain
    local domain=""
    echo ""
    echo -e "${BOLD}Domain Configuration (REQUIRED)${NC}"
    echo "Enter a domain name for DoH endpoint (HTTPS)"
    echo "Examples: doh.example.com, 440.info, dns.mysite.com"
    echo ""
    
    # Keep asking until valid domain is entered
    while [ -z "$domain" ]; do
        read -rp "Domain name: " domain
        
        if [ -z "$domain" ]; then
            print_error "Domain is required!"
            echo ""
        elif ! echo "$domain" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'; then
            print_error "Invalid domain format: $domain"
            echo "  Valid examples: doh.example.com, 440.info, dns.local"
            echo ""
            domain=""
        fi
    done
    
    # Create .env using .env.example as template
    if [ -f "$PROJECT_ROOT/.env.example" ]; then
        cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    fi
    
    # Write configuration
    cat > "$PROJECT_ROOT/.env" << EOF
# DoH Kubernetes Configuration
# Generated: $(date)
# Note: You can edit this file and run 'bash scripts/deploy.sh' to update config

VPS_IP=$VPS_IP
DOMAIN=$domain
NAMESPACE=doh-system
OVERLAY=base
EOF
    
    print_success "Created .env with VPS_IP=$VPS_IP and DOMAIN=$domain"
    print_info "Tip: Change DOMAIN anytime by editing .env and running: bash scripts/deploy.sh"

# ============================================================================
# 6. Run deploy.sh
# ============================================================================
run_deployment() {
    print_header "Deploying DoH Smart DNS"
    
    cd "$PROJECT_ROOT"
    bash scripts/deploy.sh
}

# ============================================================================
# 7. Post-deployment info
# ============================================================================
show_completion_info() {
    print_header "Installation Complete!"
    
    # Read domain from .env if set
    local access_point="$VPS_IP"
    if [ -f "$PROJECT_ROOT/.env" ]; then
        local domain=$(grep '^DOMAIN=' "$PROJECT_ROOT/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' "'"'"'' || true)
        if [ -n "$domain" ]; then
            access_point="$domain"
        fi
    fi
    
    echo ""
    echo -e "${BOLD}Your DoH Smart DNS is now running on $access_point${NC}"
    echo ""
    echo -e "${CYAN}Access Points:${NC}"
    echo "  DNS (plain):   $access_point:30053"
    echo "  DoH (HTTPS):   https://$access_point:30443/dns-query"
    echo ""
    echo -e "${CYAN}Test Commands:${NC}"
    echo "  DNS test:  dig @$access_point -p 30053 xboxlive.com"
    echo "  DoH test:  curl -ks https://$access_point:30443/health"
    echo ""
    echo -e "${CYAN}Manage Deployment:${NC}"
    echo "  Status:    bash scripts/deploy.sh status"
    echo "  View logs: bash scripts/deploy.sh logs"
    echo "  Restart:   bash scripts/deploy.sh restart"
    echo "  Destroy:   bash scripts/deploy.sh destroy"
    echo ""
}

# ============================================================================
# Help
# ============================================================================
show_help() {
    cat << EOF
DoH Kubernetes — Single VPS Full Setup

USAGE:
  bash scripts/install.sh [OPTIONS]

OPTIONS:
  <IP>                Auto-detect or use specified VPS IP
  --help              Show this help message

EXAMPLES:
  # Auto-detect VPS IP and install everything
  bash scripts/install.sh

  # Use specific IP
  bash scripts/install.sh 192.168.1.100

  # Set environment variable
  VPS_IP=1.2.3.4 bash scripts/install.sh

EOF
}

# ============================================================================
# Main
# ============================================================================
main() {
    if [ "${1:-}" = "--help" ]; then
        show_help
        exit 0
    fi
    
    echo -e "${BOLD}"
    echo "  ____        _   _   ____                       _     ____  _   _ ____  "
    echo " |  _ \\  ___ | | | | / ___| _ __ ___   __ _ _ __| |_  |  _ \\| \\ | / ___| "
    echo " | | | |/ _ \\| |_| | \\___ \\| '_ \` _ \\ / _\` | '__| __| | | | |  \\| \\___ \\ "
    echo " | |_| | (_) |  _  |  ___) | | | | | | (_| | |  | |_  | |_| | |\\  |___) |"
    echo " |____/ \\___/|_| |_| |____/|_| |_| |_|\\__,_|_|   \\__| |____/|_| \\_|____/ "
    echo -e "${NC}"
    echo ""
    echo -e "${CYAN}Single VPS Setup — Fully Automated${NC}"
    echo ""
    
    # Run setup sequence
    detect_vps_ip "$@"
    check_and_install_dependencies
    install_k3s
    setup_kubectl
    setup_env_file
    run_deployment
    show_completion_info
}

main "$@"
