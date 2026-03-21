#!/bin/bash
# audio-switch.sh — Switcher la sortie audio de Kodi + RetroArch (LXC 301)
# Usage : audio-switch [jack|hdmi|status]
#
# jack → prise casque/enceinte (CX20632 Analog)
# hdmi → sortie TV via HDMI (AMD HDMI card 0, device 3)

set -e

LXC_ID=301
KODI_SETTINGS="/home/kodi/.kodi/userdata/guisettings.xml"
RETROARCH_CFG="/home/kodi/.config/retroarch/retroarch.cfg"

# Kodi ALSA device names
JACK_KODI="ALSA:plughw:CARD=Generic_1,DEV=0"
HDMI_KODI="ALSA:hdmi:CARD=Generic,DEV=3"

# RetroArch ALSA device names
JACK_RETROARCH="plughw:1,0"
HDMI_RETROARCH="hdmi:0,3"

usage() {
  echo "Usage: $0 [jack|hdmi|status]"
  echo "  jack   → Prise jack 3.5mm (casque / enceintes)"
  echo "  hdmi   → Sortie HDMI (TV)"
  echo "  status → Affiche la sortie actuellement configurée"
  exit 1
}

current() {
  pct exec "$LXC_ID" -- grep 'audiooutput.audiodevice' "$KODI_SETTINGS" | sed 's/.*>\(.*\)<.*/\1/'
}

switch_to() {
  local kodi_device="$1"
  local ra_device="$2"
  local label="$3"

  echo "→ Arrêt de Kodi..."
  pct exec "$LXC_ID" -- systemctl stop kodi
  sleep 2

  # Kodi
  pct exec "$LXC_ID" -- sed -i \
    "s|<setting id=\"audiooutput.audiodevice\"[^>]*>.*</setting>|<setting id=\"audiooutput.audiodevice\">${kodi_device}</setting>|" \
    "$KODI_SETTINGS"

  # RetroArch (seulement si pas en cours d'exécution, sinon il écrase le cfg)
  if ! pct exec "$LXC_ID" -- pgrep -x retroarch >/dev/null 2>&1; then
    pct exec "$LXC_ID" -- sed -i \
      "s|^audio_device = .*|audio_device = \"${ra_device}\"|" \
      "$RETROARCH_CFG"
  fi

  # Volume ALSA (jack = modéré pour casque, HDMI = 100%)
  local vol="$4"
  pct exec "$LXC_ID" -- amixer -c 1 -q set Master "${vol}" unmute
  pct exec "$LXC_ID" -- amixer -c 1 -q set Headphone "${vol}" unmute

  echo "→ Démarrage de Kodi..."
  pct exec "$LXC_ID" -- systemctl start kodi
  echo "✓ Sortie audio : $label"
  echo "  Kodi      → $kodi_device"
  echo "  RetroArch → $ra_device"
  echo "  Volume    → $vol"
}

case "${1:-}" in
  jack)   switch_to "$JACK_KODI" "$JACK_RETROARCH" "Jack 3.5mm" "50%" ;;
  hdmi)   switch_to "$HDMI_KODI" "$HDMI_RETROARCH" "HDMI TV" "100%" ;;
  status) echo "Sortie actuelle : $(current)" ;;
  *)      usage ;;
esac
