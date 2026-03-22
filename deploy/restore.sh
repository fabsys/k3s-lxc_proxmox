#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# restore.sh — Restauration des backups restic depuis Google Drive
# Namespaces supportés : arr-stack, syncthing, paperless
# ============================================================

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

# ---- couleurs ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- prérequis ----
command -v kubectl &>/dev/null || error "kubectl non trouvé"

# ---- ArgoCD auto-sync control ----
disable_argocd_sync() {
  local app="$1"
  info "Désactivation auto-sync ArgoCD pour $app..."
  kubectl patch application root-app -n argocd --type=json \
    -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true
  kubectl patch application "$app" -n argocd --type=json \
    -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true
}

enable_argocd_sync() {
  local app="$1"
  info "Réactivation auto-sync ArgoCD pour $app..."
  kubectl patch application "$app" -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
  kubectl patch application root-app -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
}

# ---- menu ----
echo ""
echo "================================================"
echo " Restauration des backups restic -> Google Drive"
echo "================================================"
echo ""
echo "Quel namespace restaurer ?"
echo "  1) arr-stack  (Radarr, Sonarr, Prowlarr, Jellyfin, Jellyseerr)"
echo "  2) syncthing"
echo "  3) paperless  (dump SQL + media)"
echo "  4) Tout restaurer"
echo ""
read -rp "Choix [1-4] : " CHOICE

case "$CHOICE" in
  1) NAMESPACES=("arr-stack") ;;
  2) NAMESPACES=("syncthing") ;;
  3) NAMESPACES=("paperless") ;;
  4) NAMESPACES=("arr-stack" "syncthing" "paperless") ;;
  *) error "Choix invalide" ;;
esac

# ---- fonction : attendre qu'un job se termine ----
wait_job() {
  local ns="$1" job="$2"
  info "Attente du job $job dans $ns..."
  kubectl wait job/"$job" -n "$ns" --for=condition=complete --timeout=30m 2>/dev/null \
    || { kubectl logs job/"$job" -n "$ns" --tail=50; error "Job $job échoué"; }
  success "Job $job terminé"
}

# ---- fonction : supprimer un job s'il existe ----
cleanup_job() {
  local ns="$1" job="$2"
  kubectl delete job "$job" -n "$ns" --ignore-not-found=true
}

# ============================================================
# ARR-STACK
# ============================================================
restore_arr_stack() {
  info "=== Restauration arr-stack ==="

  # Vérifier les secrets
  kubectl get secret restic-secret -n arr-stack &>/dev/null   || error "Secret restic-secret introuvable dans arr-stack"
  kubectl get secret rclone-config -n arr-stack &>/dev/null   || error "Secret rclone-config introuvable dans arr-stack"

  disable_argocd_sync arr-stack

  warn "Scale down des deployments arr-stack..."
  for dep in radarr sonarr prowlarr jellyfin jellyseerr joal qbittorrent; do
    kubectl scale deployment "$dep" -n arr-stack --replicas=0 2>/dev/null || true
  done
  sleep 5
  kubectl wait pod -n arr-stack -l "app in (radarr,sonarr,prowlarr,jellyfin,jellyseerr,joal,qbittorrent)" --for=delete --timeout=120s 2>/dev/null || true

  cleanup_job arr-stack arr-stack-restore

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: arr-stack-restore
  namespace: arr-stack
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restic-restore
          image: alpine:3.23
          env:
            - name: RESTIC_REPOSITORY
              value: "rclone:gdrive:k3s-backups/arr-stack"
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: restic-secret
                  key: RESTIC_PASSWORD
            - name: RCLONE_CONFIG
              value: /tmp/rclone.conf
          command:
            - /bin/sh
            - -c
            - |
              set -e
              apk add --no-cache restic rclone
              cp /rclone/rclone.conf /tmp/rclone.conf

              echo "Nettoyage des PVCs..."
              for d in radarr sonarr prowlarr jellyfin jellyseerr; do
                rm -rf /data/\$d/* /data/\$d/.[!.]* 2>/dev/null || true
              done

              restic unlock --remove-all 2>/dev/null || true

              echo "=== Restauration Radarr ==="
              restic restore latest --tag radarr --target / --path /data/radarr

              echo "=== Restauration Sonarr ==="
              restic restore latest --tag sonarr --target / --path /data/sonarr

              echo "=== Restauration Prowlarr ==="
              restic restore latest --tag prowlarr --target / --path /data/prowlarr

              echo "=== Restauration Jellyfin ==="
              restic restore latest --tag jellyfin --target / --path /data/jellyfin

              echo "=== Restauration Jellyseerr ==="
              restic restore latest --tag jellyseerr --target / --path /data/jellyseerr

              echo "=== Tailles restaurées ==="
              du -sh /data/radarr /data/sonarr /data/prowlarr /data/jellyfin /data/jellyseerr
              echo "Restauration arr-stack terminee."
          volumeMounts:
            - name: radarr
              mountPath: /data/radarr
            - name: sonarr
              mountPath: /data/sonarr
            - name: prowlarr
              mountPath: /data/prowlarr
            - name: jellyfin
              mountPath: /data/jellyfin
            - name: jellyseerr
              mountPath: /data/jellyseerr
            - name: rclone-config
              mountPath: /rclone
              readOnly: true
      volumes:
        - name: radarr
          persistentVolumeClaim:
            claimName: radarr-pvc
        - name: sonarr
          persistentVolumeClaim:
            claimName: sonarr-pvc
        - name: prowlarr
          persistentVolumeClaim:
            claimName: prowlarr-pvc
        - name: jellyfin
          persistentVolumeClaim:
            claimName: jellyfin-pvc
        - name: jellyseerr
          persistentVolumeClaim:
            claimName: jellyseerr-pvc
        - name: rclone-config
          secret:
            secretName: rclone-config
            items:
              - key: rclone.conf
                path: rclone.conf
EOF

  wait_job arr-stack arr-stack-restore

  warn "Scale up des deployments arr-stack..."
  for dep in radarr sonarr prowlarr jellyfin jellyseerr joal qbittorrent; do
    kubectl scale deployment "$dep" -n arr-stack --replicas=1 2>/dev/null || true
  done
  enable_argocd_sync arr-stack
  success "arr-stack restauré et redémarré"
}

# ============================================================
# SYNCTHING
# ============================================================
restore_syncthing() {
  info "=== Restauration syncthing ==="

  kubectl get secret restic-secret -n syncthing &>/dev/null  || error "Secret restic-secret introuvable dans syncthing"
  kubectl get secret rclone-config -n syncthing &>/dev/null  || error "Secret rclone-config introuvable dans syncthing"

  disable_argocd_sync syncthing

  warn "Scale down du deployment syncthing..."
  kubectl scale deployment syncthing -n syncthing --replicas=0
  kubectl wait pod -n syncthing -l app=syncthing --for=delete --timeout=120s 2>/dev/null || true

  cleanup_job syncthing syncthing-restore

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: syncthing-restore
  namespace: syncthing
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restic-restore
          image: alpine:3.23
          env:
            - name: RESTIC_REPOSITORY
              value: "rclone:googledrive:k3s-backups/syncthing"
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: restic-secret
                  key: RESTIC_PASSWORD
            - name: RCLONE_CONFIG
              value: /tmp/rclone.conf
          command:
            - /bin/sh
            - -c
            - |
              set -e
              apk add --no-cache restic rclone
              cp /rclone/rclone.conf /tmp/rclone.conf

              echo "Nettoyage du PVC..."
              rm -rf /data/config/* /data/config/.[!.]* 2>/dev/null || true

              restic unlock --remove-all 2>/dev/null || true

              echo "=== Restauration Syncthing config ==="
              restic restore latest --target / --path /data/config

              echo "=== Taille restaurée ==="
              du -sh /data/config
              echo "Restauration syncthing terminee."
          volumeMounts:
            - name: syncthing-config
              mountPath: /data/config
            - name: rclone-config
              mountPath: /rclone
              readOnly: true
      volumes:
        - name: syncthing-config
          persistentVolumeClaim:
            claimName: syncthing-config-pvc
        - name: rclone-config
          secret:
            secretName: rclone-config
            items:
              - key: rclone.conf
                path: rclone.conf
EOF

  wait_job syncthing syncthing-restore

  warn "Scale up du deployment syncthing..."
  kubectl scale deployment syncthing -n syncthing --replicas=1
  enable_argocd_sync syncthing
  success "syncthing restauré et redémarré"
}

# ============================================================
# PAPERLESS
# ============================================================
restore_paperless() {
  info "=== Restauration paperless ==="

  kubectl get secret restic-secret -n paperless &>/dev/null   || error "Secret restic-secret introuvable dans paperless"
  kubectl get secret rclone-config -n paperless &>/dev/null   || error "Secret rclone-config introuvable dans paperless"
  kubectl get secret paperless-secret -n paperless &>/dev/null || error "Secret paperless-secret introuvable dans paperless (requis pour pg restore)"

  disable_argocd_sync paperless

  warn "Scale down paperless-ngx (postgres+redis restent up pour l'import SQL)..."
  kubectl scale deployment paperless-ngx -n paperless --replicas=0 2>/dev/null || true
  sleep 5
  kubectl wait pod -n paperless -l app=paperless-ngx --for=delete --timeout=120s 2>/dev/null || true

  cleanup_job paperless paperless-restore

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: paperless-restore
  namespace: paperless
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: restic-download
          image: alpine:3.23
          env:
            - name: RESTIC_REPOSITORY
              value: "rclone:googledrive:k3s-backups/paperless"
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: restic-secret
                  key: RESTIC_PASSWORD
            - name: RCLONE_CONFIG
              value: /tmp/rclone.conf
          command:
            - /bin/sh
            - -c
            - |
              set -e
              apk add --no-cache restic rclone
              cp /rclone/rclone.conf /tmp/rclone.conf

              restic unlock --remove-all 2>/dev/null || true

              echo "=== Restauration dump SQL ==="
              restic restore latest --target /restore --path /backup/

              echo "=== Restauration media/documents ==="
              restic restore latest --target /restore --path /media/documents/

              ls -lh /restore/backup/*.sql 2>/dev/null || echo "Aucun dump SQL trouvé"
              echo "Téléchargement terminé."
          volumeMounts:
            - name: restore-tmp
              mountPath: /restore
            - name: rclone-config
              mountPath: /rclone
              readOnly: true
      containers:
        - name: pg-restore
          image: postgres:18-alpine
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: paperless-secret
                  key: PAPERLESS_DBPASS
          command:
            - /bin/sh
            - -c
            - |
              set -e
              SQL_FILE=\$(ls /restore/backup/paperless-*.sql 2>/dev/null | sort | tail -1)
              if [ -z "\$SQL_FILE" ]; then
                echo "Aucun dump SQL trouvé dans /restore/backup/"
                exit 1
              fi
              echo "Restauration depuis : \$SQL_FILE"

              echo "Nettoyage de la base..."
              echo "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" | psql -h paperless-postgres -U paperless paperlessdb

              echo "Import du dump SQL..."
              psql -h paperless-postgres -U paperless paperlessdb < "\$SQL_FILE"

              echo "=== Vérification ==="
              echo "Documents:" && psql -h paperless-postgres -U paperless paperlessdb -t -c "SELECT count(*) FROM documents_document;"

              echo "Sync media..."
              cp -rn /restore/media/documents/* /media/documents/ 2>/dev/null || echo "Media déjà en place"
              echo "Restauration paperless terminée."
          volumeMounts:
            - name: restore-tmp
              mountPath: /restore
            - name: media
              mountPath: /media
      volumes:
        - name: restore-tmp
          emptyDir: {}
        - name: media
          hostPath:
            path: /mnt/data/paperless/media
            type: Directory
        - name: rclone-config
          secret:
            secretName: rclone-config
            items:
              - key: rclone.conf
                path: rclone.conf
EOF

  wait_job paperless paperless-restore

  warn "Scale up paperless-ngx..."
  kubectl scale deployment paperless-ngx -n paperless --replicas=1 2>/dev/null || true
  enable_argocd_sync paperless
  success "paperless restauré et redémarré"
}

# ============================================================
# EXECUTION
# ============================================================
for NS in "${NAMESPACES[@]}"; do
  case "$NS" in
    arr-stack)  restore_arr_stack ;;
    syncthing)  restore_syncthing ;;
    paperless)  restore_paperless ;;
  esac
done

echo ""
success "Restauration terminée."
