#!/bin/bash
set -euo pipefail

##############################################################################
# Multi-VPS Kubernetes Setup Helper
# Automates k3s installation and configuration across multiple VPS servers
#
# Usage:
#   bash scripts/setup-multi-vps.sh
#   Add VPS IPs interactively, installs k3s, merges kubeconfigs
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
KUBECONFIG_DIR="$PROJECT_ROOT/.kube"

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
# 1. Collect VPS Information
# ============================================================================
collect_vps_info() {
    print_header "Multi-VPS Kubernetes Setup"
    echo ""
    echo "This script will:"
    echo "  1. Install k3s on each VPS (one-command cluster)"
    echo "  2. Download kubeconfigs locally"
    echo "  3. Merge them for easy switching between clusters"
    echo ""
    
    local -a vpses=()
    local -a ssh_users=()
    
    echo -e "${BOLD}Add your VPS servers (Ctrl+C when done):${NC}"
    echo ""
    
    local index=1
    while true; do
        echo -e "${BOLD}VPS #${index}:${NC}"
        read -rp "  IP/hostname (or press Enter to finish): " ip_input
        
        if [ -z "$ip_input" ]; then
            break
        fi
        
        read -rp "  SSH user (default: root): " ssh_user
        ssh_user="${ssh_user:-root}"
        
        vpses+=("$ip_input")
        ssh_users+=("$ssh_user")
        
        print_success "Added: $ssh_user@$ip_input"
        ((index++))
        echo ""
    done
    
    if [ ${#vpses[@]} -eq 0 ]; then
        print_error "No VPS entries added"
        exit 1
    fi
    
    echo ""
    print_header "VPS Summary"
    for i in "${!vpses[@]}"; do
        echo "  $((i+1)). ${ssh_users[$i]}@${vpses[$i]}"
    done
    echo ""
    
    read -rp "Proceed with installation? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warn "Cancelled"
        exit 0
    fi
    
    setup_k3s_on_vpses "${vpses[@]}" "${ssh_users[@]}"
}

# ============================================================================
# 2. Install k3s on each VPS
# ============================================================================
setup_k3s_on_vpses() {
    local vpses=("${@:1:$((${#@}/2))}")
    local ssh_users=("${@:$((${#@}/2+1))}")
    
    mkdir -p "$KUBECONFIG_DIR"
    
    for i in "${!vpses[@]}"; do
        local vps="${vpses[$i]}"
        local user="${ssh_users[$i]}"
        local cluster_name="doh-$(echo "$vps" | tr '.' '-')"
        
        print_header "Installing k3s on $user@$vps"
        
        # Install k3s on remote VPS
        print_step "Installing k3s (this may take a minute)..."
        ssh -o StrictHostKeyChecking=no "$user@$vps" << 'EOF' || true
            if command -v k3s &>/dev/null; then
                echo "✓ k3s already installed"
            else
                curl -sfL https://get.k3s.io | sh -
                mkdir -p ~/.kube
                sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
                sudo chown $(id -u):$(id -g) ~/.kube/config
            fi
EOF
        
        # Download kubeconfig
        print_step "Downloading kubeconfig..."
        local kubeconfig_file="$KUBECONFIG_DIR/${cluster_name}.yaml"
        
        scp -o StrictHostKeyChecking=no "$user@$vps:~/.kube/config" "$kubeconfig_file" 2>/dev/null || {
            print_warn "Failed to get kubeconfig from $vps, trying with sudo..."
            ssh -o StrictHostKeyChecking=no "$user@$vps" "sudo cat /etc/rancher/k3s/k3s.yaml" > "$kubeconfig_file"
        }
        
        # Update kubeconfig with cluster name and server IP
        print_step "Configuring kubeconfig for remote access..."
        python3 << PYSCRIPT
import yaml
import sys

with open("$kubeconfig_file") as f:
    config = yaml.safe_load(f)

if config and 'clusters' in config:
    for cluster in config['clusters']:
        # Replace localhost with VPS IP
        if 'cluster' in cluster and 'server' in cluster['cluster']:
            server = cluster['cluster']['server']
            server = server.replace('https://127.0.0.1:6443', 'https://$vps:6443')
            server = server.replace('https://localhost:6443', 'https://$vps:6443')
            cluster['cluster']['server'] = server

if config and 'contexts' in config:
    for ctx in config['contexts']:
        if 'context' in ctx:
            ctx['context']['cluster'] = '$cluster_name'
            if 'user' in ctx['context']:
                ctx['context']['user'] = '$cluster_name-admin'

if config and 'clusters' in config:
    config['clusters'][0]['name'] = '$cluster_name'

if config and 'users' in config:
    config['users'][0]['name'] = '$cluster_name-admin'

if config and 'contexts' in config:
    config['contexts'][0]['name'] = '$cluster_name'
    config['current-context'] = '$cluster_name'

with open("$kubeconfig_file", 'w') as f:
    yaml.dump(config, f)
PYSCRIPT
        
        print_success "kubeconfig ready: $kubeconfig_file"
        echo ""
    done
    
    # Merge all kubeconfigs
    merge_kubeconfigs
}

# ============================================================================
# 3. Merge kubeconfigs for easy switching
# ============================================================================
merge_kubeconfigs() {
    print_header "Merging kubeconfigs"
    
    local merged_kubeconfig="$KUBECONFIG_DIR/config"
    
    # Create merged kubeconfig
    python3 << 'PYSCRIPT'
import yaml
import os
import glob

kubeconfig_dir = os.path.expanduser("$KUBECONFIG_DIR")
config_files = sorted(glob.glob(f"{kubeconfig_dir}/*.yaml"))

merged = {
    'apiVersion': 'v1',
    'kind': 'Config',
    'clusters': [],
    'contexts': [],
    'users': [],
    'current-context': None
}

for config_file in config_files:
    try:
        with open(config_file) as f:
            config = yaml.safe_load(f)
            if config:
                merged['clusters'].extend(config.get('clusters', []))
                merged['contexts'].extend(config.get('contexts', []))
                merged['users'].extend(config.get('users', []))
                if not merged['current-context']:
                    merged['current-context'] = config.get('current-context')
    except Exception as e:
        print(f"Warning: Could not read {config_file}: {e}")

# Write merged config
merged_file = f"{kubeconfig_dir}/config"
with open(merged_file, 'w') as f:
    yaml.dump(merged, f)

print(f"✓ Merged {len(config_files)} kubeconfigs")
print(f"✓ Written to {merged_file}")
PYSCRIPT
    
    print_success "Kubeconfigs merged to: $merged_kubeconfig"
    echo ""
    print_step "To use, set in your shell:"
    echo "  export KUBECONFIG=$merged_kubeconfig"
    echo ""
    print_step "Switch clusters with:"
    echo "  kubectl config use-context doh-<vps-ip>"
    echo "  kubectl config current-context"
}

# ============================================================================
# Main
# ============================================================================
main() {
    if ! command -v python3 &>/dev/null; then
        print_error "python3 is required"
        exit 1
    fi
    
    if ! command -v yaml &>/dev/null && ! python3 -c "import yaml" 2>/dev/null; then
        print_warn "Installing python3-yaml..."
        sudo apt-get install -y python3-pyyaml &>/dev/null || print_warn "Could not auto-install pyyaml"
    fi
    
    collect_vps_info
    
    print_header "Setup Complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Add this to your shell profile (.bashrc, .zshrc, etc.):"
    echo "     export KUBECONFIG=$KUBECONFIG_DIR/config"
    echo ""
    echo "  2. Deploy to each cluster:"
    echo "     kubectl config use-context doh-<vps-ip>"
    echo "     VPS_IP=<vps-ip> bash scripts/deploy.sh"
    echo ""
}

main
