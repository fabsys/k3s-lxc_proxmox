# Disaster Recovery — k3s Homelab

Procédure complète de reconstruction du cluster depuis zéro.

## Prérequis sur le host Proxmox

### 1. Image Debian 13 (Trixie)

```bash
# Télécharger l'image cloud Debian 13
wget https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 \
  -O /var/lib/vz/template/iso/debian-13-genericcloud-amd64.img
```

### 2. Virtiofs — configurer les partages dans Proxmox

Dans l'interface Proxmox : Datacenter → Resource Mappings → Directory Mappings

Créer deux mappings :
- `movies` → `/mnt/ssd2-movies/movies`
- `paperless` → `/mnt/shared_data/paperless`

---

## Méthode rapide — Script interactif

```bash
cd deploy
./provision.sh
```

Le script demande toutes les informations nécessaires, génère les configs et enchaîne Terraform + Ansible automatiquement. Passe directement à l'**Étape 3** (secrets) une fois terminé.

---

## Méthode manuelle

### Étape 1 — Créer la VM avec Terraform

```bash
cd deploy/terraform

# Copier et adapter les variables
cp terraform.tfvars.sample terraform.tfvars
vim terraform.tfvars   # Renseigner IP, mot de passe Proxmox, clé SSH

terraform init
terraform plan
terraform apply
```

La VM démarre automatiquement avec cloud-init (utilisateur `ansible`, clé SSH).

---

## Étape 2 — Provisionner avec Ansible

```bash
cd deploy/ansible

# Adapter l'inventaire
cp inventory.ini.example inventory.ini
vim inventory.ini   # Renseigner l'IP de la VM

# Lancer le playbook complet
ansible-playbook -i inventory.ini playbook.yml
```

Le playbook installe dans l'ordre :
1. **base** — dépendances, virtiofs, sysctl
2. **k3s** — k3s v1.33 sans flannel, kubectl, helm, kubeseal
3. **cilium** — CNI Cilium
4. **argocd** — ArgoCD + bootstrap `root-app.yaml`

ArgoCD sync ensuite automatiquement toutes les apps depuis git.

---

## Étape 3 — Recréer les Secrets (SealedSecrets)

ArgoCD va déployer les apps mais elles resteront en attente des secrets.
Les recréer dans l'ordre suivant depuis le nœud k3s :

### sealed-secrets doit être Running en premier
```bash
kubectl wait pod -n kube-system -l app.kubernetes.io/name=sealed-secrets \
  --for=condition=Ready --timeout=120s
```

### cert-manager — Cloudflare DNS-01
```bash
TOKEN=$(kubectl get secret cloudflare-api-key -n external-dns \
  -o jsonpath='{.data.apiKey}' | base64 -d 2>/dev/null || echo "RENSEIGNER_MANUELLEMENT")

kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token="$TOKEN" \
  -n cert-manager --dry-run=client -o yaml \
  | kubeseal -o yaml -n cert-manager \
  > cluster/apps/system/cert-manager/templates/cloudflare-api-token.yaml
```

### external-dns — Cloudflare
```bash
kubectl create secret generic cloudflare-api-key \
  --from-literal=apiKey='TON_TOKEN_CLOUDFLARE' \
  -n external-dns --dry-run=client -o yaml \
  | kubeseal -o yaml -n external-dns \
  > cluster/apps/system/external-dns/templates/cloudflare-api-key.yaml
```

### Gluetun — VPN
```bash
kubectl create secret generic vpn-sensitive-data \
  --from-file=client.key=client.key \
  --from-file=client.crt=client.crt \
  --from-file=ca.crt=ca.crt \
  --from-literal=OPENVPN_USER='xxx' \
  --from-literal=OPENVPN_PASSWORD='xxx' \
  -n gluetun --dry-run=client -o yaml \
  | kubeseal -o yaml -n gluetun \
  > cluster/apps/gluetun/secrets.yaml
```

### Gluetun — Shadowsocks (même password dans arr-stack et gluetun)
```bash
SS_PASS=$(openssl rand -hex 16)
for NS in gluetun arr-stack; do
  kubectl create secret generic shadowsocks-config \
    --from-literal=password="$SS_PASS" \
    -n $NS --dry-run=client -o yaml \
    | kubeseal -o yaml -n $NS \
    > cluster/apps/$([ "$NS" = "gluetun" ] && echo "gluetun" || echo "arr-stack")/shadowsocks-secret.yaml
done
```

### qBittorrent — mot de passe WebUI
```bash
kubectl create secret generic qbittorrent-auth \
  --from-literal=password='HASH_QBITTORRENT' \
  -n arr-stack --dry-run=client -o yaml \
  | kubeseal -o yaml -n arr-stack \
  > cluster/apps/arr-stack/qBittorrent-WEBUI_PASS.yaml
```

### Paperless
```bash
SECRET_KEY=$(openssl rand -hex 32)
kubectl create secret generic paperless-secret \
  --from-literal=PAPERLESS_DBPASS='ton_db_password' \
  --from-literal=PAPERLESS_SECRET_KEY="$SECRET_KEY" \
  --from-literal=PAPERLESS_ADMIN_PASSWORD='ton_admin_password' \
  -n paperless --dry-run=client -o yaml \
  | kubeseal -o yaml -n paperless \
  > cluster/apps/paperless/secret.yaml
```

### Paperless — Backups (rclone + restic)
```bash
kubectl create secret generic rclone-config \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf \
  -n paperless --dry-run=client -o yaml \
  | kubeseal -o yaml -n paperless \
  > cluster/apps/paperless/rclone-secret.yaml

kubectl create secret generic restic-secret \
  --from-literal=RESTIC_PASSWORD='ton_restic_password' \
  -n paperless --dry-run=client -o yaml \
  | kubeseal -o yaml -n paperless \
  > cluster/apps/paperless/restic-secret.yaml
```

### arr-stack — Backups (même rclone.conf, restic password différent)
```bash
kubectl create secret generic rclone-config \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf \
  -n arr-stack --dry-run=client -o yaml \
  | kubeseal -o yaml -n arr-stack \
  > cluster/apps/arr-stack/backup-rclone-secret.yaml

kubectl create secret generic restic-secret \
  --from-literal=RESTIC_PASSWORD='ton_restic_password_arr' \
  -n arr-stack --dry-run=client -o yaml \
  | kubeseal -o yaml -n arr-stack \
  > cluster/apps/arr-stack/backup-restic-secret.yaml
```

### Syncthing — Backups
```bash
kubectl create secret generic rclone-config \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf \
  -n syncthing --dry-run=client -o yaml \
  | kubeseal -o yaml -n syncthing \
  > cluster/apps/syncthing/backup-rclone-secret.yaml

kubectl create secret generic restic-secret \
  --from-literal=RESTIC_PASSWORD='ton_restic_password_syncthing' \
  -n syncthing --dry-run=client -o yaml \
  | kubeseal -o yaml -n syncthing \
  > cluster/apps/syncthing/backup-restic-secret.yaml
```

Commit et push tous les secrets regénérés, puis sync ArgoCD.

---

## Étape 4 — Restauration Paperless depuis Google Drive

Si le CronJob de backup avait tourné au moins une fois :

```bash
# Vérifier les snapshots disponibles sur Google Drive
kubectl run restic-check --rm -it --restart=Never \
  --image=alpine \
  --env="RESTIC_REPOSITORY=rclone:googledrive:k3s-backups/paperless" \
  --env="RESTIC_PASSWORD=ton_restic_password" \
  -- sh -c "apk add restic rclone && restic snapshots"

# Restaurer le dernier dump SQL
kubectl run restic-restore --rm -it --restart=Never \
  --image=alpine \
  --env="RESTIC_REPOSITORY=rclone:googledrive:k3s-backups/paperless" \
  --env="RESTIC_PASSWORD=ton_restic_password" \
  -- sh -c "
    apk add restic rclone
    mkdir /restore
    restic restore latest --target /restore
    ls /restore
  "

# Importer le dump dans postgres
kubectl exec -i -n paperless deploy/paperless-postgres -- \
  psql -U paperless paperlessdb < /chemin/vers/paperless-backup.sql
```

---

## Étape 5 — Restauration PVCs arr-stack depuis Google Drive

Si le CronJob arr-stack-backup avait tourné :

```bash
# Lister les snapshots
kubectl run restic-check --rm -it --restart=Never \
  --image=alpine \
  --env="RESTIC_REPOSITORY=rclone:googledrive:k3s-backups/arr-stack" \
  --env="RESTIC_PASSWORD=ton_restic_password_arr" \
  -- sh -c "apk add restic rclone && restic snapshots"

# Restaurer une app spécifique (ex: Radarr)
# Les données sont dans le PVC — monter un pod de restauration
kubectl run restic-restore --rm -it --restart=Never \
  --image=alpine \
  --env="RESTIC_REPOSITORY=rclone:googledrive:k3s-backups/arr-stack" \
  --env="RESTIC_PASSWORD=ton_restic_password_arr" \
  -- sh -c "
    apk add restic rclone
    restic restore latest --tag radarr --target /restore
  "
```

> Si les CronJobs de backup arr-stack n'avaient pas encore tourné (cluster tout neuf),
> les configs Radarr/Sonarr/Prowlarr sont à reconfigurer manuellement.

---

## Checklist finale

- [ ] VM créée et accessible SSH
- [ ] k3s Running, node Ready
- [ ] Cilium pods Running
- [ ] ArgoCD synced
- [ ] Sealed-secrets controller Running
- [ ] Tous les secrets recréés et pushés
- [ ] MetalLB IPs 192.168.1.250-253 opérationnelles
- [ ] Ingress nginx-private (192.168.1.251) et nginx-public (192.168.1.250) Running
- [ ] cert-manager — certificats émis
- [ ] Paperless accessible sur paperless.int.fabsys.ovh
- [ ] Jellyfin accessible, VAAPI fonctionnel
- [ ] qBittorrent — VPN actif (vérifier l'IP via gluetun)
