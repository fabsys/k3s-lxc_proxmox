#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Bootstrap k3s homelab — Proxmox + Ansible (Tofu/Terraform)
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
VM_ID="${VM_ID:-}"
LXC_ID="${LXC_ID:-}"
VM_IP="${VM_IP:-}"
VM_GATEWAY="${VM_GATEWAY:-}"
NETWORK_VLAN="${NETWORK_VLAN:-}"
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

  echo -e "${YELLOW}--- Architecture ---${NC}"
  ask DEPLOYMENT_TYPE     "Type de déploiement (vm/lxc)" "lxc"
  ask K3S_CNI            "CNI (cilium/calico)"          "calico"
  ask GPU_TYPE            "Type de GPU (intel/amd)"      "amd"

  echo -e "${YELLOW}--- Proxmox ---${NC}"
  ask PROXMOX_ENDPOINT    "URL API Proxmox"              "https://192.168.1.10:8006"
  ask PROXMOX_USER        "Utilisateur Proxmox"          "root@pam"
  ask PROXMOX_NODE        "Nom du nœud Proxmox"          "pve"
  echo -n "Mot de passe Proxmox : "
  read -rsp "" PROXMOX_PASSWORD; echo

  echo -e "${YELLOW}--- Sécurité ---${NC}"
  echo -n "Mot de passe console/root (accès urgence) : "
  read -rsp "" VM_CONSOLE_PASSWORD; echo

  echo -e "${YELLOW}--- Réseau ---${NC}"
  if [[ "$DEPLOYMENT_TYPE" == "vm" ]]; then
    ask VM_ID             "ID de la VM"               "200"
  else
    ask LXC_ID             "ID du LXC"                "300"
  fi
  ask VM_IP             "IP statique (ex: 192.168.1.100/24)"
  ask VM_GATEWAY        "Passerelle"                "192.168.1.1"
  ask NETWORK_VLAN      "Tag VLAN (10=Mgmt, 30=K3s)" "30"

  echo -e "${YELLOW}--- SSH ---${NC}"
  local default_key=""
  for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [[ -f "$key_file" ]]; then
      default_key=$(cat "$key_file")
      break
    fi
  done
  ask SSH_PUBLIC_KEY    "Clé SSH publique" "$default_key"

  VM_IP_ONLY="${VM_IP%%/*}"
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

ssh_public_key      = "$SSH_PUBLIC_KEY"
EOF

  info "Génération de inventory.ini..."
  # Extraction de l'IP du PVE depuis l'URL (ex: https://192.168.1.98:8006 -> 192.168.1.98)
  PVE_IP_ONLY=$(echo "$PROXMOX_ENDPOINT" | grep -oP '(?<=//)[^:/]+')

  cat > "$ANSIBLE_DIR/inventory.ini" <<EOF
[pve]
proxmox ansible_host=$PVE_IP_ONLY ansible_user=root ansible_ssh_pass=$PROXMOX_PASSWORD

[k3s]
k3s-control ansible_host=$VM_IP_ONLY ansible_user=ansible ansible_become=true
EOF
}

run_iaas() {
  info "Exécution de $TF_BIN..."
  cd "$TERRAFORM_DIR"
  "$TF_BIN" init -upgrade
  "$TF_BIN" apply -auto-approve
}

wait_for_ssh() {
  info "Attente de la disponibilité SSH sur $VM_IP_ONLY..."
  local retries=30
  local count=0
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        root@"$VM_IP_ONLY" 'exit' 2>/dev/null || \
        ansible@"$VM_IP_ONLY" 'exit' 2>/dev/null; do
    count=$((count + 1))
    [[ $count -ge $retries ]] && error "SSH non disponible."
    echo -n "."
    sleep 10
  done
  echo
}
run_ansible() {
  info "Lancement du playbook Ansible..."
  cd "$ANSIBLE_DIR"
  local ssh_user="ansible"
  ssh -o StrictHostKeyChecking=no root@"$VM_IP_ONLY" 'exit' 2>/dev/null && ssh_user="root"

  # Pour l'hôte PVE, on utilise sshpass si une clé n'est pas déjà configurée
  export ANSIBLE_HOST_KEY_CHECKING=False
  ansible-playbook -i inventory.ini playbook.yml \
    -e "k3s_target=$DEPLOYMENT_TYPE" \
    -e "k3s_cni=$K3S_CNI" \
    -e "gpu_type=$GPU_TYPE" \
    -e "ansible_user=$ssh_user"
}


# --- Main ---
check_prerequisites
collect_inputs
generate_configs
run_iaas
wait_for_ssh
run_ansible
echo -e "${GREEN}Cluster prêt en mode $DEPLOYMENT_TYPE avec $K3S_CNI (via $TF_BIN) !${NC}"
