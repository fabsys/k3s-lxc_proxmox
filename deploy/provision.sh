#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Bootstrap k3s homelab — Proxmox + Ansible
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

ask() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local secret="${4:-false}"

  # Priorité : valeur déjà en cache > default passé en argument
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
    read -rsp "$prompt : " value
    echo
  else
    read -rp "$prompt : " value
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
    info "Config précédente chargée depuis .provision.env (Entrée pour garder, ou nouvelle valeur)"
  fi
}

save_cache() {
  cat > "$CACHE_FILE" <<EOF
PROXMOX_ENDPOINT="$PROXMOX_ENDPOINT"
PROXMOX_USER="$PROXMOX_USER"
PROXMOX_NODE="$PROXMOX_NODE"
VM_ID="$VM_ID"
VM_IP="$VM_IP"
VM_GATEWAY="$VM_GATEWAY"
SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY"
DEBIAN_IMAGE_ID="$DEBIAN_IMAGE_ID"
EOF
  # Le mot de passe n'est PAS mis en cache
  chmod 600 "$CACHE_FILE"
}

# ============================================================
# Vérification des prérequis
# ============================================================
check_prerequisites() {
  info "Vérification des prérequis..."
  local missing=()

  command -v terraform  &>/dev/null || missing+=("terraform")
  command -v ansible-playbook &>/dev/null || missing+=("ansible")
  command -v ssh        &>/dev/null || missing+=("ssh")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Outils manquants : ${missing[*]}\nInstalle-les et relance le script."
  fi
  success "Prérequis OK"
}

# ============================================================
# Collecte des informations
# ============================================================
collect_inputs() {
  load_cache
  echo
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${CYAN}   Configuration du cluster k3s${NC}"
  echo -e "${CYAN}============================================================${NC}"
  echo

  echo -e "${YELLOW}--- Proxmox ---${NC}"
  ask PROXMOX_ENDPOINT  "URL API Proxmox"          "https://192.168.1.10:8006"
  ask PROXMOX_USER      "Utilisateur Proxmox"       "root@pam"
  ask PROXMOX_PASSWORD  "Mot de passe Proxmox"      "" "true"
  ask PROXMOX_NODE      "Nom du nœud Proxmox"       "pve"

  echo
  echo -e "${YELLOW}--- VM ---${NC}"
  ask VM_ID             "ID de la VM"               "200"
  ask VM_IP             "IP statique de la VM (ex: 192.168.1.100/24)"
  ask VM_GATEWAY        "Passerelle"                "192.168.1.1"

  echo
  echo -e "${YELLOW}--- SSH ---${NC}"
  # Cherche une clé SSH existante
  local default_key=""
  for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [[ -f "$key_file" ]]; then
      default_key=$(cat "$key_file")
      info "Clé SSH trouvée : $key_file"
      break
    fi
  done
  ask SSH_PUBLIC_KEY    "Clé SSH publique" "$default_key"

  echo
  echo -e "${YELLOW}--- Image Debian ---${NC}"
  ask DEBIAN_IMAGE_ID   "ID image Debian 13 dans Proxmox" "local:iso/debian-13-genericcloud-amd64.img"

  # IP sans le masque pour Ansible
  VM_IP_ONLY="${VM_IP%%/*}"

  save_cache
}

# ============================================================
# Génération des fichiers de config
# ============================================================
generate_configs() {
  info "Génération de terraform.tfvars..."
  cat > "$TERRAFORM_DIR/terraform.tfvars" <<EOF
proxmox_endpoint = "$PROXMOX_ENDPOINT"
proxmox_username = "$PROXMOX_USER"
proxmox_password = "$PROXMOX_PASSWORD"
proxmox_node     = "$PROXMOX_NODE"

vm_id      = $VM_ID
vm_ip      = "$VM_IP"
vm_gateway = "$VM_GATEWAY"

ssh_public_key  = "$SSH_PUBLIC_KEY"
debian_image_id = "$DEBIAN_IMAGE_ID"
EOF
  success "terraform.tfvars généré"

  info "Génération de inventory.ini..."
  cat > "$ANSIBLE_DIR/inventory.ini" <<EOF
[k3s]
k3s-control ansible_host=$VM_IP_ONLY ansible_user=ansible ansible_become=true
EOF
  success "inventory.ini généré"
}

# ============================================================
# Terraform
# ============================================================
run_terraform() {
  info "Initialisation Terraform..."
  cd "$TERRAFORM_DIR"
  terraform init -upgrade

  info "Plan Terraform..."
  terraform plan

  echo
  read -rp "Appliquer le plan ? [y/N] : " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || error "Annulé."

  info "Application Terraform..."
  terraform apply -auto-approve
  success "VM créée"
}

# ============================================================
# Attente SSH
# ============================================================
wait_for_ssh() {
  info "Attente de la disponibilité SSH sur $VM_IP_ONLY..."
  local retries=30
  local count=0
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        ansible@"$VM_IP_ONLY" 'exit' 2>/dev/null; do
    count=$((count + 1))
    if [[ $count -ge $retries ]]; then
      error "SSH non disponible après ${retries} tentatives. Vérifie la VM."
    fi
    echo -n "."
    sleep 10
  done
  echo
  success "SSH disponible"
}

# ============================================================
# Ansible
# ============================================================
run_ansible() {
  info "Lancement du playbook Ansible..."
  cd "$ANSIBLE_DIR"
  ansible-playbook -i inventory.ini playbook.yml
  success "Provisionnement terminé"
}

# ============================================================
# Résumé final
# ============================================================
print_summary() {
  echo
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}   Cluster prêt !${NC}"
  echo -e "${GREEN}============================================================${NC}"
  echo
  echo -e "  VM IP         : ${CYAN}$VM_IP_ONLY${NC}"
  echo -e "  ArgoCD        : ${CYAN}https://argocd.int.fabsys.ovh${NC}"
  echo -e "  Kubeconfig    : ${CYAN}ssh ansible@$VM_IP_ONLY 'cat ~/.kube/config'${NC}"
  echo
  echo -e "${YELLOW}Prochaine étape : recréer les SealedSecrets${NC}"
  echo -e "  → Voir deploy/README.md Étape 3"
  echo
}

# ============================================================
# Main
# ============================================================
check_prerequisites
collect_inputs
generate_configs
run_terraform
wait_for_ssh
run_ansible
print_summary
