# [xuty.dev](https://xuty.dev)

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
xuty-dev/
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


## 6. Setup Cloudflare Tunnel

### 6.1 Create a tunnel on Cloudflare Dashboard
Go to Cloudflare Zero Trust -> Networks -> Tunnels & Mesh -> Create a tunnel -> Cloudflare Tunnel
Then name it, and copy token: `eyJhIjoiNT...`, it will be used on [6.3 step](#73-encrypt-credentials-with-sops).

Configure DNS like this:

| Subdomain | Domain        | Service - Type     | Service - URL                                                        |
| --------- | ------------- | ------------------ | -------------------------------------------------------------------- | 
| empty     | `your.domain` | HTTP               | `http://your-ingress-controller.your-namespace.svc.cluster.local:80` |
| `*@*`     | `your.domain` | HTTP               | `http://your-ingress-controller.your-namespace.svc.cluster.local:80` |

- `` = root domain (e.g. xuty.dev). Cloudflare use *CNAME Flattening*
- `*` = wildcard subdomain (e.g. blog.xuty.dev), covers all subdomains

Review DNS records of your domain and check both are created and proxied.

### 6.2 Encrypt credentials with SOPS
Get token saved before, and encrypt it with SOPS:
```bash
bash ./sops-secret.sh --name cloudflared-credentials -N cloudflared -l CLOUDFLARE_TOKEN=eyJhIjoiNTQ5NTQ...
```

Note: Name `cloudflared-credentials` will be referenced on `deployment.yaml`

### 6.3 Configure infrastructure
Create manifests for the tunnel, Flux will manage it via GitOps.

#### 6.3.1 Namespace
Create it on `infrastructure/cloudflared/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflared
```

#### 6.3.2 Deployment
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

#### 6.3.3 Kustomization (Kustomize)
Create it on `infrastructure/cloudflared/kustomization.yaml`, it references the manifests created before.
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - ../../secrets/cloudflared-credentials.yaml # <-- Created before and referenced on deployment.yaml
```

### 6.3.4 Reference it on infrastructure
Create it on `infrastructure/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - cloudflared
```

### 6.4 Deploy on Kubernetes
Create a commit with the manifests created before and push to Git, Flux will do the magic.

## 7. Add a new app

### 7.1 Create a new app
Create a new directory under `apps/` with the name of the app, e.g. `apps/xuty-dev/`
For this example, we will use my front page `xuty-dev`.

### 7.2 Create structure overlay
```
apps/
└── xuty-dev/                       # ← New overlay
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── deployment-patch.yaml
    └── ingress-patch.yaml
```

### 7.3 Create kustomization overlay
Create a `kustomization.yaml` file on `apps/xuty-dev/` with the following content:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: xuty-dev

resources:
  - ../base                     # Reference to base resources
  - namespace.yaml

namePrefix: xuty-dev-           # Name prefix for all resources, where magic happens

commonLabels:                   # Labels to be applied to all resources
  app: xuty-dev

patches:
  - path: deployment-patch.yaml
  - path: ingress-patch.yaml
```


### 7.4 Namespace
Create a `namespace.yaml` file on `apps/xuty-dev/` with the following content:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: xuty-dev
```

### 7.5 Deployment
Create a `deployment-patch.yaml` file on `apps/xuty-dev/` with the following content:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  template:
    spec:
      containers:
        - name: app
          image: xutyxd/xuty.dev:1.1.0  # In future, this will be automated
          imagePullPolicy: IfNotPresent
```

### 7.6 Ingress
Create a `ingress-patch.yaml` file on `apps/xuty-dev/` with the following content:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
spec:
  rules:
    - host: xuty.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: xuty-dev-app
                port:
                  number: 80
```

### 7.7 Reference it on apps
Update `apps/kustomization.yaml` with the following content:

```yaml
resources:
  - other-app
  - xuty-dev   # Add xuty-dev here
```

## 8. Image automation

### 8.1 Verify Image Automation Controllers

```bash
kubectl get deployment -n flux-system | grep image
```
If empty, update flux controllers with new ones:

```bash
flux install \
  --components-extra=image-reflector-controller,image-automation-controller \
  --export > bootstrap/flux-system/gotk-components.yaml
```
Commit and push to Git, Flux will do the magic.

```bash
git add bootstrap/flux-system/gotk-components.yaml
git commit -m "feat(flux): add image automation controllers"
git push origin main
```

### 8.2 Create an Encrypted GitHub PAT Secret

A PAT is needed by `ImageUpdateAutomation` to push back to GitHub with the new image version.

Create a secret with the PAT, and encrypt it with SOPS:
```bash
bash ./sops-secret.sh --name github-pat -N flux-system -l username=USERNAME -l password=PASSWORD
```

### 8.3 Update the GitRepository for Write Access

Update the `/bootstrap/flux-system/gotk-sync` to allow write access to the repository:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  url: https://github.com/xutyxd/xuty-dev.git
  secretRef:
    name: github-pat          # <-- ADD THIS
```

Commit and push to Git, Flux will do the magic.

```bash
git add bootstrap/flux-system/gotk-sync.yaml
git commit -m "feat(flux): add git credentials for image automation"
git push origin main
```

### 8.4 Create an Image Update Automation

Create a new directory for global image automation resources:

```bash
mkdir -p infrastructure/image-automation
```

Create a `kustomization.yaml` file on `infrastructure/image-automation/` with the following content:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - image-update-automation.yaml
  - xuty-dev-policy.yaml  # <-- this will be the example
```

Create a `image-update-automation.yaml` file on `infrastructure/image-automation/` with the following content:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: xuty-dev
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: Flux Bot
        email: flux@xuty.dev
      messageTemplate: "chore(images): automated update [{{ range .Changed.Images }}{{.}} {{end}}]"
    push:
      branch: main
  update:
    path: ./apps
    strategy: Setters
```

**Note:** `strategy: Setters` tells Flux to look for `# {"$imagepolicy": ...}` markers in your YAML files.

### 8.5 Create an Image Policy for xuty-dev

Create a `xuty-dev-policy.yaml` file on `infrastructure/image-automation/` with the following content:

```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: xuty-dev
  namespace: flux-system
spec:
  image: xutyxd/xuty.dev
  interval: 5m
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: xuty-dev
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: xuty-dev
  policy:
    semver:
      range: ">=1.0.0"
```

### 8.6 Wire it on infrastructure

Update `infrastructure/kustomization.yaml` with the following content:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - cloudflared
  - image-automation
```

### 8.7 Add Image Policy Markers to your YAML files

Add `# {"$imagepolicy": "xuty-dev:1.0.0"}` to your YAML files, e.g.:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  template:
    spec:
      containers:
        - name: app
          image: xutyxd/xuty.dev:1.1.0 # {"$imagepolicy": "flux-system:xuty-dev"}
          imagePullPolicy: IfNotPresent
```

### 8.8 Commit and push to Git

Like other steps, commit and push to Git, Flux will do the magic.

```bash
git add .
git commit -m "feat(image-automation): add image automation"
git push origin main
```
Flux will *not* reconcile itself, so, you need to do it manually:
```bash
kubectl apply -f bootstrap/flux-system/gotk-components.yaml
```

Within a few minutes, you should see:
 - `ImageRepository` scanning you registry
 - `ImagePolicy` selecting the latest semver tag
 - `ImageUpdateAutomation` watching for changes

### 8.9 Verify everything is working

```bash
# Check image repositories
flux get image repository

# Check image policies (should show the selected latest tag)
flux get image policy

# Check the automation status
flux get image update

# Check controller logs if something is wrong
kubectl logs -n flux-system deployment/image-reflector-controller -f
kubectl logs -n flux-system deployment/image-automation-controller -f
```


## 9. Observability stack

### 9.1.1 Check volume

```bash
sudo vgs
```

Should show something like this:
```bash
VG         #PV #LV VSize    VFree
ubuntu-vg    1   1 928.50g 728.50g
```

### 9.1.2 Claim free space

```bash
sudo lvcreate -L 100G -n observability ubuntu-vg
```

### 9.1.3 Format it as ext4

```bash
sudo mkfs.ext4 /dev/ubuntu-vg/observability
```

### 9.1.4 Create the mount point

```bash
sudo mkdir -p /srv/observability/{prometheus,grafana,loki,alertmanager}
```
### 9.1.5 Mount it
Get the UUID of the volume:
```bash
sudo blkid /dev/ubuntu-vg/observability
```
Edit `/etc/fstab` and add the following line:
```
sudo nano /etc/fstab
```
Add:
```
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /srv/observability  ext4  defaults,noatime,discard  0  2
```

Then test it:
```bash
sudo mount -a
df -h /srv/observability
sudo lvdisplay /dev/ubuntu-vg/observability
```

### 9.1.6 How to expand it later if needed

```bash
sudo lvextend -L +50G /dev/ubuntu-vg/observability
sudo resize2fs /dev/ubuntu-vg/observability
```

### 9.2.1 Configuration itself

It will be has this structure:

```
infrastructure/
├── observability/
│   ├── namespace.yaml
|   ├── storage-class.yaml
│   ├── helmrepository.yaml
│   ├── helmrelease.yaml
│   ├── ingress-grafana.yaml
│   └── kustomization.yaml
```

### 9.2.2 Namespace

Create it on `infrastructure/observability/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    app.kubernetes.io/name: observability
```

### 9.2.3 Storage Class

Create it on `infrastructure/observability/storage-class.yaml`

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: observability-local
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
parameters:
  nodePath: /srv/observability
```

Not Flux friendly, but it need to add path to allowed paths in `/var/lib/rancher/k3s/server/manifests/local-storage.yaml`:
So:
```bash
sudo nano /var/lib/rancher/k3s/server/manifests/local-storage.yaml
```
Find for:
```yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: local-path-config
  namespace: kube-system
data:
  config.json: |-
    {
      "nodePathMap":[
      {
        "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
        "paths":["/var/lib/rancher/k3s/storage", "/srv/observability"]  # <-- ADD THIS PATH
      }
      ]
    }

```
Finally, restart the k3s service:
```bash
sudo k3s kubectl rollout restart deployment local-path-provisioner -n kube-system
```

### 9.2.4 Helm Repository

Create it on `infrastructure/observability/helmrepository.yaml`

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: observability
spec:
  interval: 1h
  url: https://prometheus-community.github.io/helm-charts
```

### 9.2.5 Helm Release

Create it on `infrastructure/observability/helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: victoria-metrics-k8s-stack
  namespace: observability
spec:
  interval: 1h
  chart:
    spec:
      chart: victoria-metrics-k8s-stack
      version: "v0.91.x"  # Check latest version: https://docs.victoriametrics.com/helm/victoria-metrics-k8s-stack/changelog/
      sourceRef:
        kind: HelmRepository
        name: victoria-metrics   # <-- should match with metadata.name helmrepository.yaml
        namespace: observability
  values:
    vmsingle:
      enabled: true
      spec:
        retentionPeriod: "14d"  # 14 days, its a homelab
        storage:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 60Gi   # La mayoría de tu LV
          storageClassName: observability-local
    loki:
      enabled: true
      persistence:
        enabled: true
        size: 25Gi
        storageClassName: observability-local
    grafana:
      enabled: true
      admin:
        existingSecret: grafana-admin
        userKey: admin-user
        passwordKey: admin-password
      ingress:
        enabled: true
        ingressClassName: traefik
        hosts:
          - grafana.xuty.dev
    prometheus-node-exporter:
      enabled: true
    kube-state-metrics:
      enabled: true
```

For grafana admin password, create a secret with the following content:
```bash
# Create a random password and save it
GRAFANA_PASS=$(openssl rand -base64 24)

# Create secret with SOPS and ref it on infrastructure/kustomization.yaml
bash ./sops-secret.sh --name grafana-admin -N observability \
  -l admin-user=your-admin-name \
  -l admin-password="$GRAFANA_PASS"
```
### 9.2.6 Kustomization

Create it on `infrastructure/observability/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: observability

resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
  - storage-class.yaml
```

### 9.2.7 Reference it on infrastructure

Create it on `infrastructure/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - cloudflared
  - image-automation
  - observability
  - ../secrets/github-pat.yaml
  - ../secrets/grafana-admin.yaml
```

### 9.2.8 Commit and push to Git
Commit and push to Git, Flux will do the magic. Pray for it.

## 10. Identity

### 10.1 Update server to reserver disk for database
We need to claim some disk space so, review step [9.1](#911-check-volume) to get some space

Fast commands:
```bash
# Check volume
sudo vgs
# Claim free space
sudo lvcreate -L 40G -n database ubuntu-vg
# Format it as ext4
sudo mkfs.ext4 /dev/ubuntu-vg/database
# Create the mount point
mkdir -p /srv/database
# Get uuid
sudo blkid /dev/ubuntu-vg/database
# Update fstab
sudo nano /etc/fstab
# Add next line
# UUID={uuid}  /srv/database  ext4  defaults,noatime,discard  0  2
# Test it
sudo mount -a
df -h /srv/database
sudo lvdisplay /dev/ubuntu-vg/database
# Update allowed paths
sudo nano /var/lib/rancher/k3s/server/manifests/local-storage.yaml
# Restart it to allow to use
sudo k3s kubectl rollout restart deployment local-path-provisioner -n kube-system
```

### 10.2 Setup Postgres DB
Create a secret called `postgres-credentials` with:
```bash
# Create a random password and save it
POSTGRES_PASSWORD=$(openssl rand -base64 24)

# Create secret with SOPS and ref it on infrastructure/database/kustomization.yaml
bash ./sops-secret.sh --name postgres-credentials -N database \
  -l POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
```

### 10.3 Create passwords for every Ory service
Execute `setup-ory-passwords.sh`, it will create a secret (`ory-credentials`) on `flux-system` namespace with 3 random passwords with literals: `KRATOS_PASSWORD`, `HYDRA_PASSWORD` and `KETO_PASSWORD`

The main problem is secret must be shared between `infrastructure` and `ory` apps, different namespaces, so load it on `flux-system` and apply `postBuild.substituteFrom`
