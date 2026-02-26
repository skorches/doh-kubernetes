#!/bin/bash
set -euo pipefail

################################################
# DoH Smart DNS — One-Command Kubernetes Installer
#
# Usage:
#   bash scripts/deploy.sh                  # interactive
#   bash scripts/deploy.sh 1.2.3.4          # with VPS IP
#   bash scripts/deploy.sh 1.2.3.4 production
#   bash scripts/deploy.sh status
#   bash scripts/deploy.sh destroy
#
# Everything is handled: kubectl check, namespace,
# hosts ConfigMap, self-signed TLS certs, deploy, verify.
################################################

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Helpers ---
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

# ======================================================
# 1. Resolve VPS_IP — env var > .env file > arg > prompt
# ======================================================
resolve_vps_ip() {
    # Already set via environment
    if [ -n "${VPS_IP:-}" ]; then
        return 0
    fi

    # Try .env file
    if [ -f "$PROJECT_ROOT/.env" ]; then
        VPS_IP=$(grep '^VPS_IP=' "$PROJECT_ROOT/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' "'"'"'' || true)
    fi

    # Still empty — interactive prompt
    if [ -z "${VPS_IP:-}" ]; then
        echo ""
        echo -e "${BOLD}Enter your VPS / server public IP address:${NC}"
        read -rp "> " VPS_IP
        echo ""
    fi

    # Validate
    if [ -z "${VPS_IP:-}" ]; then
        print_error "VPS_IP is required. Aborting."
        exit 1
    fi

    # Basic IP format check (v4 or v6)
    if ! echo "$VPS_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-fA-F:]+$'; then
        print_error "Invalid IP address: $VPS_IP"
        exit 1
    fi

    # Persist to .env for next time
    if [ ! -f "$PROJECT_ROOT/.env" ]; then
        echo "VPS_IP=$VPS_IP" > "$PROJECT_ROOT/.env"
        print_info "Saved VPS_IP to .env"
    elif ! grep -q "^VPS_IP=" "$PROJECT_ROOT/.env"; then
        echo "VPS_IP=$VPS_IP" >> "$PROJECT_ROOT/.env"
        print_info "Saved VPS_IP to .env"
    fi
}

# ======================================================
# 2. Pre-flight — install kubectl if needed, check cluster
# ======================================================
preflight() {
    print_header "Pre-flight Checks"

    # --- kubectl ---
    if ! command -v kubectl &>/dev/null; then
        print_warn "kubectl not found — installing..."
        install_kubectl
    fi
    print_success "kubectl $(kubectl version --client -o json 2>/dev/null | grep -oP '"gitVersion"\s*:\s*"\K[^"]+' || echo 'found')"

    # --- cluster connectivity ---
    if ! kubectl cluster-info &>/dev/null; then
        print_error "Cannot connect to Kubernetes cluster."
        echo "  Make sure your kubeconfig is configured:"
        echo "    export KUBECONFIG=/path/to/kubeconfig"
        exit 1
    fi
    print_success "Connected to cluster: $(kubectl config current-context 2>/dev/null || echo 'default')"

    # --- kustomize ---
    if command -v kustomize &>/dev/null; then
        KUSTOMIZE_CMD="kustomize build"
        print_success "kustomize found (standalone)"
    else
        KUSTOMIZE_CMD="kubectl kustomize"
        print_info "Using built-in kubectl kustomize"
    fi

    # --- openssl (needed for self-signed certs) ---
    if ! command -v openssl &>/dev/null; then
        print_warn "openssl not found — self-signed TLS generation will be skipped"
    fi
}

install_kubectl() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="arm"   ;;
    esac

    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')

    local version
    version=$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo "v1.31.0")

    local url="https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl"
    print_info "Downloading kubectl ${version} (${os}/${arch})..."

    if [ -w /usr/local/bin ]; then
        curl -fsSL "$url" -o /usr/local/bin/kubectl
        chmod +x /usr/local/bin/kubectl
    elif command -v sudo &>/dev/null; then
        curl -fsSL "$url" -o /tmp/kubectl
        sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
        rm -f /tmp/kubectl
    else
        print_error "Cannot install kubectl — no write access to /usr/local/bin and sudo not available."
        echo "  Install manually: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi

    print_success "kubectl installed to /usr/local/bin/kubectl"
}

# ======================================================
# 3. Generate xbox-hosts ConfigMap from template
# ======================================================
generate_hosts_configmap() {
    print_header "Generating xbox-hosts ConfigMap"

    local template="$PROJECT_ROOT/coredns/xbox-hosts.template"
    local output="$PROJECT_ROOT/base/configmap-xbox-hosts.yaml"

    if [ ! -f "$template" ]; then
        print_error "Template not found: $template"
        exit 1
    fi

    local date_str
    date_str=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # Generate hosts content
    local hosts_content
    hosts_content=$(sed \
        -e "s/__VPS_IP__/$VPS_IP/g" \
        -e "s/__DATE__/$date_str/g" \
        "$template")

    # Write ConfigMap YAML
    cat > "$output" <<EOF
# AUTO-GENERATED — Do not edit manually.
# Generated by: scripts/deploy.sh
# VPS IP: $VPS_IP
# Date: $date_str
apiVersion: v1
kind: ConfigMap
metadata:
  name: xbox-hosts
  namespace: doh-system
  labels:
    app.kubernetes.io/name: coredns-smartdns
    app.kubernetes.io/component: dns-hosts
    app.kubernetes.io/part-of: doh-smart-dns
data:
  xbox-hosts: |
$(echo "$hosts_content" | sed 's/^/    /')
EOF

    print_success "Generated xbox-hosts ConfigMap (VPS_IP=$VPS_IP)"

    # Ensure kustomization.yaml includes the generated file
    if ! grep -q "configmap-xbox-hosts.yaml" "$PROJECT_ROOT/base/kustomization.yaml"; then
        sed -i 's|  - pdb.yaml|  - configmap-xbox-hosts.yaml\n  - pdb.yaml|' \
            "$PROJECT_ROOT/base/kustomization.yaml"
        print_info "Added configmap-xbox-hosts.yaml to base/kustomization.yaml"
    fi
}

# ======================================================
# 4. TLS certificates — find existing or generate self-signed
# ======================================================
setup_tls() {
    print_header "TLS Certificate Setup"

    local cert_path=""
    local key_path=""

    # Search common locations for real certs
    for cert_dir in \
        /etc/letsencrypt/live \
        "${PROJECT_ROOT}/ssl" \
        "${PROJECT_ROOT}/certs" \
        "${PROJECT_ROOT}/tls"; do
        if [ -d "$cert_dir" ]; then
            local found_cert found_key
            found_cert=$(find "$cert_dir" -name "fullchain.pem" -o -name "tls.crt" -o -name "cert.pem" 2>/dev/null | head -1)
            found_key=$(find "$cert_dir" -name "privkey.pem" -o -name "tls.key" -o -name "key.pem" 2>/dev/null | head -1)
            if [ -n "$found_cert" ] && [ -n "$found_key" ]; then
                cert_path="$found_cert"
                key_path="$found_key"
                break
            fi
        fi
    done

    if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
        print_info "Found existing cert: $cert_path"
        print_info "Found existing key:  $key_path"
    else
        # Generate self-signed certificate
        print_info "No TLS certificates found — generating self-signed cert..."
        generate_self_signed_cert
        cert_path="$PROJECT_ROOT/ssl/tls.crt"
        key_path="$PROJECT_ROOT/ssl/tls.key"
    fi

    # Ensure namespace exists before creating secret
    kubectl apply -f "$PROJECT_ROOT/base/namespace.yaml" 2>/dev/null || true

    # Create / update the TLS secret
    kubectl create secret tls doh-tls-certs \
        --namespace=doh-system \
        --cert="$cert_path" \
        --key="$key_path" \
        --dry-run=client -o yaml | kubectl apply -f -

    print_success "TLS secret doh-tls-certs created/updated in doh-system"
}

generate_self_signed_cert() {
    if ! command -v openssl &>/dev/null; then
        print_error "openssl is required to generate self-signed certs."
        echo "  Install it:  sudo apt install openssl   (or equivalent)"
        echo "  Or provide your own certs in:  ${PROJECT_ROOT}/ssl/"
        exit 1
    fi

    mkdir -p "$PROJECT_ROOT/ssl"

    # Build SAN list: IP + domain (if set)
    local san="IP:${VPS_IP}"
    local cn="$VPS_IP"

    local domain="${DOMAIN:-}"
    if [ -z "$domain" ] && [ -f "$PROJECT_ROOT/.env" ]; then
        domain=$(grep '^DOMAIN=' "$PROJECT_ROOT/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' "'"'"'' || true)
    fi
    if [ -n "$domain" ]; then
        san="${san},DNS:${domain}"
        cn="$domain"
    fi

    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$PROJECT_ROOT/ssl/tls.key" \
        -out "$PROJECT_ROOT/ssl/tls.crt" \
        -subj "/CN=${cn}/O=DoH Smart DNS" \
        -addext "subjectAltName=${san}" \
        2>/dev/null

    print_success "Self-signed cert generated in ssl/ (valid 10 years)"
    print_warn "For production, replace with real certs (Let's Encrypt, etc.)"
}

# ======================================================
# 5. Deploy manifests via kustomize
# ======================================================
deploy() {
    local overlay="${1:-base}"
    local manifest_dir="$PROJECT_ROOT/$overlay"

    if [ "$overlay" != "base" ]; then
        manifest_dir="$PROJECT_ROOT/overlays/$overlay"
    fi

    print_header "Deploying DoH Smart DNS ($overlay)"

    if [ ! -f "$manifest_dir/kustomization.yaml" ]; then
        print_error "Kustomization not found: $manifest_dir/kustomization.yaml"
        exit 1
    fi

    print_step "Applying manifests from $manifest_dir..."

    # Compute config checksum so CoreDNS pods restart on ConfigMap changes
    local config_checksum
    config_checksum=$(cat \
        "$PROJECT_ROOT/base/configmap-coredns.yaml" \
        "$PROJECT_ROOT/base/configmap-xbox-hosts.yaml" \
        2>/dev/null | sha256sum | cut -d' ' -f1)

    # Render manifests, inject real checksum, then apply
    $KUSTOMIZE_CMD "$manifest_dir" | \
        sed "s/PLACEHOLDER/$config_checksum/g" | \
        kubectl apply -f -
    print_success "All manifests applied (config checksum: ${config_checksum:0:12}...)"

    # Wait for rollouts
    print_header "Waiting for Rollout"

    local deployments=("coredns-smartdns" "doh-backend" "doh-nginx")
    for dep in "${deployments[@]}"; do
        printf "  %-16s " "$dep:"
        if kubectl rollout status "deployment/$dep" -n doh-system --timeout=120s 2>/dev/null; then
            print_success "Ready"
        else
            print_warn "Timeout — check: kubectl describe deployment/$dep -n doh-system"
        fi
    done
}

# ======================================================
# 6. Post-deploy verification
# ======================================================
verify() {
    print_header "Verification"

    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)
    if [ -z "$node_ip" ]; then
        node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
    fi
    node_ip="${node_ip:-$VPS_IP}"

    echo ""
    echo "Pods:"
    kubectl get pods -n doh-system -o wide 2>/dev/null || true
    echo ""
    echo "Services:"
    kubectl get svc -n doh-system 2>/dev/null || true

    # Quick DNS test with retry (non-fatal)
    echo ""
    if command -v dig &>/dev/null; then
        print_step "Testing DNS resolution (port 30053)..."
        local dns_ok=false
        for i in 1 2 3; do
            if dig "@${node_ip}" -p 30053 xboxlive.com +short +time=3 +tries=1 2>/dev/null | grep -q "$VPS_IP"; then
                dns_ok=true
                break
            fi
            [ "$i" -lt 3 ] && sleep 3
        done
        if $dns_ok; then
            print_success "DNS test passed — xboxlive.com → $VPS_IP"
        else
            print_warn "DNS test inconclusive (may need a moment to start)"
        fi
    fi

    # Quick HTTPS health check with retry (non-fatal)
    if command -v curl &>/dev/null; then
        print_step "Testing DoH health endpoint (port 30443)..."
        local doh_ok=false
        for i in 1 2 3; do
            if curl -fsSk --connect-timeout 3 "https://${node_ip}:30443/health" &>/dev/null; then
                doh_ok=true
                break
            fi
            [ "$i" -lt 3 ] && sleep 3
        done
        if $doh_ok; then
            print_success "DoH health check passed"
        else
            print_warn "DoH health check failed — showing recent pod logs:"
            echo ""
            for dep in coredns-smartdns doh-backend doh-nginx; do
                echo "--- $dep (last 5 lines) ---"
                kubectl logs -n doh-system -l "app.kubernetes.io/name=$dep" --tail=5 2>/dev/null || echo "  (no logs)"
            done
            echo ""
        fi
    fi

    print_header "Done! Your DoH Smart DNS is running"
    echo ""
    echo -e "  ${BOLD}DNS (plain):${NC}   ${node_ip}:30053"
    echo -e "  ${BOLD}DoH (HTTPS):${NC}   https://${node_ip}:30443/dns-query"
    echo ""
    echo "  Xbox DNS setting:  ${node_ip}"
    echo "  Xbox DoH URL:      https://${node_ip}:30443/dns-query"
    echo ""
    echo -e "  ${CYAN}Test DNS:${NC}   dig @${node_ip} -p 30053 xboxlive.com"
    echo -e "  ${CYAN}Test DoH:${NC}   curl -ks https://${node_ip}:30443/health"
    echo -e "  ${CYAN}Status:${NC}     bash scripts/deploy.sh status"
    echo -e "  ${CYAN}Destroy:${NC}    bash scripts/deploy.sh destroy"
    echo ""
}

# ======================================================
# 7. Status / Destroy helpers
# ======================================================
show_status() {
    print_header "Deployment Status"
    echo ""
    echo "Pods:"
    kubectl get pods -n doh-system -o wide 2>/dev/null || echo "  (namespace not found)"
    echo ""
    echo "Services:"
    kubectl get svc -n doh-system 2>/dev/null || echo "  (namespace not found)"
    echo ""
    echo "Deployments:"
    kubectl get deployments -n doh-system 2>/dev/null || echo "  (namespace not found)"
    echo ""

    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)
    if [ -z "$node_ip" ]; then
        node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
    fi

    if [ -n "$node_ip" ]; then
        echo "  DNS:  dig @${node_ip} -p 30053 xboxlive.com"
        echo "  DoH:  curl -ks https://${node_ip}:30443/health"
    fi
    echo ""
}

do_destroy() {
    print_header "Destroying DoH Smart DNS"
    kubectl delete namespace doh-system --ignore-not-found
    print_success "Namespace doh-system deleted"

    # Clean generated files
    rm -f "$PROJECT_ROOT/base/configmap-xbox-hosts.yaml"
    print_info "Cleaned generated files"
}

show_logs() {
    local component="${1:-all}"
    print_header "Logs ($component)"

    if [ "$component" = "all" ]; then
        for dep in coredns-smartdns doh-backend doh-nginx; do
            echo ""
            echo "=== $dep ==="
            kubectl logs -n doh-system -l "app.kubernetes.io/name=$dep" --tail=30 --prefix 2>/dev/null || echo "  (no logs)"
        done
    else
        kubectl logs -n doh-system -l "app.kubernetes.io/name=$component" --tail=100 --prefix 2>/dev/null || \
            print_error "No logs found for: $component"
    fi
}

do_restart() {
    print_header "Restarting DoH Smart DNS"
    for dep in coredns-smartdns doh-backend doh-nginx; do
        kubectl rollout restart "deployment/$dep" -n doh-system 2>/dev/null && \
            print_success "Restarted $dep" || print_warn "Failed to restart $dep"
    done
    echo ""
    print_info "Waiting for rollouts..."
    for dep in coredns-smartdns doh-backend doh-nginx; do
        kubectl rollout status "deployment/$dep" -n doh-system --timeout=60s 2>/dev/null || true
    done
    print_success "All deployments restarted"
}

# ======================================================
# Main — smart argument parsing
# ======================================================
main() {
    echo -e "${BOLD}"
    echo "  ____        _   _   ____                       _     ____  _   _ ____  "
    echo " |  _ \\  ___ | | | | / ___| _ __ ___   __ _ _ __| |_  |  _ \\| \\ | / ___| "
    echo " | | | |/ _ \\| |_| | \\___ \\| '_ \` _ \\ / _\` | '__| __| | | | |  \\| \\___ \\ "
    echo " | |_| | (_) |  _  |  ___) | | | | | | (_| | |  | |_  | |_| | |\\  |___) |"
    echo " |____/ \\___/|_| |_| |____/|_| |_| |_|\\__,_|_|   \\__| |____/|_| \\_|____/ "
    echo -e "${NC}"
    echo -e " ${CYAN}Kubernetes One-Command Installer${NC}"
    echo ""

    local arg1="${1:-}"
    local arg2="${2:-}"

    # --- Handle named commands ---
    case "$arg1" in
        status)
            show_status
            return
            ;;
        destroy|delete|remove)
            do_destroy
            return
            ;;
        logs)
            show_logs "${arg2:-all}"
            return
            ;;
        restart)
            do_restart
            return
            ;;
        help|-h|--help)
            echo "Usage: $0 [VPS_IP] [base|production]"
            echo "       $0 status"
            echo "       $0 logs [component]"
            echo "       $0 restart"
            echo "       $0 destroy"
            echo ""
            echo "If VPS_IP is not provided, it will be read from .env or prompted interactively."
            echo ""
            echo "Examples:"
            echo "  bash $0                              # interactive install"
            echo "  bash $0 1.2.3.4                      # install with IP"
            echo "  bash $0 1.2.3.4 production            # production overlay"
            echo "  VPS_IP=1.2.3.4 bash $0               # env var"
            echo "  bash $0 status                       # show status"
            echo "  bash $0 logs                         # all logs"
            echo "  bash $0 logs coredns-smartdns        # single component"
            echo "  bash $0 restart                      # restart all pods"
            echo "  bash $0 destroy                      # tear down"
            return
            ;;
    esac

    # --- Deploy flow ---
    # If first arg looks like an IP, use it as VPS_IP
    if echo "$arg1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-fA-F:]+$'; then
        VPS_IP="$arg1"
        local overlay="${arg2:-base}"
    # If first arg is "deploy" (legacy compat), shift
    elif [ "$arg1" = "deploy" ]; then
        local overlay="${arg2:-base}"
    else
        local overlay="${arg1:-base}"
    fi

    # Validate overlay
    if [ "$overlay" != "base" ] && [ "$overlay" != "production" ]; then
        overlay="base"
    fi

    resolve_vps_ip
    preflight
    generate_hosts_configmap
    setup_tls
    deploy "$overlay"
    verify
}

main "$@"
