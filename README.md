# Xuty dev (xuty.dev)

A personal homelab built on GitOps and Infrastructure as Code (IaC). It started as a single k3s node completely managed by FluxCD. 

All traffic is routed through a Cloudflare Tunnel, eliminating the need for public ports. Secrets are securely stored using SOPS, ensuring security without sacrificing code transparency. Everything is declarative, versioned, and automatically synchronized.


### Philosophy
This project tries to follow the GitOps KRM-Native principles:
* **Kubernetes Resource Model (KRM):** KRM as the only API for everything: deployments, ingress, DNS, secrets.
* **Declarative and inmutable:** Everything is defined in YAML. No scripts, no click-ops.
* **Continuous Reconciliation:** Flux watches Git and converges the cluster to the desired state automatically.
* **Native RBAC:** Flux delegates permissions to Kubernetes RBAC. No parallel access models.
* **Zero Public Ports:** No public port of the router is open. The traffic enters through the outgoing tunnel to Cloudflare.

## Architecture
```
Usuario ──HTTPS──> Cloudflare Edge ──HTTPS──> Cloudflare Tunnel
                                                    │
                                                    v
                                          ┌──────────────────┐
                                          │  k3s Cluster     │
                                          │  ┌───────────┐   │
                                          │  │cloudflared│   │
                                          │  └─────┬─────┘   │
                                          │        │ HTTP:80 │
                                          │  ┌─────┴─────┐   │
                                          │  │  Traefik  │   │
                                          │  │ (Ingress) │   │
                                          │  └─────┬─────┘   │
                                          │        │         │
                                          │  ┌─────┴─────┐   │
                                          │  │ Flux CD   │<──+── GitHub
                                          │  │ (GitOps)  │   │   (this repo)
                                          │  └───────────┘   │
                                          │        │         │
                                          │  ┌─────┴─────┐   │
                                          │  │  Apps     │   │
                                          │  │  (blog...)│   │
                                          │  └───────────┘   │
                                          └──────────────────┘
```

## Code Structure

```
xuty-k8s/
├── clusters/
│   └── homelab/                 # The "cluster"
│       ├── flux-system/         # Flux installation (bootstrap)
│       ├── infrastructure/
│       │   ├── kustomization.yaml
│       │   ├── cloudflared/
│       │   ├── traefik/
│       │   └── sources/         # HelmRepositories, OCIRepositories
│       └── apps/
│           ├── kustomization.yaml
│           ├── homepage/
│           └── blog/
├── infrastructure/
│   ├── cloudflared/
│   │   ├── deployment.yaml
│   │   ├── configmap.yaml
│   │   └── kustomization.yaml
│   └── sources/
│       └── cloudflare-helm.yaml  # If using Helm charts
├── apps/
│   ├── base/                     # Base resources reusable
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── homepage/
│   │   ├── kustomization.yaml    # Base + patches
│   │   ├── namespace.yaml
│   │   └── ingress-patch.yaml    # host: xuty.dev
│   └── blog/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       └── ingress-patch.yaml    # host: blog.xuty.dev
└── secrets/
    └── .sops.yaml               # Encryption config for SOPS
```

## Requirements

* A server with Ubuntu Server or similar (testing on Ubuntu 26.04)
* A domain managed by Cloudflare (testing on xuty.dev)
* A Cloudflare account (for Cloudflare Tunnel)

## Installation

### Check and disable swap memory

Check if your server has swap memory enabled:

```bash
swapon --show
```
If the output is empty, swap memory is disabled, everything is fine. If it's not, you need to disable it.

Disable on this session:

```bash
sudo swapoff -a
```

Disable permanently:
```bash
# And comment line with /swap.img or similar
sudo nano /etc/fstab
```

### Install k3s on server

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --disable servicelb \
  --write-kubeconfig-mode 644

# Configure kubeconfig for current user
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config
```
With `--disable servicel` k3s will not create a load balancer for the cluster, not need as we will use Cloudflare tunnel.

### Install tools

#### Flux CLI
```
curl -s https://fluxcd.io/install.sh | sudo bash
```

#### SOPS
Use:
```bash
./setup-sops.sh
```

Or:
```bash
# Download the latest release
LATEST=$(curl -s https://api.github.com/repos/getsops/sops/releases/latest | grep '"tag_name"' | cut -d '"' -f4)

wget https://github.com/getsops/sops/releases/download/${LATEST}/sops-${LATEST#v}.linux.amd64

# Make it executable
chmod +x sops-${LATEST#v}.linux.amd64

# Move it into your PATH
sudo mv sops-${LATEST#v}.linux.amd64 /usr/local/bin/sops

# Verify
sops --version
```

#### Age
```
sudo apt install age
```

## Install Flux

```bash
# Clone and move to the repo
git clone https://github.com/xutyxd/xuty-dev.git
cd xuty-dev

# Bootstrap Flux
flux bootstrap github \
  --owner=xutyxd \
  --repository=xuty-dev \
  --branch=main \
  --private=false \
  --path=clusters/homelab/flux-system \
  --export > ./clusters/homelab/flux-system/bootstrap.yaml
  --personal
```

## Setup SOPS

```bash
./setup-sops.sh
```

## Setup Cloudflare Tunnel

### Install cloudflared

```bash
# Download latest version
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb

# Install
sudo dpkg -i cloudflared.deb

# Verify
cloudflared --version
```