# 🧠 Référence Technique Complète — Homelab Proxmox/K3s/Media Center

> **Objectif de ce document** : Servir de prompt/contexte pour tout nouvel agent travaillant sur ce projet.
> Contient TOUS les pièges rencontrés, les décisions techniques, les configurations critiques, et les guidances pour éviter de refaire les mêmes erreurs.

---

## 📋 Table des Matières

1. [Architecture Matérielle & Réseau](#1-architecture-matérielle--réseau)
2. [Structure du Dépôt](#2-structure-du-dépôt)
3. [LXC sur Proxmox — Pièges Critiques](#3-lxc-sur-proxmox--pièges-critiques)
4. [K3s dans un LXC — Configuration Complète](#4-k3s-dans-un-lxc--configuration-complète)
5. [Media Center (Kodi + RetroArch + Steam) dans un LXC](#5-media-center-kodi--retroarch--steam-dans-un-lxc)
6. [Audio — Configuration ALSA Multi-Cartes](#6-audio--configuration-alsa-multi-cartes)
7. [Bluetooth & Manettes (DS4)](#7-bluetooth--manettes-ds4)
8. [Stockage SSD & Chemins de Données](#8-stockage-ssd--chemins-de-données)
9. [Backup & Restauration (Restic/rclone)](#9-backup--restauration-resticrclone)
10. [ArgoCD — Pièges operationnels](#10-argocd--pièges-opérationnels)
11. [Ansible — Pièges & Bonnes Pratiques](#11-ansible--pièges--bonnes-pratiques)
12. [Terraform/OpenTofu — Notes](#12-terraformopentofu--notes)
13. [Migration VM (vzdump/pct restore)](#13-migration-vm-vzdumppct-restore)
14. [Catalogue Complet des Erreurs Rencontrées](#14-catalogue-complet-des-erreurs-rencontrées)
15. [État Actuel de l'Infrastructure](#15-état-actuel-de-linfrastructure)
16. [Fichiers Clés & Leurs Rôles](#16-fichiers-clés--leurs-rôles)
17. [Tâches Restantes](#17-tâches-restantes)

---

## 1. Architecture Matérielle & Réseau

### Hardware
- **Machine** : Mini PC Chuwi AuBox
- **CPU/GPU** : AMD Ryzen 7 8745HS + iGPU Radeon 780M (RDNA3, accélération VA-API/AMF)
- **RAM** : 16 Go DDR5 (upgrade 32 Go prévu pour bande passante iGPU)
- **Stockage** :
  - NVMe 0 : 512 Go (système Proxmox + rootfs LXC)
  - NVMe 1 : 931 Go (`/dev/nvme0n1p1`, ext4 label "games", monté `/mnt/data`)
- **Adaptateur BT** : Realtek RTL8852BU (USB, `0bda:b85b`)

### Plan Réseau (pas de VLAN pour l'instant)
| Rôle | IP | LXC ID | OS |
|------|------|--------|-----|
| PVE Host (nouveau) | 192.168.1.98 | — | Proxmox VE 8.x |
| PVE Host (ancien) | 192.168.1.99 | — | Proxmox (à décom) |
| K3s Cluster | 192.168.1.100 | 300 | Debian 13 |
| Media Center | 192.168.1.101 | 301 | Ubuntu 24.04 |
| WireGuard | 192.168.1.103 | 103 | (migré) |
| OpenVPN Client | 192.168.1.104 | 104 | (migré) |
| Pi-hole DNS | 192.168.1.106 | 106 | (migré) |

### K3s Network
- Cluster CIDR : `10.42.0.0/16`
- Service CIDR : `10.43.0.0/16`
- CNI : **Calico** (v3.29.2 via Tigera Operator)
- ⚠️ **Cilium ne fonctionne PAS en LXC** (problèmes permissions eBPF avec kernel partagé)
- MetalLB pour LoadBalancer, Ingress-NGINX, cert-manager, external-dns

---

## 2. Structure du Dépôt

```
k3s-lxc_proxmox/
├── deploy/
│   ├── provision.sh              # Script bootstrap interactif (Tofu + Ansible)
│   ├── restore.sh                # Restauration PVC depuis Google Drive (restic)
│   ├── audio-switch.sh           # Commutateur audio jack/HDMI (copié par Ansible)
│   ├── bt-pair.sh                # Appairage BT manettes (copié par Ansible)
│   ├── gen_qbittorrent_pass.sh   # Génération hash qBittorrent
│   ├── terraform/
│   │   ├── main.tf               # LXC provisioning (K3s + Media)
│   │   ├── variables.tf          # Variables Terraform
│   │   └── outputs.tf            # Outputs
│   └── ansible/
│       ├── playbook.yml           # Playbook principal (3 plays: pve, k3s, media)
│       ├── inventory.ini          # Inventaire (pve, k3s, media)
│       ├── group_vars/all.yml     # Variables globales
│       └── roles/
│           ├── pve_host/          # Config hôte PVE (GPU passthrough, SSD, BT, services)
│           ├── base/              # Paquets de base
│           ├── k3s/               # Installation K3s + fix-kmsg + symlinks compat
│           ├── calico/            # CNI Calico
│           ├── cilium/            # CNI Cilium (non utilisé, problèmes eBPF)
│           ├── argocd/            # ArgoCD + root-app
│           └── media/             # Kodi + RetroArch + Steam (886 lignes!)
├── cluster/
│   ├── root-app.yaml             # ArgoCD root application
│   ├── argocd/                   # Chart ArgoCD (Helm)
│   ├── argocd-apps/              # App-of-apps templates
│   └── apps/                     # Applications K8s
│       ├── arr-stack/             # Radarr, Sonarr, Prowlarr, Jellyfin, Jellyseerr, JOAL, qBittorrent
│       ├── paperless/             # Paperless-ngx + PostgreSQL + Redis + backup CronJob
│       ├── syncthing/             # Syncthing + backup CronJob
│       ├── gluetun/               # VPN gateway (TUN device requis)
│       ├── homepage/              # Dashboard
│       ├── system/                # cert-manager, external-dns, ingress-nginx, metallb, sealed-secrets
│       └── ...
└── images/                        # Screenshots pour README
```

---

## 3. LXC sur Proxmox — Pièges Critiques

### ⚠️ LXC Privileged vs Unprivileged — Impact sur les UID

Les deux LXC principaux (300 et 301) sont **privilegiés** :
- **LXC 300 (K3s)** : `unprivileged` non défini = **privilegié** par défaut
- **LXC 301 (Media)** : `unprivileged = false` = **privilegié** explicite

**Conséquence CRITIQUE** : UID 1000 dans le LXC = UID 1000 sur l'hôte. **PAS** d'offset namespace (contrairement aux LXC unprivileged où UID 1000 → UID 101000 sur l'hôte).

Les LXC migrés (103, 104, 106) sont **unprivileged** (`--unprivileged 1` lors du `pct restore`).

### Configuration cgroup2 — Périphériques

Le provider Terraform `bpg/proxmox` ne supporte **PAS** toutes les options LXC raw config. Les lignes `lxc.*` doivent être ajoutées via Ansible (`lineinfile` sur `/etc/pve/lxc/<ID>.conf`).

**Majors des devices Linux à connaître** :
| Major | Device | Usage |
|-------|--------|-------|
| 226 | `/dev/dri/*` | GPU (DRM/KMS) |
| 29 | `/dev/fb0` | Framebuffer |
| 13 | `/dev/input/*` | Contrôleurs/claviers |
| 116 | `/dev/snd/*` | Audio ALSA |
| 4 | `/dev/tty*` | Terminaux |
| 10:200 | `/dev/net/tun` | TUN (VPN) |
| 10:223 | `/dev/uinput` | Devices virtuels (Steam) |
| 189 | `/dev/bus/usb/*` | USB |

### Seccomp — Désactivation pour Steam

Proxmox applique un filtre seccomp par défaut (`Seccomp: 2`) qui envoie **SIGTRAP** quand un process touche un syscall bloqué. Steam utilise des syscalls non-standard et **crashe immédiatement**.

**Solution** : `lxc.seccomp.profile:` (ligne vide, pas de valeur) → `Seccomp: 0`

⚠️ Ne mettre QUE sur le LXC Media (301), **PAS** sur K3s (300) qui n'en a pas besoin.

### proc:rw sys:rw — Obligatoire pour K3s ET pour systemd-udevd

`lxc.mount.auto: proc:rw sys:rw` est requis pour :
- **K3s** (LXC 300) : kubelet écrit dans `/proc/sys/vm/overcommit_memory`, `/proc/sys/kernel/panic`, etc.
- **Media** (LXC 301) : `systemd-udevd` (dont dépend `libinput` pour les manettes)

Sans ça :
- K3s : `Failed to start ContainerManager: open /proc/sys/vm/overcommit_memory: read-only file system`
- Media : manettes non détectées

### /dev/kmsg — N'existe PAS en LXC

`/dev/kmsg` n'est pas créé dans un LXC. K3s en a besoin.

**Solution** : Créer un service systemd `fix-kmsg.service` avec `Before=k3s.service` qui fait `ln -sf /dev/console /dev/kmsg`.

⚠️ Un simple `ln -s` en one-shot ne persiste PAS après reboot du LXC ! Il faut un service systemd persistant.

### unbind-fbcon — Libérer le GPU pour Kodi

Le framebuffer console (`vtcon1`) tient le DRM master du GPU AMD au boot. Kodi ne peut pas initialiser le DRM tant que fbcon est bindé.

**Solution** : Service `unbind-fbcon.service` sur l'hôte PVE qui fait `echo 0 > /sys/class/vtconsole/vtcon1/bind`.

⚠️ Au boot, `/sys/class/vtconsole/vtcon1/bind` peut ne pas être disponible immédiatement. Le service doit avoir une **boucle de retry** (10 itérations, 1s de pause).

### renderD128 — Groupe incorrect

Malgré une règle udev `SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render"`, PVE assigne parfois le groupe `kvm` au lieu de `render` à `/dev/dri/renderD128`.

**Solution** : `ExecStartPre=/bin/chown root:render /dev/dri/renderD128` dans chaque service qui utilise le GPU (Kodi, RetroArch).

---

## 4. K3s dans un LXC — Configuration Complète

### Config LXC 300 (`/etc/pve/lxc/300.conf`)

```
# Fonctionnalités LXC
features: keyctl=1,nesting=1

# GPU passthrough (Jellyfin VA-API transcoding)
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir

# TUN device (gluetun VPN gateway)
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net dev/net none bind,optional,create=dir

# /proc/sys writable (kubelet DOIT écrire dedans)
lxc.mount.auto: proc:rw sys:rw

# Stockage partagé
mp0: /mnt/data,mp=/mnt/data
```

### Flags K3s à l'installation

```bash
INSTALL_K3S_EXEC="server \
  --flannel-backend=none \
  --disable-network-policy \
  --disable=traefik \
  --disable=servicelb \
  --disable=cloud-controller \        # ⚠️ OBLIGATOIRE sinon taint permanent
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16 \
  --kubelet-arg=protect-kernel-defaults=false \  # ⚠️ OBLIGATOIRE en LXC
  --kubelet-arg=system-reserved=cpu=500m,memory=512Mi \
  --kubelet-arg=kube-reserved=cpu=500m,memory=512Mi \
  --kubelet-arg=eviction-hard=memory.available<100Mi,nodefs.available<10%"
```

### Flags K3s INTERDITS

- `--kubelet-arg=kube-privileged=true` → **N'EXISTE PAS**, crash loop kubelet avec `unknown flag`
- `--cloud-controller-manager` → utiliser `--disable=cloud-controller` à la place

### Problèmes connus après reboot LXC 300

1. **`/dev/kmsg` disparaît** → fix-kmsg.service le recrée
2. **`/proc/sys` read-only** → `lxc.mount.auto: proc:rw sys:rw` corrige ça
3. **Calico peut mettre 2-3 min à converger** → attendre, ne pas paniquer
4. **Node taint** : Si `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` apparaît, c'est que `--disable=cloud-controller` manque → `kubectl taint node k3s-lxc node.cloudprovider.kubernetes.io/uninitialized:NoSchedule-`

### Symlinks de compatibilité

Des anciens manifests référencent `/mnt/shared_data/`. Des symlinks de compatibilité existent :
- `/mnt/shared_data/movies → /mnt/data/movies`
- `/mnt/shared_data/paperless → /mnt/data/paperless`

Ces symlinks sont créés par le rôle Ansible `k3s`.

---

## 5. Media Center (Kodi + RetroArch + Steam) dans un LXC

### Config LXC 301 (`/etc/pve/lxc/301.conf`)

```
unprivileged: 0
features: keyctl=1,nesting=1

# GPU
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir

# Framebuffer
lxc.cgroup2.devices.allow: c 29:0 rwm
lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file

# TTY (requis pour DRM/KMS init)
lxc.cgroup2.devices.allow: c 4:* rwm
lxc.mount.entry: /dev/tty0 dev/tty0 none bind,optional,create=file

# Input (manettes, claviers)
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir

# Audio ALSA
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir

# uinput (Steam virtual gamepad)
lxc.cgroup2.devices.allow: c 10:223 rwm
lxc.mount.entry: /dev/uinput dev/uinput none bind,optional,create=file

# USB
lxc.cgroup2.devices.allow: c 189:* rwm

# /proc/sys writable (pour systemd-udevd)
lxc.mount.auto: proc:rw sys:rw

# Seccomp DÉSACTIVÉ (Steam en a besoin)
lxc.seccomp.profile:

# Stockage partagé
mp0: /mnt/data,mp=/mnt/data
```

### Kodi — Mode GBM/KMS (sans X11, sans Wayland)

Kodi 21.x supporte le mode GBM nativement avec `--windowing=gbm`.

**Service systemd** :
```ini
[Service]
User=root                          # PAS User=kodi (casse drmAuthMagic)
Environment=HOME=/home/kodi
Environment=LIBVA_DRIVER_NAME=radeonsi
Environment=MESA_GL_VERSION_OVERRIDE=3.3
ExecStartPre=/bin/chown root:render /dev/dri/renderD128
ExecStart=/usr/bin/kodi --standalone --windowing=gbm --audio-backend=pulseaudio
Restart=on-failure
```

**Pièges** :
- `User=kodi` avec `PAMName=login` **casse** `drmAuthMagic` → utiliser `User=root` + `Environment=HOME=/home/kodi`
- `card1` est le GPU AMD dans le LXC (pas `card0` — la numérotation change en LXC)
- `DrmAtomicCommit - test commit failed: Invalid argument` est **NON-FATAL** (test MPO échoue, fallback OK)
- Le moniteur PNP(XMI) 'Mi Monitor' supporte 3440x1440, 4K, 1080p

### RetroArch — Configuration KMS/GL

```ini
video_driver = "gl"              # PAS "drm" (framebuffer only, RGUI pixelé)
video_context_driver = "kms"     # OpenGL via KMS/EGL
menu_driver = "ozone"            # Requiert GL + assets
input_driver = "udev"            # PAS "x" (pas de X11 en mode KMS)
audio_device = "plughw:0,3"      # HDMI TV (card 0, device 3)
config_save_on_exit = "false"    # CRITIQUE: RetroArch ÉCRASE retroarch.cfg à chaque sortie
```

⚠️ **RetroArch réécrit `retroarch.cfg` à chaque sortie** sauf si `config_save_on_exit = "false"`. Sans ça, il peut remettre `input_driver = "x"` ou `video_driver = "drm"` et tout casser.

**Protection supplémentaire** : `chmod 444 retroarch.cfg` après configuration.

**Assets requis** : `retroarch-assets` package, path = `/usr/share/libretro/assets`

**Cores disponibles Ubuntu 24.04** : `libretro-mgba` (GBA), `libretro-nestopia` (NES), `libretro-snes9x` (SNES), `libretro-genesisplusgx` (Mega Drive), `libretro-beetle-psx` (PSX), `libretro-beetle-pce-fast` (PC Engine), `libretro-desmume` (NDS), `libretro-gambatte` (GB/GBC), `libretro-bsnes-mercury-*` (SNES alt)

**FBNeo** (Neo Geo/Arcade) : pas de paquet → téléchargement direct depuis buildbot libretro.

### Steam — Configuration Xorg + Openbox

Steam ne fonctionne **PAS** avec :
- Kodi GBM (pas de X11)
- `cage` (Wayland compositor) → Steam re-exec perd l'auth Xwayland, segfault dans libX11 32-bit

**Solution qui fonctionne** : Xorg standalone + Openbox WM

```bash
# Lancement Xorg
Xorg :0 -config /etc/X11/xorg-steam.conf -sharevts -novtswitch -keeptty -nolisten tcp

# xorg-steam.conf force 1080p (évite 4K@30Hz de la TV)
Section "Monitor"
    Identifier "HDMI"
    Modeline "1920x1080" ...
    Option "PreferredMode" "1920x1080"
EndSection
```

**Variables d'environnement Steam** :
```bash
PROTON_USE_XALIA=0        # ⚠️ PAS PROTON_ENABLE_XALIA=0 (ne marche pas)
WINE_FULLSCREEN_FSR=1     # FSR upscaling
LIBSEAT_BACKEND=seatd     # Seat management sans logind
XDG_RUNTIME_DIR=/run/user/1000
LANG=en_US.UTF-8
```

**Problème Steam disk space** : Steam utilise `statvfs()` sur le dossier `debian-installation/`. Créer des symlinks sur des sous-dossiers ne suffit PAS. Il faut symlinker **tout** `debian-installation/` vers le SSD :
```
/home/kodi/.steam/debian-installation → /mnt/data/games/steam/debian-installation
```

**Steam bootstrap** : Première exécution télécharge ~2 Go. Ansible fait `steam -textclient +quit` (headless, 600s timeout).

### Switching Kodi ↔ RetroArch ↔ Steam

Architecture : systemd path units surveillent des fichiers trigger.

```
Kodi → [RunScript(script.launch.retroarch)] → touch /tmp/.launch-retroarch
  → retroarch-switcher.path détecte le fichier
  → retroarch-switcher.service exécute launch-retroarch
  → launch-retroarch: stop kodi, chown renderD128, amixer IEC958 on, retroarch --menu
  → RetroArch quitte → restart kodi.service

Kodi → [RunScript(script.launch.steam)] → touch /tmp/.launch-steam
  → steam-switcher.path détecte
  → steam-switcher.service exécute launch-steam
  → launch-steam: stop kodi, start pulseaudio+seatd, start Xorg, start openbox+steam
  → Background loop: fix /dev/input perms toutes les 2s (Steam crée des devices via uinput)
  → Steam quitte → kill Xorg/openbox/pulseaudio, modetest DRM reset, restart kodi
```

⚠️ **Piège critique DRM master** : Quand Xorg prend le DRM master puis est tué, le kernel ne libère pas complètement le mode. Kodi redémarre en mode dégradé (1280x720 au lieu de 4K).
- `modetest -w 94:DPMS:0` tente un reset partiel mais ne fonctionne pas toujours
- **Seule solution fiable** : full restart du LXC via SSH vers le PVE (`ssh root@192.168.1.98 pct stop 301 && pct start 301`)
- Le script `fix-kodi` détecte le mode dégradé via le log Kodi (`GUI format 1280x720`) et fait le restart automatiquement

### Addons Kodi

- `script.launch.retroarch` : addon Kodi qui fait `touch /tmp/.launch-retroarch`
- `script.launch.steam` : addon Kodi qui fait `touch /tmp/.launch-steam`
- `kodi-peripheral-joystick` : paquet requis pour les manettes dans Kodi
- L'addon doit être `enabled=1` dans `/home/kodi/.kodi/userdata/Database/Addons33.db`
- `favourites.xml` utilise `RunScript(script.launch.retroarch)` — **PAS** `System.Exec()` (silencieusement ignoré)

---

## 6. Audio — Configuration ALSA Multi-Cartes

### Hardware Audio

| Card | PCI | Type | Devices |
|------|-----|------|---------|
| 0 | `66:00.1` | AMD HDMI | DEV 3 = TV HISENSE, DEV 7-9 = HDMI 1-3 |
| 1 | `66:00.6` | CX20632 Analog | DEV 0 = Jack 3.5mm |

### Périphériques ALSA

| Output | Kodi device | RetroArch device | PulseAudio sink |
|--------|-------------|------------------|-----------------|
| Jack | `plughw:CARD=Generic_1,DEV=0` | `plughw:1,0` | `alsa_output.pci-0000_66_00.6.analog-stereo` |
| HDMI TV | `hdmi:CARD=Generic,DEV=3` | `plughw:0,3` | `alsa_output.pci-0000_66_00.1.hdmi-stereo` |

### IEC958 HDMI Switch — PIÈGE MAJEUR

L'audio HDMI ne sort **QUE** si le switch ALSA `IEC958,0` est activé :
```bash
amixer -c 0 set 'IEC958',0 on    # Active l'audio HDMI
amixer -c 0 set 'IEC958',0 off   # Désactive
```

⚠️ RetroArch ne l'active PAS automatiquement → le script `launch-retroarch` doit le faire.
⚠️ Le script `audio-switch` gère ce switch automatiquement.

### PulseAudio — Pour Steam uniquement

Kodi utilise ALSA directement (GBM mode). Steam/Proton nécessitent PulseAudio.

```bash
pulseaudio --start --exit-idle-time=-1  # Ne pas auto-exit
# Créer /run/user/1000/pulse avec ownership kodi:kodi
```

Le script `launch-steam` démarre PulseAudio et route vers le sink HDMI.

---

## 7. Bluetooth & Manettes (DS4)

### Architecture BT

Le Bluetooth tourne sur l'**hôte PVE** (pas dans le LXC). Les events manettes arrivent dans le LXC via le bind-mount `/dev/input`.

### Realtek RTL8852BU — Binding manuel requis

L'adaptateur `0bda:b85b` n'est **PAS** dans la table btusb par défaut.

**Service systemd** `btusb-realtek.service` (sur PVE) :
```bash
echo '0bda b85b' > /sys/bus/usb/drivers/btusb/new_id
```

Firmware requis : `firmware-realtek` package → `/lib/firmware/rtl_bt/rtl8852bu_fw.bin`

### Appairage DS4

1. PS + Share ~3 secondes → LED clignote rapidement
2. Sur PVE : `bt-pair pair` (script interactif)
3. Ordre : `pair` → `trust` → `connect` (trust AVANT connect)
4. L'appairage est persistant (auto-reconnect sur pression bouton)

### udev — Permissions des devices input

Les manettes BT et les virtual gamepads Steam obtiennent le groupe `systemd-timesync` au lieu de `input`.

**Règle udev** (dans LXC 301) :
```
KERNEL=="event[0-9]*", SUBSYSTEM=="input", MODE="0660", GROUP="input", ACTION=="add"
KERNEL=="js[0-9]*", SUBSYSTEM=="input", MODE="0660", GROUP="input", ACTION=="add"
```

⚠️ `ACTION=="add"` est nécessaire pour les devices créés dynamiquement par Steam via `/dev/uinput`.

⚠️ Même avec les règles udev, les devices Steam créés dynamiquement ne sont pas toujours catchés en LXC. **Solution de contournement** : boucle background dans `launch-steam` :
```bash
while true; do chgrp input /dev/input/event* /dev/input/js* 2>/dev/null; chmod 0660 /dev/input/event* /dev/input/js* 2>/dev/null; sleep 2; done &
```

### Buttonmap Kodi DS4

- Paquet requis : `kodi-peripheral-joystick`
- Device exact : `"Sony Computer Entertainment Wireless controller"` (casse exacte !)
- 13 boutons, 8 axes
- Fichier buttonmap : `Sony_Computer_Entertainment_Wireless_Controller_13b_8a.xml`
- Emplacement : `/usr/share/kodi/addons/peripheral.joystick/resources/buttonmaps/xml/linux/`
- ⚠️ L'approche `gamepad.xml` NE fonctionne PAS

---

## 8. Stockage SSD & Chemins de Données

### Layout disque

```
/mnt/data/                          # SSD 931 Go, monté sur PVE, bind-mounté dans LXC 300+301
├── games/
│   ├── steam/
│   │   └── debian-installation/    # Racine Steam (symlink depuis LXC 301)
│   └── non-steam/                  # ROMs custom
├── movies/                         # Films/séries (Radarr, Sonarr, Jellyfin, Plex)
│   ├── movies/
│   ├── tv/
│   └── joal-import/                # chmod 777 pour JOAL
├── paperless/
│   ├── data/
│   ├── media/documents/
│   ├── consume/
│   └── export/
├── nextcloud/
└── backup/
```

### Ownership

Tous les répertoires appartiennent à UID **1000** (les deux LXC sont privilegiés, pas d'offset).

Les containers K8s utilisent `fsGroup: 1000`, `PUID=1000`, `PGID=1000`.

Exception : `joal-import/` est en `chmod 777` (JOAL écrit avec un UID différent).

### Chemins dans les manifests K8s

Tous les `hostPath` dans `cluster/apps/*/deployment.yaml` utilisent `/mnt/data/...` :
- `/mnt/data/movies` (arr-stack, plex)
- `/mnt/data/paperless/{data,media,consume,export}` (paperless)

⚠️ **Anciens chemins** : Certains manifests peuvent encore référencer `/mnt/shared_data/`. Des symlinks de compatibilité existent dans LXC 300 mais les manifests DOIVENT utiliser `/mnt/data/`.

### Virtiofs Mounts (pour mode VM, non utilisé actuellement)

Dans `group_vars/all.yml` :
```yaml
virtiofs_mounts:
  - tag: movies
    path: /mnt/data/movies
  - tag: paperless
    path: /mnt/data/paperless
```

---

## 9. Backup & Restauration (Restic/rclone)

### Architecture Backup

- **PAS de VolSync** (désactivé)
- **CronJobs K8s** : restic → rclone → Google Drive
- Schedules : Paperless 03h00, arr-stack 03h30, Syncthing 04h00

### Repos Restic

| Namespace | Repo rclone | Tags |
|-----------|-------------|------|
| arr-stack | `rclone:gdrive:k3s-backups/arr-stack` | radarr, sonarr, prowlarr, jellyfin, jellyseerr |
| paperless | `rclone:googledrive:k3s-backups/paperless` | — |
| syncthing | `rclone:googledrive:k3s-backups/syncthing` | — |

⚠️ **Attention aux noms rclone** : arr-stack utilise `gdrive:`, paperless/syncthing utilisent `googledrive:`. C'est le même remote mais nommé différemment dans la config rclone.

### Pièges Restic CRITIQUES

#### 1. restic restore SKIP les fichiers existants

`restic restore latest --target / --path /data/radarr` **ne remplace PAS** les fichiers qui existent déjà sur la cible. Si un pod a déjà démarré et créé des fichiers de config frais, restic les skip.

**Solution obligatoire** : Wiper le PVC avant le restore :
```bash
rm -rf /data/radarr/* /data/radarr/.[!.]* 2>/dev/null || true
```

Alternative : `--overwrite always` (restic >= 0.17.0) mais moins fiable.

#### 2. Repo locks stale après crash

Si un pod de backup crashe pendant une opération restic, le repo reste locké. Les opérations suivantes échouent avec `repository is already locked`.

**Solution** : `restic unlock --remove-all` comme étape séparée AVANT toute opération.

#### 3. Snapshots corrompus pendant un crash K3s

Si K3s crashe pendant l'exécution d'un CronJob backup, les snapshots créés sont quasi-vides (3.4 KiB au lieu de 1.252 GiB pour paperless).

**Nettoyage** : Identifier les snapshots par taille anormale avec `restic snapshots`, puis `restic forget <ID>` pour chaque snapshot corrompu.

### Script restore.sh

Le script `deploy/restore.sh` a été corrigé pour :
1. ✅ Wiper les PVCs avant restore (`rm -rf`)
2. ✅ Garder PostgreSQL UP pendant l'import paperless (seul `paperless-ngx` est scale down)
3. ✅ `DROP SCHEMA public CASCADE; CREATE SCHEMA public;` avant import SQL
4. ✅ Désactiver ArgoCD auto-sync pendant le restore
5. ✅ `restic unlock --remove-all` avant chaque restore
6. ✅ Afficher les tailles restaurées pour vérification

---

## 10. ArgoCD — Pièges Opérationnels

### Désactiver selfHeal / auto-sync

**CE QUI NE MARCHE PAS** :
```bash
# ❌ Merge patch avec null — ArgoCD l'ignore silencieusement
kubectl patch application X --type=merge -p '{"spec":{"syncPolicy":null}}'
```

**CE QUI MARCHE** :
```bash
# ✅ JSON patch pour supprimer la clé automated
kubectl patch application X --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

### App-of-Apps — root-app

Le pattern utilisé est app-of-apps : `root-app` gère les sous-applications.

⚠️ Si vous désactivez l'auto-sync sur une sub-app mais PAS sur `root-app`, celui-ci va re-syncer la sub-app et **réactiver son auto-sync**.

**Procédure complète pour une maintenance** :
1. Désactiver auto-sync sur `root-app`
2. Désactiver auto-sync sur l'app cible
3. Faire la maintenance
4. Réactiver sur l'app cible
5. Réactiver sur `root-app`

### Réactiver l'auto-sync

```bash
kubectl patch application X -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

---

## 11. Ansible — Pièges & Bonnes Pratiques

### Variables passées via `-e` sont des STRINGS

```bash
# ❌ deploy_media est la STRING "true", pas le booléen true
ansible-playbook ... -e "deploy_media=true"

# ✅ Utiliser le filtre | bool dans les templates/conditions
when: deploy_media | bool
```

### `-e "ansible_user=X"` override TOUS les hôtes

Une variable globale `-e "ansible_user=root"` écrase les valeurs définies dans l'inventaire pour TOUS les hôtes, y compris ceux qui ont un `ansible_user` explicite.

### set_fact vs group_vars

`set_fact` ne fonctionne que dans le play en cours. Pour des variables partagées entre plays, utiliser `group_vars/all.yml`.

### k3s_user / k3s_home

En mode LXC, l'utilisateur est `root` (pas `ansible`). Variables ternaires dans `group_vars/all.yml` :
```yaml
k3s_user: "{{ 'root' if k3s_target == 'lxc' else 'ansible' }}"
k3s_home: "{{ '/root' if k3s_target == 'lxc' else '/home/ansible' }}"
```

### Shebang mangé par heredoc SSH

Quand on envoie un script via `pct exec ... -- bash -c 'cat <<EOF > /path/script.sh\n#!/bin/bash\n...\nEOF'`, le shebang `#!/bin/bash` est mangé par l'interprétation du heredoc.

**Solution** : Encoder le script en base64 ou utiliser le module Ansible `copy`/`template` directement.

### Idempotence des lineinfile sur /etc/pve/lxc/*.conf

Les fichiers `/etc/pve/lxc/<ID>.conf` sont gérés par Proxmox. `lineinfile` fonctionne bien pour ajouter/modifier des lignes `lxc.*`, mais attention :
- Chaque `lineinfile` avec `regexp` doit matcher UNE seule ligne
- Utiliser `insertafter: EOF` pour les nouvelles entrées
- Les changements nécessitent un reboot du LXC

---

## 12. Terraform/OpenTofu — Notes

### Provider bpg/proxmox

- Version : `~> 0.66` (installé : v0.98.1)
- **Limitations** : Ne supporte PAS les options LXC raw config (`lxc.cgroup2.*`, `lxc.mount.*`, `lxc.seccomp.*`) → ces configs DOIVENT être ajoutées via Ansible post-provisioning

### LXC K3s (ID 300)

```hcl
unprivileged = false    # Privilegié (requis pour Docker/K3s)
features { nesting = true; keyctl = true }
memory { dedicated = 8192 }
cpu { cores = 4 }
disk { size = 30 }       # Go — rootfs uniquement, données sur SSD externe
```

### LXC Media (ID 301)

```hcl
unprivileged = false    # Privilegié (requis pour GPU passthrough)
features { nesting = true }
memory { dedicated = 8192 }
cpu { cores = 12 }       # 12 cores pour Steam/gaming
disk { size = 30 }
```

### Templates

- K3s : `debian-13-standard_13.1-2_amd64.tar.zst`
- Media : `ubuntu-24.04-standard_24.04-2_amd64.tar.zst` (migré depuis Debian 13)

---

## 13. Migration VM (vzdump/pct restore)

### Procédure

```bash
# Sur l'ancien PVE (source)
vzdump <VMID> --compress zstd --storage local --mode stop

# Copier le backup vers le nouveau PVE
scp /var/lib/vz/dump/vzdump-lxc-<VMID>-*.tar.zst root@<nouveau_pve>:/var/lib/vz/dump/

# Sur le nouveau PVE (cible)
pct restore <VMID> /var/lib/vz/dump/vzdump-lxc-<VMID>-*.tar.zst \
  --storage local-lvm --unprivileged 1

# Démarrer
pct start <VMID>
```

### Pièges

- **SSH** : Si pas de clé SSH entre les PVE, inverser le sens du `scp` (pull depuis la cible)
- **Stopper sur la source AVANT de démarrer sur la cible** (conflits IP)
- **Les configs (IP, MAC, bridge) sont préservées** dans le backup vzdump
- **`--storage local-lvm`** : Spécifier le stockage cible (peut différer de la source)

---

## 14. Catalogue Complet des Erreurs Rencontrées

| # | Erreur | Cause Racine | Solution |
|---|--------|-------------|----------|
| 1 | Calico `connection refused 127.0.0.1:6443` | `wait_for` vérifiait l'existence du fichier kubeconfig, pas la dispo API | `wait_for port: 6443` |
| 2 | Kubelet `unknown flag: --kube-privileged` | Flag K3s invalide | Supprimer `--kubelet-arg=kube-privileged=true` |
| 3 | Node taint `uninitialized:NoSchedule` permanent | Cloud controller manager attend un provider cloud | `--disable=cloud-controller` |
| 4 | ArgoCD `chown failed: user ansible` | Utilisateur `ansible` n'existe pas en LXC | Variable `k3s_user` (root en LXC) |
| 5 | Kodi `failed to initialize Atomic DRM` | `/dev/tty0` absent du LXC | Bind-mount `/dev/tty0` |
| 6 | Kodi process 1.5MB RAM (wrapper state) | `ExecStart` incorrect | `kodi --standalone --windowing=gbm` |
| 7 | RetroArch menu pixelé | `video_driver = "drm"` = framebuffer sans GL | `video_driver = "gl"` + `video_context_driver = "kms"` |
| 8 | RetroArch "no items" dans file browser | `~/roms` → `/root/roms` inexistant | Symlink `/root/roms → /home/kodi/roms` |
| 9 | RetroArch input mort | `input_driver = "x"` (auto-écrit par RetroArch) | `input_driver = "udev"` + `config_save_on_exit = "false"` + `chmod 444` |
| 10 | DS4 `Failed to access management interface` | BT impossible dans LXC (AF_BLUETOOTH) | Exécuter bluetoothd sur l'hôte PVE |
| 11 | Realtek BT adapter non reconnu | `0bda:b85b` pas dans table btusb | `echo '0bda b85b' > .../btusb/new_id` |
| 12 | Steam crash SIGTRAP | Seccomp Proxmox bloque syscalls | `lxc.seccomp.profile:` (vide) |
| 13 | Steam `Authorization required` | Re-exec perd l'auth cage/Xwayland | Xorg standalone au lieu de cage |
| 14 | Steam fullscreen 1280x800 | TV envoie 4K@30Hz, xrandr corrompt DRM | Config Xorg native 1080p |
| 15 | Steam 30 FPS / lag | TV 3840x2160@30Hz + xalia.exe (50% CPU) | xorg-steam.conf 1080p + `PROTON_USE_XALIA=0` |
| 16 | Kodi écran noir après Steam | Xorg tient DRM master, kernel ne release pas | `fix-kodi` avec auto-restart LXC via SSH |
| 17 | K3s `/dev/kmsg: no such file` | `/dev/kmsg` n'existe pas en LXC | Service systemd `fix-kmsg` (ln -sf /dev/console) |
| 18 | K3s `/proc/sys/vm/overcommit_memory: read-only` | `/proc/sys` monté read-only | `lxc.mount.auto: proc:rw sys:rw` |
| 19 | Pods `FailedMount` `/dev/dri` vide | GPU non passé au LXC K3s | `lxc.cgroup2.devices.allow: c 226:* rwm` + bind |
| 20 | Gluetun crash TUN | Device TUN absent | `lxc.cgroup2.devices.allow: c 10:200 rwm` + bind |
| 21 | Steam disk space 17 Go (au lieu de 770) | `statvfs()` sur `debian-installation/` | Symlink `debian-installation/` entier vers SSD |
| 22 | Audio HDMI muet (RetroArch) | Switch ALSA `IEC958,0` désactivé | `amixer -c 0 set 'IEC958',0 on` |
| 23 | Restic restore skip fichiers | Fichiers existants non écrasés | Wiper PVC avant restore |
| 24 | Restic `repository locked` | Lock stale après crash pod | `restic unlock --remove-all` |
| 25 | Paperless DB vide après restore | Postgres scale down → psql impossible | Garder postgres UP, seul paperless-ngx scale down |
| 26 | ArgoCD re-scale pendant restore | selfHeal réactive les replicas | JSON patch `remove /spec/syncPolicy/automated` |
| 27 | `unbind-fbcon` échoue au boot | `vtcon1/bind` pas encore dispo | Boucle retry 10x1s |
| 28 | renderD128 groupe kvm | PVE ignore udev rule | `ExecStartPre=/bin/chown root:render` |
| 29 | Ansible `pulseaudio` conflict | `pulseaudio` amd64 vs `pulseaudio:i386` | Supprimer `pulseaudio:i386` de la liste |
| 30 | Shebang `#!/bin/bash` mangé | Heredoc SSH interprète le shebang | Encoder en base64 ou utiliser module copy |

---

## 15. État Actuel de l'Infrastructure

### Ce qui fonctionne ✅

- K3s cluster opérationnel (node Ready, Calico CNI, ArgoCD)
- GPU passthrough K3s (Jellyfin VA-API transcoding)
- TUN passthrough K3s (gluetun VPN)
- Tous les pods K8s running (sauf renovate — secret manquant pré-existant)
- Kodi GBM sur TV HDMI
- RetroArch GL+KMS avec audio HDMI
- Steam Big Picture avec Xorg+Openbox
- DS4 USB + Bluetooth fonctionnel
- Audio jack/HDMI switchable
- Backups restic → Google Drive
- VMs migrées (wireguard, openvpn, pi-hole)
- Script restore.sh corrigé

### Ce qui reste à faire 📋

- [ ] `git push` vers GitHub pour qu'ArgoCD sync les nouveaux manifests
- [ ] Tester retour Kodi après exit Steam (restauration mode DRM)
- [ ] Tester manette dans jeu Proton avec `PROTON_USE_XALIA=0`
- [ ] Vérifier `retroarch.cfg chmod 444`
- [ ] Renovate pod : créer le secret `renovate-secret` manquant
- [ ] VLANs (reporté, architecture réseau plate pour l'instant)
- [ ] Upgrade RAM 32 Go dual-channel

---

## 16. Fichiers Clés & Leurs Rôles

### Infrastructure (Terraform + Ansible)

| Fichier | Rôle |
|---------|------|
| `deploy/provision.sh` | Script bootstrap interactif (Tofu → Ansible) |
| `deploy/terraform/main.tf` | Provisioning LXC (K3s 300 + Media 301) |
| `deploy/ansible/playbook.yml` | 3 plays : pve_host, k3s, media |
| `deploy/ansible/group_vars/all.yml` | Variables globales |
| `deploy/ansible/roles/pve_host/tasks/main.yml` | Config PVE : GPU/TUN passthrough, SSD, BT, unbind-fbcon, services |
| `deploy/ansible/roles/k3s/tasks/main.yml` | K3s install + fix-kmsg + symlinks compat |
| `deploy/ansible/roles/calico/tasks/main.yml` | CNI Calico via Tigera Operator |
| `deploy/ansible/roles/argocd/tasks/main.yml` | ArgoCD + root-app |
| `deploy/ansible/roles/media/tasks/main.yml` | **886 lignes** — Kodi + RetroArch + Steam + DS4 complet |

### Scripts utilitaires

| Fichier | Rôle | Déployé sur |
|---------|------|-------------|
| `deploy/audio-switch.sh` | Switch audio jack/HDMI | PVE → `/usr/local/bin/audio-switch` |
| `deploy/bt-pair.sh` | Appairage BT manettes | PVE → `/usr/local/bin/bt-pair` |
| `deploy/restore.sh` | Restauration PVC depuis Google Drive | Machine locale |

### Manifests K8s

| Fichier | Applications | Paths sensibles |
|---------|-------------|-----------------|
| `cluster/apps/arr-stack/deployment.yaml` | Radarr, Sonarr, Prowlarr, Jellyfin, Jellyseerr, JOAL, qBittorrent | `/mnt/data/movies` |
| `cluster/apps/paperless/deployment.yaml` | Paperless-ngx + PostgreSQL + Redis | `/mnt/data/paperless/*` |
| `cluster/apps/paperless/backup-cronjob.yaml` | Backup CronJob paperless | `/mnt/data/paperless/*` |
| `cluster/apps/syncthing/` | Syncthing | config PVC |
| `cluster/apps/gluetun/` | VPN gateway | Requiert TUN device |

### Fichiers de config sur les systèmes

| Fichier | Système | Rôle |
|---------|---------|------|
| `/etc/pve/lxc/300.conf` | PVE | Config LXC K3s |
| `/etc/pve/lxc/301.conf` | PVE | Config LXC Media |
| `/etc/systemd/system/unbind-fbcon.service` | PVE | Libère GPU du fbcon |
| `/etc/systemd/system/btusb-realtek.service` | PVE | Bind adapter BT |
| `/etc/systemd/system/fix-kmsg.service` | LXC 300 | Symlink /dev/kmsg |
| `/etc/systemd/system/kodi.service` | LXC 301 | Kodi GBM |
| `/etc/systemd/system/retroarch-switcher.{path,service}` | LXC 301 | Launcher RetroArch |
| `/etc/systemd/system/steam-switcher.{path,service}` | LXC 301 | Launcher Steam |
| `/etc/X11/xorg-steam.conf` | LXC 301 | Xorg 1080p pour Steam |
| `/home/kodi/.config/retroarch/retroarch.cfg` | LXC 301 | Config RetroArch (chmod 444!) |
| `/usr/local/bin/launch-retroarch` | LXC 301 | Script switching Kodi→RetroArch |
| `/usr/local/bin/launch-steam` | LXC 301 | Script switching Kodi→Steam |
| `/usr/local/bin/fix-kodi` | LXC 301 | Recovery Kodi (DRM reset + restart LXC) |
| `/usr/local/bin/force-stop-all` | LXC 301 | Kill tous les process media |

---

## 17. Tâches Restantes

### Priorité Haute
1. **`git push`** — Les manifests K8s avec les nouveaux paths `/mnt/data` n'ont pas été poussés vers GitHub. ArgoCD utilise encore potentiellement les anciens paths. Tant que ce push n'est pas fait, les symlinks de compatibilité sont essentiels.

### Priorité Moyenne
2. **Test DRM restoration** — Vérifier que le retour Steam → Kodi fonctionne correctement (mode DRM natif vs dégradé 1280x720)
3. **Test manette Proton** — Valider que `PROTON_USE_XALIA=0` fonctionne dans un vrai jeu
4. **retroarch.cfg chmod 444** — Vérifier que la protection est en place pour éviter les réécritures
5. **Secret renovate** — Créer `renovate-secret` dans le namespace renovate

### Priorité Basse (reporté)
6. **VLANs** — Segmentation réseau (VLAN 10 Mgmt, VLAN 20 Media, VLAN 30 K3s)
7. **RAM 32 Go** — Upgrade dual-channel pour bande passante iGPU
8. **BIOS UMA Frame Buffer** — Allocation statique 4 Go VRAM

---

## 🔑 Résumé des Règles d'Or

1. **Les deux LXC principaux (300, 301) sont PRIVILEGIÉS** → UID 1000 = UID 1000, pas d'offset
2. **`proc:rw sys:rw` est obligatoire** sur les deux LXC (K3s + Media)
3. **Seccomp désactivé uniquement sur LXC 301** (Steam en a besoin)
4. **`--disable=cloud-controller`** obligatoire pour K3s en LXC
5. **RetroArch réécrit sa config à chaque sortie** → `config_save_on_exit=false` + `chmod 444`
6. **Le switch ALSA IEC958 doit être activé** pour l'audio HDMI
7. **Restic ne remplace PAS les fichiers existants** → wiper avant restore
8. **ArgoCD JSON patch** (pas merge) pour désactiver selfHeal
9. **Bluetooth sur le PVE host**, pas dans le LXC
10. **Symlinker `debian-installation/` entier** pour Steam disk space
11. **DRM master = non récupérable** après Xorg → seul un restart LXC corrige
12. **Calico OUI, Cilium NON** en LXC (eBPF incompatible)
