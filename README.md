# DoH Smart DNS — Kubernetes Edition

DNS-over-HTTPS smart DNS proxy for Xbox, Discord, and gaming platforms, deployed on Kubernetes.

> This is the Kubernetes equivalent of the [Docker Compose version](../doh/).
> Same functionality, but with replicas, rolling updates, health checks, and production overlays.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Kubernetes Cluster                │
│                   Namespace: doh-system              │
│                                                     │
│  ┌─────────────┐    ┌──────────────┐                │
│  │  doh-nginx   │───▶│  doh-backend  │  (DoH server) │
│  │  (TLS/HTTPS) │    │  :8053        │               │
│  │  :443, :80   │    └──────┬───────┘                │
│  └─────────────┘           │                        │
│        ▲                   ▼                        │
│        │           ┌──────────────┐                  │
│   NodePort:30443   │  coredns-     │                 │
│   NodePort:30080   │  smartdns     │  (Smart DNS)    │
│                    │  :53          │                 │
│                    └──────────────┘                  │
│                          ▲                          │
│                    NodePort:30053                    │
└─────────────────────────────────────────────────────┘
         ▲                    ▲
     Xbox/Client          Xbox/Client
     (DoH mode)          (plain DNS)
```

## Quick Start

### Prerequisites

- A Kubernetes cluster (k3s, minikube, kubeadm, etc.)
- `kubectl` configured and connected to the cluster (auto-installed if missing)
- Your VPS/node public IP address

### One-Command Install

```bash
# Just run it — prompts for your VPS IP interactively
bash scripts/deploy.sh

# Or pass your IP directly
bash scripts/deploy.sh 1.2.3.4

# Production overlay (3 replicas, higher resources)
bash scripts/deploy.sh 1.2.3.4 production
```

The script handles **everything** automatically:
- Installs `kubectl` if not found
- Generates the xbox-hosts ConfigMap from template
- Generates self-signed TLS certificates (or uses existing ones from `ssl/` or Let's Encrypt)
- Deploys all Kubernetes resources
- Waits for rollouts to complete
- Runs DNS and DoH health checks
- Saves your VPS_IP to `.env` for next time

### Verify

```bash
# Check status
bash scripts/deploy.sh status

# Test DNS resolution
dig @YOUR_NODE_IP -p 30053 xboxlive.com

# Test DoH endpoint
curl -ks https://YOUR_NODE_IP:30443/health
```

## Project Structure

```
doh-kubernetes/
├── .env.example                    # Configuration template
├── README.md                       # This file
├── base/                           # Base Kubernetes manifests
│   ├── kustomization.yaml          # Kustomize entry point
│   ├── namespace.yaml              # doh-system namespace
│   ├── configmap-coredns.yaml      # CoreDNS Corefile config
│   ├── configmap-nginx.yaml        # Nginx reverse proxy config
│   ├── configmap-xbox-hosts.yaml   # [GENERATED] Xbox/gaming hosts
│   ├── coredns-smartdns.yaml       # CoreDNS Deployment + Services
│   ├── doh-backend.yaml            # DoH server Deployment + Service
│   ├── doh-nginx.yaml              # Nginx Deployment + Service
│   └── pdb.yaml                    # PodDisruptionBudgets
├── overlays/
│   └── production/
│       └── kustomization.yaml      # Production overrides (3 replicas, more resources)
├── coredns/
│   └── xbox-hosts.template         # Hosts file template (__VPS_IP__ placeholders)
└── scripts/
    ├── deploy.sh                   # Main deploy/destroy/status script
    └── regenerate-hosts.sh         # Regenerate xbox-hosts ConfigMap
```

## Commands

| Command | Description |
|---|---|
| `bash scripts/deploy.sh` | Full install — interactive VPS IP prompt |
| `bash scripts/deploy.sh 1.2.3.4` | Full install with VPS IP |
| `bash scripts/deploy.sh 1.2.3.4 production` | Production install (3 replicas, more resources) |
| `bash scripts/deploy.sh status` | Show pods, services, and access info |
| `bash scripts/deploy.sh destroy` | Delete the entire doh-system namespace |
| `bash scripts/regenerate-hosts.sh [IP]` | Regenerate hosts and restart CoreDNS (hot reload) |

## Ports / Services

| Service | Internal Port | NodePort | Protocol | Purpose |
|---|---|---|---|---|
| coredns-smartdns | 53 | 30053 | UDP/TCP | DNS for Xbox/clients |
| doh-nginx | 443 | 30443 | TCP | HTTPS DoH endpoint |
| doh-nginx | 80 | 30080 | TCP | HTTP → HTTPS redirect |

> **Tip:** If your cluster has a LoadBalancer (cloud provider or MetalLB), you can change
> the Service types from `NodePort` to `LoadBalancer` to get a dedicated external IP.

## TLS Certificates

The deploy script **automatically generates self-signed TLS certificates** if none are found.
For production, you can replace them:

### Option A: Provide your own certificates

Place `tls.crt` and `tls.key` in the `ssl/` directory before running `deploy.sh`, or:

```bash
kubectl create secret tls doh-tls-certs \
  --namespace=doh-system \
  --cert=/etc/letsencrypt/live/yourdomain.com/fullchain.pem \
  --key=/etc/letsencrypt/live/yourdomain.com/privkey.pem
```

### Option B: cert-manager (recommended for production)

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Create a ClusterIssuer for Let's Encrypt
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

# Create a Certificate resource
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: doh-tls-certs
  namespace: doh-system
spec:
  secretName: doh-tls-certs
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - bypass.yourdomain.com
EOF
```

## Differences from Docker Compose Version

| Feature | Docker Compose | Kubernetes |
|---|---|---|
| Replicas | 1 per service | 2-3 per service (configurable) |
| Health checks | Basic restart | Liveness + readiness probes |
| Rolling updates | Recreate (brief downtime) | Zero-downtime rolling updates |
| Config management | Volume mounts | ConfigMaps + Secrets |
| Disruption safety | None | PodDisruptionBudgets |
| Monitoring | Manual | Prometheus metrics endpoint |
| Scaling | Manual restart | `kubectl scale` or HPA |
| Resource limits | None | CPU/memory requests and limits |
| Networking | Bridge + host ports | ClusterIP + NodePort/LB |

## Scaling

```bash
# Scale CoreDNS to 5 replicas
kubectl scale deployment/coredns-smartdns -n doh-system --replicas=5

# Scale DoH backend
kubectl scale deployment/doh-backend -n doh-system --replicas=3
```

## Monitoring

CoreDNS exports Prometheus metrics on port 9153:

```bash
# Port-forward to check metrics locally
kubectl port-forward -n doh-system svc/coredns-smartdns 9153:9153
curl http://localhost:9153/metrics
```

## Troubleshooting

```bash
# Check pod status
kubectl get pods -n doh-system -o wide

# Check pod logs
kubectl logs -n doh-system -l app.kubernetes.io/name=coredns-smartdns --tail=50
kubectl logs -n doh-system -l app.kubernetes.io/name=doh-backend --tail=50
kubectl logs -n doh-system -l app.kubernetes.io/name=doh-nginx --tail=50

# Describe a failing pod
kubectl describe pod -n doh-system <pod-name>

# Test DNS from inside the cluster
kubectl run -it --rm dns-test --image=busybox:1.36 --restart=Never -- \
  nslookup xboxlive.com coredns-smartdns.doh-system.svc.cluster.local

# Check events
kubectl get events -n doh-system --sort-by='.lastTimestamp'
```

## Lightweight Cluster Setup (k3s)

If you don't have a Kubernetes cluster yet, [k3s](https://k3s.io) is the easiest way to run one on a single VPS:

```bash
# Install k3s (single-node cluster, <512MB RAM overhead)
curl -sfL https://get.k3s.io | sh -

# Verify
sudo k3s kubectl get nodes

# Use k3s kubectl or copy kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Now deploy — just one command
bash scripts/deploy.sh $(curl -s ifconfig.me)
```
