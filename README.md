# [xuty.dev](xuty.dev)

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
├── bootstrap/
├─────── flux-system/                 # Flux installation (bootstrap)
│
├── clusters/
│   └── homelab/                      # The "cluster"
│       ├── apps.yaml                 # Flux Kustomization
│       └── infrastructure.yaml       # Flux Kustomization
│
├── infrastructure/
│   └── cloudflared/
│       ├── deployment.yaml
│       ├── configmap.yaml
│       └── kustomization.yaml
│
├── apps/
│   ├── base/                         # Base resources reusable
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── homepage/
│   │   ├── kustomization.yaml        # Base + patches
│   │   ├── namespace.yaml
│   │   └── ingress-patch.yaml        # host: xuty.dev
│   └── blog/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       └── ingress-patch.yaml        # host: blog.xuty.dev
│
├── secrets/
│   └── cloudflared-credentials.yaml  # Secure encrypted credentials for Cloudflare Tunnel
│
└── .sops.yaml                        # Encryption config for SOPS
```

## Stack
| Component       | Purpose                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------- |
| **k3s**         | Lightweight Kubernetes distribution. Includes Traefik, Flannel, CoreDNS, and containerd.                    |
| **Flux CD**     | Native Kubernetes GitOps controller. Event-driven, with native RBAC and no UI that breaks the GitOps model. |
| **Kustomize**   | Declarative manifest composition. No templates, no conditional logic. Built into `kubectl`.                 |
| **SOPS + Age**  | Secret encryption. Commit encrypted YAML files to Git. Flux automatically decrypts them in the cluster.     |
| **Traefik**     | Ingress controller (included with k3s). Routes HTTP traffic by hostname within the cluster.                 |
| **cloudflared** | Cloudflare Tunnel client. Creates an outbound tunnel from the cluster to Cloudflare.                        |



## Requirements

* A server with Ubuntu Server or similar (testing on Ubuntu 26.04)
* A domain managed by Cloudflare (testing on xuty.dev)
* A Cloudflare account (for Cloudflare Tunnel)
* A GitHub account (for Flux)

## Installation

### 1. Check and disable swap memory

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

### 2. Install k3s on server

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

### 3. Install tools

```bash
# Flux CLI
curl -s https://fluxcd.io/install.sh | sudo bash

# SOPS
./get-sops.sh

# Age
sudo apt install age
```

## 4. Configure SOPS + Age for secrets
SOPS is the tool used to encrypt secrets. It uses GPG to encrypt the secrets, and the public key is stored in the `.sops.yaml` file.
So secrets are commiteable and secure.

```bash
./setup-sops.sh
```

It check if the `age.key` (ignored on .gitignored) file exists, if not, it generates a new one.
It also creates a `.sops.yaml` file with the public key of the age key.

## 5. Setup FluxCD (GitOps)
Assuming you have a SSH configured agains git repository, you can use the following command to bootstrap FluxCD:
```bash
# Create directory (already on repo)
mkdir -p bootstrap/flux-system

# Generate manifests
flux install --export > bootstrap/flux-system/gotk-components.yaml

flux create source git flux-system \
  --url=https://github.com/xutyxd/xuty-dev.git \
  --branch=main \
  --export > bootstrap/flux-system/gotk-sync.yaml

flux create kustomization flux-system \
  --source=GitRepository/flux-system \
  --path=./clusters/homelab \
  --prune=true \
  --interval=10m \
  --export > bootstrap/flux-system/kustomization.yaml

# Commit to Git
git add bootstrap/flux-system/
git commit -m "feat(flux): add flux system manifests"
git push origin main

# Then apply and never do an apply again
# Apply only components (CRDs + controladores)
kubectl apply -f bootstrap/flux-system/gotk-components.yaml

# Wait for Flux to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/part-of=flux -n flux-system --timeout=120s
# Create secret with SOPS
cat age.key |
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin


# Then apply manifests
kubectl apply -f bootstrap/flux-system/gotk-sync.yaml
kubectl apply -f bootstrap/flux-system/kustomization.yaml
```

After this, Flux will start reconciling the cluster automatically.


## 7. Setup Cloudflare Tunnel

### 7.1 Create a tunnel on Cloudflare Dashboard
Go to Cloudflare Zero Trust -> Networks -> Tunnels & Mesh -> Create a tunnel -> Cloudflare Tunnel
Then name it, and copy token: `eyJhIjoiNT...`, it will be used on [7.3 step](#73-encrypt-credentials-with-sops).

Configure DNS like this:

| Subdomain | Domain        | Service - Type     | Service - URL                                                        |
| --------- | ------------- | ------------------ | -------------------------------------------------------------------- | 
| empty     | `your.domain` | HTTP               | `http://your-ingress-controller.your-namespace.svc.cluster.local:80` |
| `*@*`     | `your.domain` | HTTP               | `http://your-ingress-controller.your-namespace.svc.cluster.local:80` |

- `` = root domain (e.g. xuty.dev). Cloudflare use *CNAME Flattening*
- `*` = wildcard subdomain (e.g. blog.xuty.dev), covers all subdomains

Review DNS records of your domain and check both are created and proxied.

### 7.2 Encrypt credentials with SOPS
Get token saved before, and encrypt it with SOPS:
```bash
bash ./sops-secret.sh --name cloudflared-credentials -N cloudflared -l CLOUDFLARE_TOKEN=eyJhIjoiNTQ5NTQ...
```

Note: Name `cloudflared-credentials` will be referenced on `deployment.yaml`

### 7.3 Configure infrastructure
Create manifests for the tunnel, Flux will manage it via GitOps.

#### 7.3.1 Namespace
Create it on `infrastructure/cloudflared/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflared
```

#### 7.3.2 Deployment
Create it on `infrastructure/cloudflared/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
  labels:
    app: cloudflared
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --no-autoupdate
            - --metrics
            - 0.0.0.0:60123
            - run
            - --token
            - $(CLOUDFLARE_TOKEN)
          livenessProbe:
            httpGet:
              path: /metrics
              port: metrics
            failureThreshold: 3
            initialDelaySeconds: 5
            periodSeconds: 5
          ports:
            - containerPort: 60123
              name: metrics
          env:
            - name: CLOUDFLARE_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflared-credentials
                  key: CLOUDFLARE_TOKEN
```

#### 7.3.3 Kustomization (Kustomize)
Create it on `infrastructure/cloudflared/kustomization.yaml`, it references the manifests created before.
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - ../../secrets/cloudflared-credentials.yaml # <-- Created before and referenced on deployment.yaml
```

### 7.3.4 Reference it on infrastructure
Create it on `infrastructure/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - cloudflared
```

### 7.4 Deploy on Kubernetes
Create a commit with the manifests created before and push to Git, Flux will do the magic.

