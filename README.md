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

## 4. Setup SOPS
SOPS is the tool used to encrypt secrets. It uses GPG to encrypt the secrets, and the public key is stored in the `.sops.yaml` file.
So secrets are commiteable and secure.
```bash
./setup-sops.sh
```

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

# Then apply manifests
kubectl apply -f bootstrap/flux-system/gotk-sync.yaml
kubectl apply -f bootstrap/flux-system/kustomization.yaml
```

After this, Flux will start reconciling the cluster automatically.

## 6. Configure SOPS + Age for secrets
SOPS is the tool used to encrypt secrets. It uses GPG to encrypt the secrets, and the public key is stored in the `.sops.yaml` file.
So secrets are commiteable and secure.

```bash
./setup-sops.sh
```

It check if the `age.key` (ignored on .gitignored) file exists, if not, it generates a new one.
It also creates a `.sops.yaml` file with the public key of the age key.


## 7. Setup Cloudflare Tunnel

### 7.1 Install cloudflared on local machine
```bash
# Download latest version
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb

# Install
sudo dpkg -i cloudflared.deb

# Verify
cloudflared --version
```

## 7.2 Create tunnel
```bash
# It opens a browser to authenticate, open on your machine
cloudflared tunnel login

cloudflared tunnel create YOUR-TUNNEL-NAME
# Example: cloudflared tunnel create xuty-dev
```

Save:
 - Tunnel UUID (it appears in output)
 - File `~/.cloudflared/UUID.json`

## 7.3 Configure DNS on Cloudflare Dashboard
Go to DNS -> Records of your domain, and create a new record:

| Type  | Name | Content                   | Proxy     |
| ----- | ---- | ------------------------- | --------- |
| CNAME | `@`  | `<UUID>.cfargotunnel.com` | ✅ Proxied |
| CNAME | `*`  | `<UUID>.cfargotunnel.com` | ✅ Proxied |

- `@` = root domain (e.g. xuty.dev). Cloudflare use *CNAME Flattening*
- `*` = wildcard subdomain (e.g. blog.xuty.dev), covers all subdomains
- *Proxied* = Cloudflare manages SSL and cache

## 7.4 Encrypt credentials with SOPS
```bash
bash sops-secret.sh --name cloudflared-credentials -N cloudflared -f ~/.cloudflared/UUID.json=credentials.json
```

Note: Name `cloudflared-credentials` will be referenced on `deployment.yaml`


## 7.5 Deploy on Kubernetes
Create manifests for the tunnel:, Flux will manage it via GitOps.

### 7.5.1 Namespace
Create it on `infrastructure/cloudflared/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflared
```

### 7.5.2 ConfigMap
Create it on `infrastructure/cloudflared/configmap.yaml`
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config # <-- This will be referenced by the deployment
  namespace: cloudflared
data:
  config.yaml: |
    tunnel: <TU_TUNNEL_UUID>
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true

    ingress:
      # Dominio raíz - tu página personal
      - hostname: xuty.dev
        service: http://traefik.kube-system.svc.cluster.local:80
        originRequest:
          noTLSVerify: true

      # Blog
      - hostname: blog.xuty.dev
        service: http://traefik.kube-system.svc.cluster.local:80
        originRequest:
          noTLSVerify: true

      # Any future subdomain
      - hostname: "*.xuty.dev"
        service: http://traefik.kube-system.svc.cluster.local:80
        originRequest:
          noTLSVerify: true

      # Fallback 404
      - service: http_status:404
```
Basic explanation about `service`:
- `traefik` = Traefik Ingress Controller (default of k3s)
- `kube-system` = Kubernetes system namespace
- `svc` = Kind of Kubernetes Resource (Service)
- `cluster.local` = Internal TLD DNS of the cluster
- `80` = Port of the service

### 7.5.3 Deployment
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
            - --config
            - /etc/cloudflared/config.yaml # ConfigMap configured before
            - run
          resources:
            requests:
              memory: "32Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
          volumeMounts:
            - name: config
              mountPath: /etc/cloudflared
              readOnly: true
            - name: creds
              mountPath: /etc/cloudflared/creds
              readOnly: true
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            failureThreshold: 1
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: cloudflared-config
        - name: creds
          secret:
            secretName: cloudflared-credentials
```

### 7.5.4 Kustomization (Kustomize)
Create it on `infrastructure/cloudflared/kustomization.yaml`, it references the manifests created before.
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - configmap.yaml
  - deployment.yaml
```

### 7.5.5 Reference it on infrastructure
Create it on `infrastructure/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - cloudflared
```

## 7.6 Flux reconciliation
Flux will reconcile the cluster automatically.

## 8. Configure Kustomizations (Flux)

### 8.1 Infrastructure
Create it on `clusters/homelab/flux-system/kustomization.yaml`
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1 # <-- Check is not Kubernetes Kustomize
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  path: ./infrastructure
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

### 8.2 Apps
Create it on `clusters/homelab/flux-system/kustomization.yaml`

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure
#   decryption: # Uncomment if apps have secrets
#       provider: sops
#       secretRef:
#       name: sops-age
```
