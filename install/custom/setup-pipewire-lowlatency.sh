#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="pipewire-lowlatency.service"
SERVICE_PATH="$HOME/.config/systemd/user/$SERVICE_NAME"

echo "==> Installing PipeWire + JACK routing tools"
sudo pacman -S --needed --noconfirm \
  pipewire \
  wireplumber \
  pipewire-pulse \
  qpwgraph

echo "==> Enabling PipeWire services"
systemctl --user enable --now \
  pipewire.service \
  wireplumber.service \
  pipewire-pulse.service

echo "==> Writing PipeWire low-latency systemd service"
mkdir -p "$HOME/.config/systemd/user"

cat > "$SERVICE_PATH" <<'EOF'
[Unit]
Description=Force PipeWire low-latency clock settings
After=pipewire.service wireplumber.service
Wants=pipewire.service wireplumber.service

[Service]
Type=oneshot
ExecStart=/usr/bin/pw-metadata -n settings 0 clock.force-rate 48000
ExecStart=/usr/bin/pw-metadata -n settings 0 clock.force-quantum 128

[Install]
WantedBy=default.target
EOF

echo "==> Reloading systemd user units"
systemctl --user daemon-reload
systemctl --user enable --now pipewire-lowlatency.service

echo "==> Restarting PipeWire stack"
systemctl --user restart pipewire.service wireplumber.service pipewire-pulse.service

echo
echo "=================================================="
echo " DONE"
echo
echo "Verify:"
echo "  pw-metadata -n settings 0 | grep -E 'clock\\.force-rate|clock\\.force-quantum'"
echo "  pw-top   # should show Quantum = 128"
echo
echo "Launch JACK router with:"
echo "  qpwgraph"
echo "=================================================="
