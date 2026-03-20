#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Bootstrap k3s homelab — Proxmox + Ansible (Tofu/Terraform)
#
# Usage:
#   ./provision.sh            → mode interactif complet
#   ./provision.sh --k3s      → déploie uniquement le cluster K3s
#   ./provision.sh --media    → déploie uniquement le Media Center
#   ./provision.sh --all      → déploie K3s + Media Center
#   ./provision.sh --ansible  → relance uniquement Ansible (sans Tofu)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
CACHE_FILE="$SCRIPT_DIR/.provision.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Parsing des arguments ---
MODE_K3S=false
MODE_MEDIA=false
SKIP_TOFU=false

parse_args() {
  if [[ $# -eq 0 ]]; then
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}   Homelab Provisioner — Que voulez-vous déployer ?${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "  ${GREEN}1)${NC} --k3s     Cluster K3s uniquement"
    echo -e "  ${GREEN}2)${NC} --media   Media Center (Kodi + RetroArch) uniquement"
    echo -e "  ${GREEN}3)${NC} --all     K3s + Media Center"
    echo -e "  ${GREEN}4)${NC} --ansible Rejouer Ansible sans recréer l'infra"
    echo -e "  ${GREEN}5)${NC} Quitter"
    echo
    read -rp "Choix [1-5] : " choice
    case "$choice" in
      1) MODE_K3S=true ;;
      2) MODE_MEDIA=true ;;
      3) MODE_K3S=true; MODE_MEDIA=true ;;
      4) MODE_K3S=true; MODE_MEDIA=true; SKIP_TOFU=true ;;
      5) echo "Annulé."; exit 0 ;;
      *) error "Choix invalide. Utilisez --help pour l'aide." ;;
    esac
    return
  fi
  for arg in "$@"; do
    case "$arg" in
      --k3s)     MODE_K3S=true ;;
      --media)   MODE_MEDIA=true ;;
      --all)     MODE_K3S=true; MODE_MEDIA=true ;;
      --ansible) MODE_K3S=true; MODE_MEDIA=true; SKIP_TOFU=true ;;
      --help|-h)
        echo "Usage: $0 [--k3s] [--media] [--all] [--ansible]"
        echo "  (aucun arg)  Mode interactif complet"
        echo "  --k3s        Déploie uniquement le cluster K3s"
        echo "  --media      Déploie uniquement le Media Center"
        echo "  --all        Déploie K3s + Media Center"
        echo "  --ansible    Relance uniquement Ansible (sans Tofu)"
        exit 0
        ;;
      *) error "Argument inconnu : $arg. Utilisez --help pour l'aide." ;;
    esac
  done
}

# Détection de l'outil IaC (OpenTofu ou Terraform)
TF_BIN=""
if command -v tofu &>/dev/null; then
  TF_BIN="tofu"
elif command -v terraform &>/dev/null; then
  TF_BIN="terraform"
fi

ask() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local secret="${4:-false}"

  local cached="${!var_name:-}"
  local effective_default="${cached:-$default}"

  if [[ -n "$effective_default" ]]; then
    if [[ "$secret" == "true" ]]; then
      prompt="$prompt [****]"
    else
      prompt="$prompt [${effective_default}]"
    fi
  fi

  if [[ "$secret" == "true" ]]; then
    read -rsp "$prompt : " value || echo
    echo
  else
    read -rp "$prompt : " value || echo
  fi

  value="${value:-$effective_default}"
  if [[ -z "$value" ]]; then
    error "La valeur '$var_name' est obligatoire."
  fi
  printf -v "$var_name" '%s' "$value"
}

load_cache() {
  if [[ -f "$CACHE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CACHE_FILE"
    info "Config précédente chargée depuis .provision.env"
  fi
}

save_cache() {
  cat > "$CACHE_FILE" <<EOF
PROXMOX_ENDPOINT="${PROXMOX_ENDPOINT:-}"
PROXMOX_USER="${PROXMOX_USER:-}"
PROXMOX_NODE="${PROXMOX_NODE:-}"
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-}"
K3S_CNI="${K3S_CNI:-}"
GPU_TYPE="${GPU_TYPE:-}"
DEPLOY_MEDIA="${DEPLOY_MEDIA:-false}"
VM_ID="${VM_ID:-}"
LXC_ID="${LXC_ID:-}"
VM_IP="${VM_IP:-}"
VM_GATEWAY="${VM_GATEWAY:-}"
NETWORK_VLAN="${NETWORK_VLAN:-}"
MEDIA_LXC_ID="${MEDIA_LXC_ID:-301}"
MEDIA_LXC_IP="${MEDIA_LXC_IP:-192.168.1.101/24}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
EOF
  chmod 600 "$CACHE_FILE"
}

check_prerequisites() {
  info "Vérification des prérequis..."
  local missing=()
  
  if [[ -z "$TF_BIN" ]]; then
    missing+=("opentofu ou terraform")
  fi
  command -v ansible-playbook &>/dev/null || missing+=("ansible")
  command -v ssh        &>/dev/null || missing+=("ssh")
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Outils manquants : ${missing[*]}"
  fi
  success "Prérequis OK (Utilisation de : $TF_BIN)"
}

collect_inputs() {
  load_cache
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${CYAN}   Configuration du cluster k3s (Hybride VM/LXC)${NC}"
  echo -e "${CYAN}============================================================${NC}"

  echo -e "${YELLOW}--- Proxmox ---${NC}"
  ask PROXMOX_ENDPOINT    "URL API Proxmox"              "https://192.168.1.10:8006"
  ask PROXMOX_USER        "Utilisateur Proxmox"          "root@pam"
  ask PROXMOX_NODE        "Nom du nœud Proxmox"          "pve"
  echo -n "Mot de passe Proxmox : "
  read -rsp "" PROXMOX_PASSWORD; echo

  echo -e "${YELLOW}--- Sécurité ---${NC}"
  echo -n "Mot de passe console/root (accès urgence) : "
  read -rsp "" VM_CONSOLE_PASSWORD; echo

  echo -e "${YELLOW}--- SSH ---${NC}"
  local default_key=""
  for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [[ -f "$key_file" ]]; then
      default_key=$(cat "$key_file")
      break
    fi
  done
  ask SSH_PUBLIC_KEY    "Clé SSH publique" "$default_key"

  if [[ "$MODE_K3S" == "true" ]]; then
    echo -e "${YELLOW}--- K3s ---${NC}"
    ask DEPLOYMENT_TYPE     "Type de déploiement (vm/lxc)" "lxc"
    ask K3S_CNI             "CNI (cilium/calico)"          "calico"
    ask GPU_TYPE            "Type de GPU (intel/amd)"      "amd"
    if [[ "$DEPLOYMENT_TYPE" == "vm" ]]; then
      ask VM_ID             "ID de la VM"                  "200"
    else
      ask LXC_ID            "ID du LXC k3s"               "300"
    fi
    ask VM_IP               "IP statique k3s (ex: 192.168.1.100/24)"
    ask VM_GATEWAY          "Passerelle"                   "192.168.1.1"
    ask NETWORK_VLAN        "Tag VLAN (0=aucun)"           "0"
  fi

  if [[ "$MODE_MEDIA" == "true" ]]; then
    echo -e "${YELLOW}--- Media Center ---${NC}"
    ask MEDIA_LXC_ID        "ID du LXC Media Center"      "301"
    ask MEDIA_LXC_IP        "IP statique Media (ex: 192.168.1.101/24)" "192.168.1.101/24"
    [[ -z "${VM_GATEWAY:-}" ]] && ask VM_GATEWAY "Passerelle" "192.168.1.1"
  fi

  DEPLOY_MEDIA="$MODE_MEDIA"
  VM_IP_ONLY="${VM_IP%%/*}"
  MEDIA_LXC_IP_ONLY="${MEDIA_LXC_IP%%/*}"
  save_cache
}

generate_configs() {
  info "Génération de ${TF_BIN}.tfvars..."
  cat > "$TERRAFORM_DIR/terraform.tfvars" <<EOF
proxmox_endpoint    = "$PROXMOX_ENDPOINT"
proxmox_username    = "$PROXMOX_USER"
proxmox_password    = "$PROXMOX_PASSWORD"
vm_console_password = "$VM_CONSOLE_PASSWORD"
proxmox_node        = "$PROXMOX_NODE"
deployment_type     = "$DEPLOYMENT_TYPE"

vm_id               = ${VM_ID:-200}
lxc_id              = ${LXC_ID:-300}
vm_ip               = "$VM_IP"
vm_gateway          = "$VM_GATEWAY"
network_vlan        = $NETWORK_VLAN

deploy_media        = ${DEPLOY_MEDIA:-false}
media_lxc_id        = ${MEDIA_LXC_ID:-301}
media_lxc_ip        = "${MEDIA_LXC_IP:-192.168.1.101/24}"

ssh_public_key      = "$SSH_PUBLIC_KEY"
EOF

  info "Génération de inventory.ini..."
  # Extraction de l'IP du PVE depuis l'URL (ex: https://192.168.1.98:8006 -> 192.168.1.98)
  PVE_IP_ONLY=$(echo "$PROXMOX_ENDPOINT" | grep -oP '(?<=//)[^:/]+')

  cat > "$ANSIBLE_DIR/inventory.ini" <<EOF
[pve]
proxmox ansible_host=$PVE_IP_ONLY ansible_user=root ansible_ssh_pass=$PROXMOX_PASSWORD

[k3s]
k3s-control ansible_host=${VM_IP_ONLY:-} ansible_user=$( [[ "${DEPLOYMENT_TYPE:-lxc}" == "lxc" ]] && echo "root" || echo "ansible" ) ansible_become=true

[media]
$( [[ "$DEPLOY_MEDIA" == "true" ]] && echo "media-lxc ansible_host=$MEDIA_LXC_IP_ONLY ansible_user=root" )
EOF
}

run_iaas() {
  [[ "$SKIP_TOFU" == "true" ]] && { info "Tofu ignoré (--ansible)"; return; }
  info "Exécution de $TF_BIN..."
  cd "$TERRAFORM_DIR"
  "$TF_BIN" init -upgrade
  "$TF_BIN" apply -auto-approve
}

wait_for_ssh() {
  local ip="$1"
  info "Attente de la disponibilité SSH sur $ip..."
  local retries=30
  local count=0
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        root@"$ip" 'exit' 2>/dev/null || \
        ansible@"$ip" 'exit' 2>/dev/null; do
    count=$((count + 1))
    [[ $count -ge $retries ]] && error "SSH non disponible sur $ip."
    echo -n "."
    sleep 10
  done
  echo
}

run_ansible() {
  info "Lancement du playbook Ansible..."
  cd "$ANSIBLE_DIR"
  export ANSIBLE_HOST_KEY_CHECKING=False

  # Construire les --limit selon le mode
  local limit_hosts=""
  if [[ "$MODE_K3S" == "true" && "$MODE_MEDIA" == "true" ]]; then
    limit_hosts="all"
  elif [[ "$MODE_K3S" == "true" ]]; then
    limit_hosts="pve:k3s"
  elif [[ "$MODE_MEDIA" == "true" ]]; then
    limit_hosts="pve:media"
  fi

  ansible-playbook -i inventory.ini playbook.yml \
    --limit "$limit_hosts" \
    -e "k3s_target=${DEPLOYMENT_TYPE:-lxc}" \
    -e "k3s_cni=${K3S_CNI:-calico}" \
    -e "gpu_type=${GPU_TYPE:-amd}" \
    -e "deploy_media=$DEPLOY_MEDIA" \
    -e "media_lxc_id=${MEDIA_LXC_ID:-301}"
}


# --- Main ---
parse_args "$@"
check_prerequisites
collect_inputs
generate_configs
run_iaas

[[ "$MODE_K3S"    == "true" ]] && wait_for_ssh "${VM_IP_ONLY:-}"
[[ "$MODE_MEDIA"  == "true" ]] && wait_for_ssh "${MEDIA_LXC_IP_ONLY:-}"

run_ansible

echo -e "${GREEN}Déploiement terminé !${NC}"
[[ "$MODE_K3S"   == "true" ]] && echo -e "  K3s    → ${CYAN}${VM_IP_ONLY:-}${NC} (mode ${DEPLOYMENT_TYPE:-lxc}, CNI: ${K3S_CNI:-calico})"
[[ "$MODE_MEDIA" == "true" ]] && echo -e "  Media  → ${CYAN}${MEDIA_LXC_IP_ONLY:-}${NC} (Kodi + RetroArch)"
