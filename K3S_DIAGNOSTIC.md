# k3s Diagnostic & Uninstall Guide

## Quick Check Commands

### 1. **Is k3s running?**
```bash
sudo systemctl status k3s
# OR
ps aux | grep k3s | grep -v grep
```

### 2. **Check CPU & Memory Usage**
```bash
# Total system resources
free -h
df -h

# k3s processes specifically
ps aux | grep -E "[k]3s|[k]ubelet|[c]ontainerd" | awk '{print $1, $3"%", $6"MB", $11}'
```

### 3. **Check Disk Space Used by k3s**
```bash
# Total k3s storage
du -sh /var/lib/rancher/k3s/

# Container images
du -sh /var/lib/rancher/k3s/agent/containerd/

# Logs
du -sh /var/log/pods/
```

### 4. **Check DoH Pod Status**
```bash
sudo k3s kubectl get pods -n doh-system
sudo k3s kubectl get nodes
```

### 5. **Check Network/Port Usage**
```bash
sudo netstat -tulpn | grep -E "6443|10250|30053|30443"
# OR
sudo ss -tulpn | grep -E "6443|10250|30053|30443"
```

---

## Using the Diagnostic Script

```bash
cd ~/doh-kubernetes
bash scripts/k3s-diagnostic.sh
```

Menu options:
- **1**: Check if k3s is bottlenecking (CPU/Memory/Disk)
- **2**: Cleanup unused data (~500MB-2GB freed)
- **3**: Complete uninstall (~5GB freed)
- **4**: Reinstall k3s
- **5**: Exit

---

## Is k3s Bottlenecking? Red Flags

**High CPU:**
```bash
ps aux | grep k3s
# If any process uses >50% CPU consistently
```

**High Memory:**
```bash
free -h | grep Mem
# If used memory is >80% of total
```

**High Disk:**
```bash
df -h / | grep -v Filesystem
# If /var/lib/rancher/k3s/ is >10GB
```

---

## Quick Uninstall (No Menu)

```bash
# 1. Stop k3s
sudo systemctl stop k3s
sudo systemctl disable k3s

# 2. Run uninstaller
sudo /usr/local/bin/k3s-uninstall.sh

# 3. Manual cleanup
sudo rm -rf /etc/rancher/
sudo rm -rf /var/lib/rancher/
sudo rm -rf /var/lib/kubelet/

# 4. Verify
k3s --version
# Should return: command not found
```

---

## If You Just Want to Pause k3s

Instead of uninstalling (keeps everything intact):

```bash
# Pause (stop but don't remove)
sudo systemctl stop k3s
sudo systemctl disable k3s

# Later: Resume
sudo systemctl enable k3s
sudo systemctl start k3s
```

---

## Reinstall After Uninstall

```bash
# Option 1: Auto-install via script
bash scripts/k3s-diagnostic.sh
# Select: 4 (Reinstall k3s)

# Option 2: Manual install
curl -sfL https://get.k3s.io | sh -

# Option 3: Full redeploy
bash scripts/install.sh
```

---

## What Gets Deleted vs. Kept

**DELETED during uninstall:**
- k3s binary (`/usr/local/bin/k3s*`)
- k3s config (`/etc/rancher/`)
- Container runtime data (`/var/lib/rancher/`)
- Kubernetes state (`/var/lib/kubelet/`)

**KEPT (Safe):**
- ✅ Your `.env` file
- ✅ doh-kubernetes repository
- ✅ Your Let's Encrypt certificates (`/etc/letsencrypt/`)
- ✅ Your DoH configuration files

---

## Disk Space Typical Usage

| Component | Space |
|-----------|-------|
| k3s binary | 50MB |
| Container images | 500MB - 2GB |
| Etcd database | 100MB - 500MB |
| Logs | 100MB - 1GB |
| **Total** | **~1-5GB** |

Uninstalling frees this up!

---

## Troubleshooting

**Q: k3s is stuck or not responding**
```bash
sudo systemctl restart k3s
# Wait 30 seconds
sudo k3s kubectl cluster-info
```

**Q: Want to reset k3s but keep the VPS**
```bash
# First uninstall
sudo /usr/local/bin/k3s-uninstall.sh

# Then reinstall
curl -sfL https://get.k3s.io | sh -
```

**Q: Check if k3s is causing high system load**
```bash
top
# Look for k3s processes using high CPU/Memory
# Then run: bash scripts/k3s-diagnostic.sh -> Option 2 (cleanup)
```

---

## Still Have Issues?

Run the full diagnostic:
```bash
bash scripts/k3s-diagnostic.sh
# Option 1 shows everything
```

Then decide:
- If using <500MB: Keep it running
- If using 2-3GB: Run cleanup (option 2)
- If using >5GB: Uninstall and redeploy (option 3)
