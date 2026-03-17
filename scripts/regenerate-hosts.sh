#!/bin/bash
set -euo pipefail

################################################
# DoH Smart DNS — Regenerate xbox-hosts ConfigMap
# Re-generates and applies the xbox-hosts ConfigMap
# with the current VPS_IP
################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load VPS_IP
VPS_IP="${1:-${VPS_IP:-}}"

if [ -z "$VPS_IP" ] && [ -f "$PROJECT_ROOT/.env" ]; then
    VPS_IP=$(grep '^VPS_IP=' "$PROJECT_ROOT/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' "'"'"'')
fi

if [ -z "$VPS_IP" ]; then
    echo -e "${RED}❌ VPS_IP not set${NC}"
    echo "Usage: $0 [VPS_IP]"
    echo "   or: VPS_IP=1.2.3.4 $0"
    exit 1
fi

echo -e "${BLUE}Regenerating xbox-hosts ConfigMap with VPS_IP=$VPS_IP${NC}"

# Generate
"$SCRIPT_DIR/deploy.sh" generate

# Apply just the ConfigMap
echo -e "${BLUE}Applying ConfigMap...${NC}"
kubectl apply -f "$PROJECT_ROOT/base/configmap-xbox-hosts.yaml"

# Restart CoreDNS to pick up new hosts
echo -e "${BLUE}Restarting CoreDNS pods...${NC}"
kubectl rollout restart deployment/coredns-smartdns -n doh-system
kubectl rollout status deployment/coredns-smartdns -n doh-system --timeout=60s

echo -e "${GREEN}✅ xbox-hosts updated and CoreDNS restarted${NC}"
echo ""
echo "Test: kubectl exec -n doh-system deploy/coredns-smartdns -- nslookup xboxlive.com localhost"
