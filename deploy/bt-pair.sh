#!/bin/bash
# bt-pair.sh — Pairer une manette Bluetooth depuis l'hôte PVE
# Usage : bt-pair [scan|pair|list|remove]
#
# Le Bluetooth est géré sur l'hôte PVE. Les events input
# sont forwarded au LXC media via /dev/input bind mount.

set -e

SCAN_TIMEOUT=20

usage() {
  echo "Usage: $0 [scan|pair|list|remove]"
  echo ""
  echo "  scan   → Cherche les manettes à proximité (${SCAN_TIMEOUT}s)"
  echo "  pair   → Pair + trust une manette (mode pairing requis)"
  echo "  list   → Liste les manettes déjà pairées"
  echo "  remove → Supprime le pairing d'une manette"
  exit 1
}

ensure_bt() {
  if ! hciconfig hci0 >/dev/null 2>&1; then
    echo "✗ Pas d'adaptateur Bluetooth détecté."
    echo "  Vérifier : systemctl status btusb-realtek"
    exit 1
  fi
  bluetoothctl power on >/dev/null 2>&1
}

cmd_scan() {
  ensure_bt
  echo "🔍 Scan Bluetooth (${SCAN_TIMEOUT}s) — mets ta manette en mode pairing..."
  echo "   DS4/DS5 : maintenir PS + Share ~3 secondes"
  echo ""

  # Scan and collect devices
  timeout "${SCAN_TIMEOUT}" bluetoothctl --timeout "${SCAN_TIMEOUT}" scan on 2>/dev/null &
  local scan_pid=$!
  sleep "${SCAN_TIMEOUT}"
  kill "$scan_pid" 2>/dev/null; wait "$scan_pid" 2>/dev/null

  echo ""
  echo "Manettes détectées :"
  bluetoothctl devices | while read -r _ mac name; do
    local class
    class=$(bluetoothctl info "$mac" 2>/dev/null | grep "Icon:" | awk '{print $2}')
    if [[ "$class" == *"input"* ]] || echo "$name" | grep -qiE "controller|wireless|gamepad|joystick|xbox|ds4|dualsense|dualshock|8bitdo"; then
      echo "  $mac  $name"
    fi
  done
}

cmd_pair() {
  ensure_bt
  echo "🔍 Scan pour trouver ta manette..."
  echo "   Assure-toi qu'elle est en mode pairing (DS4: PS+Share ~3s)"
  echo ""

  timeout "${SCAN_TIMEOUT}" bluetoothctl --timeout "${SCAN_TIMEOUT}" scan on 2>/dev/null &
  local scan_pid=$!
  sleep "${SCAN_TIMEOUT}"
  kill "$scan_pid" 2>/dev/null; wait "$scan_pid" 2>/dev/null

  echo ""
  echo "Manettes détectées :"
  local devices=()
  while IFS= read -r line; do
    local mac name class
    mac=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | cut -d' ' -f3-)
    class=$(bluetoothctl info "$mac" 2>/dev/null | grep "Icon:" | awk '{print $2}')
    if [[ "$class" == *"input"* ]] || echo "$name" | grep -qiE "controller|wireless|gamepad|joystick|xbox|ds4|dualsense|dualshock|8bitdo"; then
      devices+=("$mac|$name")
      echo "  [${#devices[@]}] $mac  $name"
    fi
  done < <(bluetoothctl devices)

  if [[ ${#devices[@]} -eq 0 ]]; then
    echo "  Aucune manette trouvée. Réessaye avec: $0 scan"
    exit 1
  fi

  echo ""
  read -rp "Numéro de la manette à pairer [1-${#devices[@]}] : " choice

  if [[ "$choice" -lt 1 || "$choice" -gt ${#devices[@]} ]]; then
    echo "Choix invalide."
    exit 1
  fi

  local selected="${devices[$((choice-1))]}"
  local mac="${selected%%|*}"
  local name="${selected#*|}"

  echo ""
  echo "→ Pairing $name ($mac)..."
  bluetoothctl pair "$mac"
  sleep 2
  echo "→ Trust..."
  bluetoothctl trust "$mac"
  sleep 1
  echo "→ Connect..."
  bluetoothctl connect "$mac"
  sleep 3

  if bluetoothctl info "$mac" | grep -q "Connected: yes"; then
    echo ""
    echo "✓ $name pairée et connectée !"
    echo "  Elle se reconnectera automatiquement au prochain appui PS."
  else
    echo ""
    echo "⚠ Pairing effectué mais connexion échouée."
    echo "  Essaye : bluetoothctl connect $mac"
  fi
}

cmd_list() {
  ensure_bt
  echo "Manettes pairées :"
  bluetoothctl devices Paired 2>/dev/null | while read -r _ mac name; do
    local connected
    connected=$(bluetoothctl info "$mac" 2>/dev/null | grep "Connected:" | awk '{print $2}')
    if [[ "$connected" == "yes" ]]; then
      echo "  ✓ $mac  $name  (connectée)"
    else
      echo "  ○ $mac  $name  (déconnectée)"
    fi
  done
}

cmd_remove() {
  ensure_bt
  echo "Manettes pairées :"
  local devices=()
  while IFS= read -r line; do
    local mac name
    mac=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | cut -d' ' -f3-)
    devices+=("$mac|$name")
    echo "  [${#devices[@]}] $mac  $name"
  done < <(bluetoothctl devices Paired 2>/dev/null)

  if [[ ${#devices[@]} -eq 0 ]]; then
    echo "  Aucune manette pairée."
    exit 0
  fi

  echo ""
  read -rp "Numéro de la manette à supprimer [1-${#devices[@]}] : " choice

  if [[ "$choice" -lt 1 || "$choice" -gt ${#devices[@]} ]]; then
    echo "Choix invalide."
    exit 1
  fi

  local selected="${devices[$((choice-1))]}"
  local mac="${selected%%|*}"
  local name="${selected#*|}"

  bluetoothctl remove "$mac"
  echo "✓ $name ($mac) supprimée."
}

case "${1:-}" in
  scan)   cmd_scan ;;
  pair)   cmd_pair ;;
  list)   cmd_list ;;
  remove) cmd_remove ;;
  *)      usage ;;
esac
