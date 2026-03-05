#!/usr/bin/env bash
# Génère un hash PBKDF2 compatible qBittorrent WebUI
# Usage: ./gen_qbittorrent_pass.sh

set -euo pipefail

read -rsp "Mot de passe qBittorrent : " PASSWORD
echo ""

QB_HASH=$(python3 -c "
import hashlib, os, base64, sys
password = sys.argv[1]
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', password.encode(), salt, 100000)
salt_b64 = base64.b64encode(salt).decode()
dk_b64 = base64.b64encode(dk).decode()
print(f'@ByteArray(PBKDF2-HMAC-SHA512:100000:{salt_b64}:{dk_b64})', end='')
" "$PASSWORD")

echo ""
echo "Hash généré : $QB_HASH"
echo ""
echo "Commande pour créer le SealedSecret :"
echo ""
echo "  kubectl create secret generic qbittorrent-auth \\"
echo "    --from-literal=password='${QB_HASH}' \\"
echo "    -n arr-stack --dry-run=client -o yaml \\"
echo "  | kubeseal --cert sealed-secrets-fixed-key.pem -o yaml \\"
echo "  > cluster/apps/arr-stack/qBittorrent-WEBUI_PASS.yaml"
