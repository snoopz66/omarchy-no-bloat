#!/usr/bin/env bash
set -euo pipefail

# Arch Linux setup:
# - Native Bitwig/Reaper + yabridge (pacman)
# - Bottles (Flatpak)
# - yabridge-bottles-wineloader (WINELOADER wrapper + env config)
# - Realtime audio limits so yabridge doesn't warn about memlock/realtime
#
# NOTE:
# - You MUST log out/in (or reboot) after this so group membership + systemd limits apply.

need_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "==> Installing base packages (pacman)"
sudo pacman -S --needed --noconfirm \
  git curl \
  yabridge yabridgectl \
  flatpak \
  realtime-privileges

echo "==> Adding user to realtime group"
sudo gpasswd -a "$USER" realtime || true

# Ensure systemd user sessions (what launches your DAW) also get proper limits
echo "==> Setting systemd user session realtime limits (memlock/rtprio/rttime)"
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/limits.conf >/dev/null <<'EOF'
[Service]
LimitMEMLOCK=infinity
LimitRTPRIO=95
LimitRTTIME=infinity
EOF

sudo systemctl daemon-reload

# yabridge-bottles-wineloader uses yq to parse Bottles' config
if ! need_cmd yq; then
  echo "==> Installing yq (required by yabridge-bottles-wineloader)"
  if sudo pacman -S --needed --noconfirm yq; then
    :
  else
    echo "ERROR: 'yq' not found in pacman on your system."
    echo "Install it via AUR (e.g. 'yay -S yq') then re-run this script."
    exit 1
  fi
fi

echo "==> Setting up Flathub + installing Bottles (Flatpak)"
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.usebottles.bottles

echo "==> Installing yabridge-bottles-wineloader"
mkdir -p "$HOME/.local/bin"
curl -fsSL \
  https://raw.githubusercontent.com/microfortnight/yabridge-bottles-wineloader/main/wineloader.sh \
  -o "$HOME/.local/bin/wineloader.sh"
chmod +x "$HOME/.local/bin/wineloader.sh"

mkdir -p "$HOME/.config/environment.d"
cat > "$HOME/.config/environment.d/wineloader.conf" <<EOF
# Used by yabridge to choose the Wine loader. This script makes yabridge use the
# Wine runner configured for each Bottles bottle (Flatpak).
WINELOADER=$HOME/.local/bin/wineloader.sh
EOF

echo "==> Writing notes / quick commands"
cat > "$HOME/.config/yabridge-bottles-setup.txt" <<'EOF'
Realtime audio sanity checks (after reboot / logout+login):

  ulimit -l     # should be 'unlimited' or very large (not 8192)
  ulimit -r     # should be high (e.g. 95)
  id -nG | grep -w realtime

Check limits for a running DAW process:
  PID="$(pidof bitwig-studio || pidof reaper)"
  grep -E 'Max locked memory|Max realtime priority|Max realtime timeout' /proc/$PID/limits

Bottles (Flatpak) bottle prefixes live here:
  ~/.var/app/com.usebottles.bottles/data/bottles/bottles/<BOTTLE_NAME>/

Typical VST3 path inside a bottle:
  .../drive_c/Program Files/Common Files/VST3/

Add VST paths to yabridge (example):
  B="$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles/MyBottle"
  yabridgectl add "$B/drive_c/Program Files/Common Files/VST3"
  yabridgectl sync

Verify WINELOADER is visible:
  systemctl --user show-environment | grep WINELOADER

If it is NOT visible after logout/login, launch your DAW like:
  env WINELOADER="$HOME/.local/bin/wineloader.sh" bitwig-studio
EOF

echo
echo "DONE."
echo "Required next step:"
echo "  Reboot (recommended) or at least log out/in so:"
echo "   - realtime group membership applies"
echo "   - systemd user limits apply"
echo "   - WINELOADER env is loaded"
echo
echo "After reboot, verify:"
echo "  ulimit -l   (expect unlimited/large)"
echo "  systemctl --user show-environment | grep WINELOADER"
echo
echo "Notes saved to: $HOME/.config/yabridge-bottles-setup.txt"

