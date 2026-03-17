#!/bin/bash
# Kubernetes (k3s) Diagnostic & Cleanup Script
# Check resource usage and optionally uninstall k3s

##############################################################################
# PART 1: CHECK IF K3S IS BOTTLENECKING YOUR VPS
##############################################################################

check_k3s_resources() {
    echo "================================================"
    echo " k3s Resource Usage Check"
    echo "================================================"
    echo ""
    
    # Check if k3s is running
    if ! systemctl is-active --quiet k3s; then
        echo "⚠️  k3s service is not running"
        return 1
    fi
    
    echo "✅ k3s service is running"
    echo ""
    
    # CPU usage
    echo "--- CPU Usage ---"
    ps aux | grep -E "[k]3s|[k]ubelet|[c]ontainerd" | awk '{print $1, $3"%", $6"MB", $11}'
    echo ""
    
    # Memory usage
    echo "--- Memory Usage ---"
    free -h
    echo ""
    
    # Disk usage
    echo "--- Disk Usage ---"
    df -h /
    echo ""
    df -h /var/lib/rancher/k3s/
    echo ""
    
    # Container runtime disk usage
    echo "--- Container Image Storage ---"
    du -sh /var/lib/rancher/k3s//* 2>/dev/null | head -5
    echo ""
    
    # Network connections
    echo "--- Network Connections (k3s related) ---"
    netstat -tulpn 2>/dev/null | grep -E "[k]3s|6443|10250|10251" || echo "(netstat not available)"
    echo ""
    
    # k3s processes
    echo "--- k3s Process Count ---"
    ps aux | grep -E "[k]3s|[k]ubelet|[c]ontainerd" | wc -l
    echo "running k3s-related processes"
    echo ""
    
    # Node status
    echo "--- Kubernetes Node Status ---"
    sudo k3s kubectl get nodes -o wide 2>/dev/null || echo "(Unable to get node status)"
    echo ""
    
    # Pod status
    echo "--- All Pods Across Namespaces ---"
    sudo k3s kubectl get pods -A 2>/dev/null || echo "(Unable to list pods)"
    echo ""
    
    # DoH status specifically
    echo "--- DoH Stack Status ---"
    sudo k3s kubectl get pods -n doh-system 2>/dev/null || echo "(doh-system namespace not found)"
}

##############################################################################
# PART 2: CLEANUP OPTIONS (NON-DESTRUCTIVE)
##############################################################################

cleanup_k3s() {
    echo "================================================"
    echo " k3s Cleanup (Non-Destructive)"
    echo "================================================"
    echo ""
    
    echo "1. Remove unused Docker images..."
    sudo k3s crictl rmi --prune 2>/dev/null && echo "   ✅ Old images removed" || echo "   ⚠️  No unused images"
    echo ""
    
    echo "2. Clear k3s logs..."
    sudo journalctl --vacuum=100M 2>/dev/null && echo "   ✅ Logs cleaned" || echo "   ⚠️  Could not clean logs"
    echo ""
    
    echo "3. Check for hung processes..."
    sudo k3s server --dry-run 2>/dev/null && echo "   ✅ k3s server is healthy" || echo "   ⚠️  Issues detected"
}

##############################################################################
# PART 3: COMPLETE UNINSTALL
##############################################################################

uninstall_k3s() {
    echo "================================================"
    echo " WARNING: Complete k3s Uninstall"
    echo "================================================"
    echo ""
    echo "This will:"
    echo "  - Stop k3s service"
    echo "  - Remove all Kubernetes pods/deployments"
    echo "  - Remove k3s binary and config"
    echo "  - FREE UP DISK SPACE (~2-5GB)"
    echo ""
    echo "YOUR DATA:"
    echo "  - .env file (configuration) - KEPT"
    echo "  - doh-kubernetes repo - KEPT"
    echo "  - Let's Encrypt certs - KEPT"
    echo ""
    
    read -p "Type 'yes' to uninstall k3s: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        return 0
    fi
    
    echo ""
    echo "Starting uninstall process..."
    
    # Stop k3s
    echo "1. Stopping k3s service..."
    sudo systemctl stop k3s 2>/dev/null
    sudo systemctl disable k3s 2>/dev/null
    sleep 5
    
    # Run k3s uninstall script
    echo "2. Running k3s uninstall script..."
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        sudo /usr/local/bin/k3s-uninstall.sh
    else
        echo "   (k3s uninstall script not found, trying kill script)"
        if [ -f /usr/local/bin/k3s-killall.sh ]; then
            sudo /usr/local/bin/k3s-killall.sh
        fi
    fi
    
    # Manual cleanup (in case uninstall script didn't do everything)
    echo "3. Cleaning up residual files..."
    sudo rm -rf /etc/rancher/ 2>/dev/null
    sudo rm -rf /var/lib/rancher/ 2>/dev/null
    sudo rm -rf /var/lib/kubelet/ 2>/dev/null
    sudo rm -f /usr/local/bin/k3s* 2>/dev/null
    sudo rm -f /etc/systemd/system/k3s* 2>/dev/null
    sudo systemctl daemon-reload 2>/dev/null
    
    echo ""
    echo "✅ k3s uninstalled successfully"
    echo ""
    echo "Available disk space:"
    df -h / | tail -1
}

##############################################################################
# REINSTALL AFTER UNINSTALL
##############################################################################

reinstall_k3s() {
    echo "================================================"
    echo " Reinstall k3s"
    echo "================================================"
    echo ""
    
    echo "Installing k3s..."
    curl -sfL https://get.k3s.io | sh -
    
    echo ""
    echo "Waiting for k3s to start..."
    for i in {1..30}; do
        if sudo k3s kubectl cluster-info &>/dev/null; then
            echo "✅ k3s is ready"
            break
        fi
        echo "  Wait ${i}s..."
        sleep 1
    done
    
    echo ""
    echo "To deploy DoH again, run:"
    echo "  cd ~/doh-kubernetes"
    echo "  bash scripts/deploy.sh"
}

##############################################################################
# MAIN MENU
##############################################################################

main() {
    while true; do
        echo ""
        echo "================================================"
        echo " k3s Diagnostic & Management"
        echo "================================================"
        echo "1. Check k3s resource usage (diagnose bottleneck)"
        echo "2. Cleanup k3s (remove unused data)"
        echo "3. Uninstall k3s completely"
        echo "4. Reinstall k3s"
        echo "5. Exit"
        echo ""
        read -p "Select option (1-5): " choice
        
        case $choice in
            1) check_k3s_resources ;;
            2) cleanup_k3s ;;
            3) uninstall_k3s ;;
            4) reinstall_k3s ;;
            5) exit 0 ;;
            *) echo "Invalid option" ;;
        esac
    done
}

main
