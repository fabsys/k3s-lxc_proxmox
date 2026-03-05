# k3s Homelab GitOps

GitOps repository for a self-hosted Kubernetes homelab running on Proxmox, managed by ArgoCD.

## Hardware

| Machine | Role | Specs |
|---------|------|-------|
| **GMKtec NucBox G3 Plus** | K3s node (primary) | Intel N150, 16GB RAM, 2x 1TB SSD |
| **Dell T5810** | NAS / cold storage | Xeon E5-2630 v4, 256GB RAM, ~29TB ZFS |

### Storage layout

```
Proxmox host
└── /mnt/shared_data/
    ├── movies/          → media (arr-stack, plex, jellyfin)
    ├── paperless/       → documents (paperless-ngx)
    │   ├── data/
    │   ├── media/
    │   ├── consume/
    │   └── export/
    └── backups/         → local backups (pg_dump, etc.)

Dell T5810 (ZFS NAS — Wake-on-LAN)
└── /data/
    ├── media/           → 12TB media archive
    ├── backup/          → cold backups
    └── coffre_fort/     → important documents archive
```

## Architecture

```
                    ┌─────────────────────────────────┐
                    │         ArgoCD (GitOps)          │
                    │   watches: github.com/fabsys/... │
                    └────────────────┬────────────────┘
                                     │ sync
                    ┌────────────────▼────────────────┐
                    │           K3s cluster            │
                    │                                  │
                    │  Ingress (private) 192.168.1.251 │
                    │  Ingress (public)  192.168.1.250 │
                    │  MetalLB L2        192.168.1.250-253│
                    └──────────────────────────────────┘
```

### Dual ingress

| Class | IP | Access | Usage |
|-------|----|--------|-------|
| `nginx-private` | 192.168.1.251 | LAN only (`192.168.1.0/24`) | Internal services (`*.services.k8s`) |
| `nginx-public` | 192.168.1.250 | Internet | Public services (`*.fabsys.ovh`) |

## Applications

### System

| App | Namespace | Description |
|-----|-----------|-------------|
| metallb | metallb-system | LoadBalancer IPs via L2 |
| ingress-nginx-private | ingress-nginx-private | Internal ingress |
| ingress-nginx-public | ingress-nginx-public | Public ingress |
| cert-manager | cert-manager | TLS (Let's Encrypt) |
| sealed-secrets | kube-system | Encrypted secrets for GitOps |
| external-dns | external-dns | Cloudflare DNS sync |
| kured | kured | Automatic node reboots |
| system-upgrade-controller | cattle-system | K3s upgrades |
| volsync | volsync-system | Volume backup/replication |
| renovate | renovate | Automated dependency updates |

### Applications

| App | URL | Description |
|-----|-----|-------------|
| ArgoCD | argocd.services.k8s | GitOps controller |
| Homepage | homepage.services.k8s | Dashboard |
| Jellyfin | jellyfin.fabsys.ovh | Media server (VAAPI transcoding) |
| Jellyseerr | jellyseerr.fabsys.ovh | Media requests |
| Radarr | radarr.services.k8s | Movie automation |
| Sonarr | sonarr.services.k8s | TV series automation |
| Prowlarr | prowlarr.services.k8s | Indexer aggregator |
| qBittorrent | qbittorrent.services.k8s | Torrent client (via VPN) |
| Gluetun | — | VPN gateway (CyberGhost) |
| Paperless-ngx | paperless.services.k8s | Document management |
| Syncthing | syncthing.services.k8s | File synchronization |
| Filebrowser | filebrowser.services.k8s | Web file manager |

---

## Prerequisites

- Proxmox VE with a K3s VM
- `kubectl` configured to reach the cluster
- `helm` >= 3.x
- `kubeseal` (for SealedSecrets)

> **Proxmox VM tip:** Disable memory ballooning on the K3s VM to prevent kernel OOM issues.
> ```bash
> qm set <VMID> --balloon 0 --memory 13312
> ```

---

## Bootstrap

This is a **one-time** operation on a fresh cluster. After this, ArgoCD manages everything — including itself.

### 1. Install ArgoCD (initial bootstrap only)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm dependency build cluster/argocd/
helm upgrade --install argocd cluster/argocd/ \
  --namespace=argocd --create-namespace --wait
```

### 2. Register the root Application (app-of-apps)

```bash
kubectl apply -f cluster/root-app.yaml
```

This single command connects ArgoCD to the git repository. ArgoCD will then automatically sync and deploy **all** applications defined in `cluster/argocd-apps/values.yaml`, including ArgoCD itself.

### How self-management works

```
cluster/root-app.yaml        ← applied once manually (bootstrap)
    └── cluster/argocd-apps/ ← app-of-apps, watched by ArgoCD
            ├── argocd        → cluster/argocd/       ← ArgoCD manages itself
            ├── metallb       → cluster/apps/system/metallb/
            ├── cert-manager  → cluster/apps/system/cert-manager/
            └── ...           → all other apps
```

From this point on, any change pushed to `main` is automatically applied by ArgoCD. To upgrade ArgoCD itself, simply update the chart version in `cluster/argocd/Chart.yaml` and push.

---

## Secrets management

All secrets are encrypted using [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) before being committed to git.

### Generic secret

```bash
kubectl create secret generic <secret-name> \
  --from-literal=KEY='value' \
  --from-literal=OTHER_KEY='value' \
  -n <namespace> --dry-run=client -o yaml \
  | kubeseal -o yaml -n <namespace> \
  > cluster/apps/<app>/secret.yaml
```

### Secret from file

```bash
kubectl create secret generic <secret-name> \
  --from-file=config.conf=/path/to/file \
  -n <namespace> --dry-run=client -o yaml \
  | kubeseal -o yaml -n <namespace> \
  > cluster/apps/<app>/secret.yaml
```

### Application-specific secrets

#### external-dns (Cloudflare)
```bash
kubectl create secret generic cloudflare-api-key \
  --from-literal=apiKey='YOUR_CLOUDFLARE_API_TOKEN' \
  -n external-dns --dry-run=client -o yaml \
  | kubeseal -o yaml -n external-dns \
  > cluster/apps/system/external-dns/templates/cloudflare-api-key.yaml
```

#### Gluetun (VPN)
```bash
kubectl create secret generic vpn-sensitive-data \
  --from-literal=OPENVPN_USER='your_vpn_user' \
  --from-literal=OPENVPN_PASSWORD='your_vpn_password' \
  --from-file=ca.crt=/path/to/ca.crt \
  --from-file=client.crt=/path/to/client.crt \
  --from-file=client.key=/path/to/client.key \
  -n gluetun --dry-run=client -o yaml \
  | kubeseal -o yaml -n gluetun \
  > cluster/apps/gluetun/secrets.yaml
```

#### Paperless-ngx
```bash
# Generate a strong secret key
SECRET_KEY=$(openssl rand -hex 32)

kubectl create secret generic paperless-secret \
  --from-literal=PAPERLESS_DBPASS='your_db_password' \
  --from-literal=PAPERLESS_SECRET_KEY="$SECRET_KEY" \
  --from-literal=PAPERLESS_ADMIN_PASSWORD='your_admin_password' \
  -n paperless --dry-run=client -o yaml \
  | kubeseal -o yaml -n paperless \
  > cluster/apps/paperless/secret.yaml
```

#### Paperless backup (rclone + restic)
```bash
# rclone config (Google Drive token)
# First configure rclone locally: rclone config
kubectl create secret generic rclone-config \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf \
  -n paperless --dry-run=client -o yaml \
  | kubeseal -o yaml -n paperless \
  > cluster/apps/paperless/rclone-secret.yaml

# restic encryption password — KEEP THIS SAFE, without it backups are unrecoverable
kubectl create secret generic restic-secret \
  --from-literal=RESTIC_PASSWORD='your_strong_restic_password' \
  -n paperless --dry-run=client -o yaml \
  | kubeseal -o yaml -n paperless \
  > cluster/apps/paperless/restic-secret.yaml
```

---

## Paperless-ngx

Document management system with PostgreSQL backend.

### Stack

```
paperless-ngx   → Django app (port 8000)
postgresql      → Database (port 5432)
redis           → Task broker (port 6379)
```

### Storage (hostPath)

| Path on host | Mount in container | Purpose |
|---|---|---|
| `/mnt/shared_data/paperless/data` | `/usr/src/paperless/data` | Index, scheduler DB |
| `/mnt/shared_data/paperless/media` | `/usr/src/paperless/media` | Processed documents |
| `/mnt/shared_data/paperless/consume` | `/usr/src/paperless/consume` | Auto-import inbox |
| `/mnt/shared_data/paperless/export` | `/usr/src/paperless/export` | Exports |

> Create directories before first deployment:
> ```bash
> mkdir -p /mnt/shared_data/paperless/{data,media,consume,export}
> chown -R 1000:1000 /mnt/shared_data/paperless/
> ```

### Migrate from LXC

```bash
# 1. On the source LXC — dump the database
sudo -u postgres pg_dump paperlessdb > /root/paperless_backup.sql

# 2. Transfer to K3s node
scp /root/paperless_backup.sql ansible@k3s-node:/mnt/shared_data/paperless/

# 3. Once pods are running — import the database
kubectl exec -n paperless deploy/paperless-postgres -- \
  psql -U paperless paperlessdb < /mnt/shared_data/paperless/paperless_backup.sql

# 4. Re-import documents from originals (if DB was empty)
# Enable dedup first to avoid duplicates
# Set PAPERLESS_CONSUMER_DELETE_DUPLICATES: "true" in configmap, then:
cp /mnt/shared_data/paperless/media/documents/originals/*.pdf \
   /mnt/shared_data/paperless/consume/
```

### Backup

Daily backup at 03:00 via CronJob (`cluster/apps/paperless/backup-cronjob.yaml`):

- **PostgreSQL dump** → encrypted with restic → Google Drive (`k3s-backups/paperless/`)
- **PDF documents** → encrypted with restic → Google Drive (`k3s-backups/paperless/`)
- Retention: **7 daily snapshots**

```bash
# Trigger backup manually
kubectl create job -n paperless --from=cronjob/paperless-backup paperless-backup-manual

# List snapshots on Google Drive
kubectl run restic-check --rm -it --restart=Never \
  --image=alpine \
  --env="RESTIC_REPOSITORY=rclone:googledrive:k3s-backups/paperless" \
  --env="RESTIC_PASSWORD=your_restic_password" \
  -- sh -c "apk add restic rclone && restic snapshots"

# Restore latest backup
restic -r rclone:googledrive:k3s-backups/paperless restore latest --target /tmp/restore
```

---

## Backup strategy

| Data | Method | Destination | Retention |
|------|--------|-------------|-----------|
| Paperless DB | pg_dump + restic | Google Drive | 7 days |
| Paperless PDFs | restic | Google Drive | 7 days |
| T5810 NAS | ZFS snapshots | Local (T5810) | Manual |
| K3s cluster state | etcd snapshots (planned) | `/mnt/shared_data/backups/` | — |

---

## Proxmox tips

### Disable memory ballooning (prevents K3s OOM)

```bash
# On Proxmox host
qm set <VMID> --balloon 0 --memory 13312   # 13GB fixed
qm config <VMID> | grep -E "memory|balloon"
```

### Verify in the VM

```bash
# Should not show "Out of puff" messages
dmesg | grep balloon
```

---

## Repository structure

```
cluster/
├── argocd/              # ArgoCD Helm chart
├── argocd-apps/         # App-of-apps (registers all applications)
│   └── values.yaml      # Enable/disable apps here
├── root-app.yaml        # Bootstrap entry point
└── apps/
    ├── system/          # Infrastructure components
    │   ├── metallb/
    │   ├── ingress-nginx-private/
    │   ├── ingress-nginx-public/
    │   ├── cert-manager/
    │   ├── sealed-secrets/
    │   ├── external-dns/
    │   ├── kured/
    │   ├── volsync/     # Volume backup operator (t5810.enabled: false by default)
    │   └── velero/      # Disabled (replaced by restic+rclone)
    ├── arr-stack/       # Jellyfin, Radarr, Sonarr, Prowlarr, qBittorrent, Jellyseerr
    ├── paperless/       # Document management
    ├── gluetun/         # VPN gateway
    ├── syncthing/       # File sync
    ├── homepage/        # Dashboard
    └── ...
```
