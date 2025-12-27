#!/usr/bin/env bash
set -euo pipefail

log()  { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die()  { printf "\n[ERR ] %s\n" "$*" >&2; exit 1; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    exec sudo bash "${BASH_SOURCE[0]}" "$@"
  fi
}

install_amd_ucode() {
  log "Installing AMD microcode package (amd-ucode)..."
  pacman -Syu --needed --noconfirm amd-ucode
}

is_systemd_boot() {
  # systemd-boot installs a loader dir in the ESP
  [[ -d /boot/loader/entries ]] || [[ -d /efi/loader/entries ]]
}

is_grub() {
  command -v grub-mkconfig >/dev/null 2>&1 && \
  ( [[ -d /boot/grub ]] || [[ -d /boot/grub2 ]] || [[ -d /efi/EFI ]] )
}

ensure_ucode_systemd_boot_entry() {
  local entries_dir=""
  if [[ -d /boot/loader/entries ]]; then
    entries_dir="/boot/loader/entries"
  elif [[ -d /efi/loader/entries ]]; then
    entries_dir="/efi/loader/entries"
  else
    die "systemd-boot detected but entries directory not found."
  fi

  log "Configuring systemd-boot entries in: $entries_dir"

  shopt -s nullglob
  local changed=0
  local entry
  for entry in "$entries_dir"/*.conf; do
    log "Checking entry: $entry"

    # Skip if it's not a Linux entry (best-effort)
    if ! grep -qE '^\s*linux\s+' "$entry"; then
      warn "No 'linux' line found; skipping: $entry"
      continue
    fi

    # If it already has amd-ucode, ensure ordering is correct.
    if grep -qE '^\s*initrd\s+/?amd-ucode\.img\s*$' "$entry"; then
      # Ensure amd-ucode is BEFORE the first initramfs initrd line.
      # We'll normalize by:
      # 1) Removing all amd-ucode initrd lines
      # 2) Inserting a single one right before the first initramfs initrd
      local tmp
      tmp="$(mktemp)"
      awk '
        BEGIN { inserted=0 }
        # drop any existing amd-ucode initrd lines
        /^[[:space:]]*initrd[[:space:]]+\/?amd-ucode\.img[[:space:]]*$/ { next }

        # before the first initrd line that looks like initramfs, insert amd-ucode
        /^[[:space:]]*initrd[[:space:]]+\/?initramfs-.*\.img([[:space:]]*)$/ && inserted==0 {
          print "initrd  /amd-ucode.img"
          inserted=1
          print
          next
        }

        { print }
        END {
          # If no initramfs line matched, we do not insert here (handled below).
        }
      ' "$entry" >"$tmp"

      # If there was no initramfs-* initrd line, insert after linux line as fallback.
      if ! grep -qE '^\s*initrd\s+/?amd-ucode\.img\s*$' "$tmp"; then
        awk '
          BEGIN { inserted=0 }
          /^[[:space:]]*linux[[:space:]]+/ && inserted==0 {
            print
            print "initrd  /amd-ucode.img"
            inserted=1
            next
          }
          { print }
        ' "$tmp" >"${tmp}.2"
        mv "${tmp}.2" "$tmp"
      fi

      if ! cmp -s "$entry" "$tmp"; then
        cp -a "$entry" "${entry}.bak.$(date +%Y%m%d-%H%M%S)"
        mv "$tmp" "$entry"
        changed=1
        log "Updated ordering / normalized amd-ucode line in: $entry"
      else
        rm -f "$tmp"
        log "No change needed: $entry"
      fi

    else
      # No amd-ucode line: insert it before the first initramfs initrd (preferred),
      # otherwise right after linux line.
      local tmp
      tmp="$(mktemp)"
      awk '
        BEGIN { inserted=0 }
        /^[[:space:]]*initrd[[:space:]]+\/?initramfs-.*\.img([[:space:]]*)$/ && inserted==0 {
          print "initrd  /amd-ucode.img"
          inserted=1
          print
          next
        }
        { print }
        END { }
      ' "$entry" >"$tmp"

      if ! grep -qE '^\s*initrd\s+/?amd-ucode\.img\s*$' "$tmp"; then
        awk '
          BEGIN { inserted=0 }
          /^[[:space:]]*linux[[:space:]]+/ && inserted==0 {
            print
            print "initrd  /amd-ucode.img"
            inserted=1
            next
          }
          { print }
        ' "$tmp" >"${tmp}.2"
        mv "${tmp}.2" "$tmp"
      fi

      cp -a "$entry" "${entry}.bak.$(date +%Y%m%d-%H%M%S)"
      mv "$tmp" "$entry"
      changed=1
      log "Inserted amd-ucode initrd line into: $entry"
    fi
  done

  if [[ $changed -eq 0 ]]; then
    log "systemd-boot entries already look good."
  else
    log "systemd-boot entries updated. Backups were created alongside entries."
  fi
}

regen_grub_config() {
  # Common grub.cfg locations
  local out=""
  if [[ -f /boot/grub/grub.cfg ]]; then
    out="/boot/grub/grub.cfg"
  elif [[ -f /boot/grub2/grub.cfg ]]; then
    out="/boot/grub2/grub.cfg"
  else
    # Fallback typical Arch location
    out="/boot/grub/grub.cfg"
  fi

  log "Regenerating GRUB config: $out"
  grub-mkconfig -o "$out"
}

post_checks() {
  log "Post-checks:"
  if [[ -f /boot/amd-ucode.img ]]; then
    echo " - Found /boot/amd-ucode.img"
  elif [[ -f /efi/amd-ucode.img ]]; then
    echo " - Found /efi/amd-ucode.img"
  else
    warn "amd-ucode.img not found in /boot or /efi. This can be OK depending on your ESP mount, but verify."
  fi

  echo " - After reboot, verify with:"
  echo "   dmesg | grep -i microcode"
  echo "   dmesg | grep -i rdseed"
}

main() {
  need_root "$@"
  install_amd_ucode

  if is_systemd_boot; then
    ensure_ucode_systemd_boot_entry
  elif is_grub; then
    regen_grub_config
  else
    warn "Could not confidently detect systemd-boot or GRUB."
    warn "amd-ucode is installed, but you must ensure your bootloader loads it early."
    warn "For systemd-boot: add 'initrd  /amd-ucode.img' BEFORE your initramfs initrd line in each entry."
    warn "For GRUB: run 'grub-mkconfig -o /boot/grub/grub.cfg'."
  fi

  post_checks
  log "Done. Reboot to apply microcode early in boot."
}

main "$@"
