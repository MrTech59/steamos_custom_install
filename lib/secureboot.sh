#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# Generic UEFI Secure Boot helpers for SteamOS on normal x86-64 hardware.
#
# This deliberately does NOT contain Steam Deck firmware logic.  It uses the
# standard sbctl tooling and signs the binaries that the existing installer
# places on the ESP, the efi-A/efi-B partitions, and the rootfs-A/B partitions.
#
# Workflow is two-stage by design:
#   1. Install SteamOS normally with bin/steamos-install.
#   2. Boot into the installed SteamOS and run bin/steamos-secureboot setup.
#
# Key generation, signing and update persistence are handled here.  Key
# enrollment into firmware is never silent; see steamos-secureboot enroll.

[[ -n ${__LIB_SECUREBOOT_SH:-} ]] && return 0
__LIB_SECUREBOOT_SH=1

# shellcheck source=lib/log.sh
source "${LIBDIR:?LIBDIR must be set}/log.sh"
# shellcheck source=lib/disk.sh
source "${LIBDIR}/disk.sh"

# Where the helper keeps its own copy of the CLI, libraries and systemd units.
# This lives on a writable SteamOS partition (/var) so it survives OS updates.
: "${SB_STATE_DIR:=/var/lib/steamos-secureboot}"
export SB_STATE_DIR

# Default paths used by sbctl on a standard Arch/SteamOS install.
: "${SBCTL_CONF:=/etc/sbctl/sbctl.conf}"
export SBCTL_CONF

# Wrapper so every sbctl call uses the same configuration and disables
# landlock, which can block access to non-standard paths.
_secureboot_sbctl() {
  if [[ -f $SBCTL_CONF ]]; then
    cmd sbctl --config "$SBCTL_CONF" --disable-landlock "$@"
  else
    cmd sbctl --disable-landlock "$@"
  fi
}

# Read keydir/files_db from the active sbctl config file, or fall back to the
# SteamOS 0.17 defaults.
secureboot_load_sbctl_paths() {
  if [[ -f $SBCTL_CONF ]]; then
    # Strip trailing whitespace (including any Windows CR) so path parsing
    # does not silently mangle the directory names.
    SBCTL_KEY_DIR="$(grep -E '^keydir:' "$SBCTL_CONF" | head -1 | sed -e 's/^keydir:[[:space:]]*//' -e 's/[[:space:]]*$//')"
    SBCTL_DB_DIR="$(grep -E '^files_db:' "$SBCTL_CONF" | head -1 | sed -e 's/^files_db:[[:space:]]*//' -e 's/[[:space:]]*$//')"
    SBCTL_DB_DIR="${SBCTL_DB_DIR%/*}"
  fi
  : "${SBCTL_KEY_DIR:=/var/lib/sbctl/keys}"
  : "${SBCTL_DB_DIR:=/var/lib/sbctl}"
  export SBCTL_KEY_DIR SBCTL_DB_DIR
}

# Explicit list of boot-chain files we sign.  We do not sign arbitrary files by
# glob, because the ESP and efi partitions may contain third-party tools or
# rescue binaries that should not be re-signed.
secureboot_esp_files() {
  local mp="${1:-/esp}"
  local f
  for f in \
    "$mp/efi/boot/bootx64.efi" \
    "$mp/efi/steamos/steamcl.efi"; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done
}

secureboot_efi_files() {
  local mp="${1:-}"
  [[ -n $mp ]] || return 0
  local f
  for f in \
    "$mp/EFI/steamos/grubx64.efi"; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done
}

secureboot_kernel_files() {
  local mp="${1:-/}"
  local f
  for f in "$mp"/boot/vmlinuz-*; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done
}

# -----------------------------------------------------------------------------
# Tool checks
# -----------------------------------------------------------------------------

secureboot_require_root() {
  [[ $EUID -eq 0 ]] || die "Secure Boot setup must run as root."
}

secureboot_require_tools() {
  local missing=()
  if ! command -v sbctl >/dev/null 2>&1; then
    missing+=(sbctl)
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    missing+=(openssl)
  fi
  [[ ${#missing[@]} -eq 0 ]] && return 0

  eerr "Missing required tool(s): ${missing[*]}"
  if [[ " ${missing[*]} " == *" sbctl "* ]]; then
    eerr "Install sbctl from the SteamOS repositories:"
    eerr "  sudo steamos-readonly disable"
    eerr "  sudo pacman -S sbctl"
    eerr "  sudo steamos-readonly enable"
  fi
  die "Cannot continue with tools missing."
}

# -----------------------------------------------------------------------------
# Environment detection
# -----------------------------------------------------------------------------

# True when we appear to be running inside an installed SteamOS system.
# /esp is the ESP; /efi is the active efi-A/B partition; / is the rootfs.
secureboot_is_installed_steamos() {
  [[ -d /esp/efi/steamos && -d /efi/EFI/steamos && -d /efi/SteamOS ]]
}

# Resolve the whole disk that holds the running root filesystem.
secureboot_root_disk() {
  local rootdev part base
  rootdev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ -z $rootdev ]]; then
    die "Could not determine the root device. Pass --disk explicitly."
  fi

  # Strip sub-device decorations (LUKS, LVM, btrfs subvol source notation).
  rootdev="${rootdev%%\[*}"
  rootdev="${rootdev%%-*}"
  [[ -L $rootdev ]] && rootdev="$(readlink -f "$rootdev")"

  part="${rootdev##*/}"
  base="${part}"

  # nvme0n1p4 -> nvme0n1, mmcblk0p4 -> mmcblk0, sda4 -> sda
  if [[ $base =~ ^(.*[0-9])p[0-9]+$ ]]; then
    base="${BASH_REMATCH[1]}"
  elif [[ $base =~ ^([^0-9]*[a-z])[0-9]+$ ]]; then
    base="${BASH_REMATCH[1]}"
  fi

  echo "/dev/$base"
}

# Return A or B for the currently booted partset.
secureboot_active_partset() {
  if command -v steamos-bootconf >/dev/null 2>&1; then
    steamos-bootconf this-image 2>/dev/null || true
  fi
}

# Return A or B for the partset that will be used on the next boot.
secureboot_selected_partset() {
  if command -v steamos-bootconf >/dev/null 2>&1; then
    steamos-bootconf selected-image 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
# Key management
# -----------------------------------------------------------------------------

secureboot_create_keys() {
  estat "Checking sbctl key state"

  secureboot_load_sbctl_paths

  if _secureboot_sbctl status >/dev/null 2>&1; then
    ewarn "sbctl keys already exist."
    ewarn "If you want a fresh key hierarchy, delete $SBCTL_KEY_DIR first."
    return 0
  fi

  # Pin keys and database under /var/lib/steamos-secureboot so they survive
  # OS updates and are easy to back up.
  if [[ ! -f $SBCTL_CONF ]]; then
    cmd mkdir -p "$(dirname "$SBCTL_CONF")"
    cat > "$SBCTL_CONF" <<EOF
keydir: $SB_STATE_DIR/keys
guid: $SB_STATE_DIR/GUID
files_db: $SB_STATE_DIR/files.json
bundles_db: $SB_STATE_DIR/bundles.json
landlock: false
EOF
    chmod 644 "$SBCTL_CONF"
  fi

  secureboot_load_sbctl_paths
  cmd mkdir -p "$SBCTL_KEY_DIR"
  cmd mkdir -p "$SBCTL_DB_DIR"
  _secureboot_sbctl create-keys

  estat "Keys created in $SBCTL_KEY_DIR"
}

secureboot_backup_keys() {
  local backup_dir="${1:-}"
  secureboot_load_sbctl_paths

  if [[ -z $backup_dir ]]; then
    backup_dir="$SB_STATE_DIR/backup/$(date +%Y%m%d-%H%M%S)"
  fi

  if [[ -e $backup_dir && ! -d $backup_dir ]]; then
    die "Backup path $backup_dir exists and is not a directory."
  fi

  cmd mkdir -p "$backup_dir"
  if [[ -d $SBCTL_KEY_DIR ]]; then
    cmd cp -a "$SBCTL_KEY_DIR" "$backup_dir/keys"
  fi
  if [[ -d $SBCTL_DB_DIR ]]; then
    cmd cp -a "$SBCTL_DB_DIR" "$backup_dir/sbctl-db"
  fi
  if [[ -f $SBCTL_CONF ]]; then
    cmd cp -a "$SBCTL_CONF" "$backup_dir/sbctl.conf"
  fi

  estat "Keys backed up to $backup_dir"
  einfo "Store this backup somewhere safe. Without it you cannot recover from"
  einfo "a lost key or re-sign files after a firmware reset."
}

# -----------------------------------------------------------------------------
# Partition mounting
# -----------------------------------------------------------------------------

_secureboot_mktemp_mount() {
  mktemp -d -t steamos-secureboot-XXXXXX
}

# Mount all five SteamOS boot partitions for a specific whole disk.
# Echoes five mountpoints: esp efi-A efi-B rootfs-A rootfs-B.
secureboot_mount_disk_partitions() {
  local disk="$1" suffix part i dev mp
  validate_disk "$disk"
  suffix="$(disk_suffix "$disk")"

  local -a mps=()
  for i in 1 2 3 4 5; do
    dev="${disk}${suffix}${i}"
    mp="$(_secureboot_mktemp_mount)"
    mps+=("$mp")
    cmd mkdir -p "$mp"
    if [[ $i -le 3 ]]; then
      cmd mount -o rw "$dev" "$mp"
    else
      # Kernel images on the rootfs must be writable so we can sign them.
      cmd mount -o rw,subvol=/ "$dev" "$mp" || cmd mount -o rw "$dev" "$mp"
    fi
  done

  printf '%s\n' "${mps[@]}"
}

# Mount the inactive efi and rootfs partitions on an installed SteamOS system.
# Echoes two mountpoints: inactive-efi inactive-rootfs.
secureboot_mount_inactive_partitions() {
  local active inactive
  active="$(secureboot_active_partset)"
  [[ $active == A || $active == B ]] || die "Could not determine active partset."

  if [[ $active == A ]]; then
    inactive="B"
  else
    inactive="A"
  fi

  local efi_dev rootfs_dev mp_efi mp_root
  efi_dev="/dev/disk/by-partlabel/efi-${inactive}"
  rootfs_dev="/dev/disk/by-partlabel/rootfs-${inactive}"

  if [[ ! -e $efi_dev ]]; then
    local disk suffix
    disk="$(secureboot_root_disk)"
    suffix="$(disk_suffix "$disk")"
    efi_dev="${disk}${suffix}$((inactive == A ? 2 : 3))"
    rootfs_dev="${disk}${suffix}$((inactive == A ? 4 : 5))"
  fi

  mp_efi="$(_secureboot_mktemp_mount)"
  cmd mkdir -p "$mp_efi"
  cmd mount -o rw "$efi_dev" "$mp_efi"

  mp_root="$(_secureboot_mktemp_mount)"
  cmd mkdir -p "$mp_root"
  cmd mount -o rw,subvol=/ "$rootfs_dev" "$mp_root" || cmd mount -o rw "$rootfs_dev" "$mp_root"

  printf '%s\n' "$mp_efi" "$mp_root"
}

secureboot_umount_partitions() {
  local mp
  for mp in "$@"; do
    [[ -d $mp ]] || continue
    if findmnt -n -o TARGET "$mp" >/dev/null 2>&1; then
      cmd umount -R "$mp" || ewarn "umount $mp failed"
    fi
    if [[ $mp == /tmp/steamos-secureboot-* ]]; then
      rmdir "$mp" 2>/dev/null || true
    fi
  done
}

# -----------------------------------------------------------------------------
# Signing
# -----------------------------------------------------------------------------

# Return 0 if the file already has a valid signature from our db key.
secureboot_signed_by_us() {
  local file="$1" cert
  secureboot_load_sbctl_paths
  cert="$SBCTL_KEY_DIR/db/db.pem"
  [[ -f $cert ]] || return 1

  if command -v sbverify >/dev/null 2>&1; then
    sbverify --cert "$cert" "$file" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Return 0 if the file has no embedded PE/COFF signature at all.
secureboot_file_is_unsigned() {
  local file="$1" out
  if command -v sbverify >/dev/null 2>&1; then
    out="$(sbverify --list "$file" 2>&1 || true)"
    if [[ $out == *"No signature table present"* || $out == *"No signatures found"* ]]; then
      return 0
    fi
    return 1
  fi
  # Without sbverify we conservatively assume the file is unsigned.
  return 0
}

# Sign a single file, idempotently.
secureboot_sign_file() {
  local file="$1"

  if secureboot_signed_by_us "$file"; then
    einfo "Already signed by us: $file"
    return 0
  fi

  # Never append our signature to a file that is already signed by someone else
  # (e.g. a future Microsoft-signed shim).  That could create a multi-signature
  # binary that some firmware refuses to load.
  if ! secureboot_file_is_unsigned "$file"; then
    ewarn "Skipping file signed by another key: $file"
    return 0
  fi

  einfo "Signing $file"
  _secureboot_sbctl sign -s "$file"
}

secureboot_sign_esp() {
  local mp="${1:-/esp}" file count=0
  local -a files=()
  if [[ -n ${DRY_RUN:-} ]]; then
    files=("$mp/efi/boot/bootx64.efi" "$mp/efi/steamos/steamcl.efi")
  else
    readarray -t files < <(secureboot_esp_files "$mp")
  fi
  estat "Signing ESP files under $mp"
  for file in "${files[@]}"; do
    secureboot_sign_file "$file"
    count=$((count + 1))
  done
  [[ $count -gt 0 ]] || ewarn "No ESP boot files found under $mp"
}

secureboot_sign_efi() {
  local mp="${1:-}" file count=0
  local -a files=()
  [[ -n $mp ]] || die "secureboot_sign_efi: no mountpoint given"
  if [[ -n ${DRY_RUN:-} ]]; then
    files=("$mp/EFI/steamos/grubx64.efi")
  else
    readarray -t files < <(secureboot_efi_files "$mp")
  fi
  estat "Signing efi partition files under $mp"
  for file in "${files[@]}"; do
    secureboot_sign_file "$file"
    count=$((count + 1))
  done
  [[ $count -gt 0 ]] || ewarn "No efi boot files found under $mp"
}

secureboot_sign_rootfs() {
  local mp="${1:-/}" file count=0
  local -a files=()
  if [[ -n ${DRY_RUN:-} ]]; then
    files=("$mp/boot/vmlinuz-*")
  else
    readarray -t files < <(secureboot_kernel_files "$mp")
  fi
  estat "Signing kernel files under $mp/boot"
  for file in "${files[@]}"; do
    secureboot_sign_file "$file"
    count=$((count + 1))
  done
  [[ $count -gt 0 ]] || ewarn "No kernel files found under $mp/boot"
}

# Sign every boot file for the current installation or for a whole disk.
secureboot_sign_all() {
  local disk="${1:-}"

  secureboot_require_root
  secureboot_require_tools

  if [[ -n $disk ]]; then
    local -a mounts=()
    mapfile -t mounts < <(secureboot_mount_disk_partitions "$disk")
    [[ ${#mounts[@]} -eq 5 ]] || die "Expected 5 mounted partitions, got ${#mounts[@]}"

    trap 'secureboot_umount_partitions "${mounts[@]}"' RETURN
    secureboot_sign_esp "${mounts[0]}"
    secureboot_sign_efi "${mounts[1]}"
    secureboot_sign_efi "${mounts[2]}"
    secureboot_sign_rootfs "${mounts[3]}"
    secureboot_sign_rootfs "${mounts[4]}"
  elif secureboot_is_installed_steamos; then
    local -a inactive=()
    mapfile -t inactive < <(secureboot_mount_inactive_partitions)
    [[ ${#inactive[@]} -eq 2 ]] || die "Expected 2 mounted inactive partitions"

    trap 'secureboot_umount_partitions "${inactive[@]}"' RETURN
    secureboot_sign_esp /esp
    secureboot_sign_efi /efi
    secureboot_sign_rootfs /
    secureboot_sign_efi "${inactive[0]}"
    secureboot_sign_rootfs "${inactive[1]}"
  else
    die "Pass --disk or run this from the installed SteamOS system."
  fi
}

# Sign the inactive partset.  This is called by the post-update hook on the
# active system, before the reboot that will switch to the updated partset.
secureboot_sign_inactive() {
  secureboot_require_root
  secureboot_require_tools

  if ! secureboot_is_installed_steamos; then
    die "update must run from the installed SteamOS system (where /esp and /efi are mounted)."
  fi

  local -a mps=()
  mapfile -t mps < <(secureboot_mount_inactive_partitions)
  [[ ${#mps[@]} -eq 2 ]] || die "Could not mount inactive partitions."

  local inactive_efi="${mps[0]}"
  local inactive_rootfs="${mps[1]}"

  secureboot_sign_efi "$inactive_efi"
  secureboot_sign_rootfs "$inactive_rootfs"

  secureboot_umount_partitions "$inactive_efi" "$inactive_rootfs"
}

# Thin wrapper used by the CLI update command so tests can hook it.
secureboot_update() {
  secureboot_sign_inactive
}

# -----------------------------------------------------------------------------
# Status and enrollment
# -----------------------------------------------------------------------------

secureboot_status_report() {
  estat "sbctl status"
  _secureboot_sbctl status 2>&1 || true

  estat "Signed file database"
  _secureboot_sbctl list-files 2>&1 || true

  estat "Unsigned files in database"
  _secureboot_sbctl verify 2>&1 || true
}

secureboot_enroll_keys() {
  local yes="${1:-0}"

  secureboot_require_root
  secureboot_require_tools

  estat "Checking Secure Boot mode"
  local status
  status="$(_secureboot_sbctl status 2>&1 || true)"

  if [[ $status != *"Setup Mode"* && $status != *"setup mode"* ]]; then
    eerr "Firmware is not in Setup Mode."
    eerr ""
    eerr "To enroll keys safely:"
    eerr "  1. Back up your keys (steamos-secureboot setup --key-backup ...)."
    eerr "  2. Reboot into UEFI firmware setup."
    eerr "  3. Clear/reset the Platform Key (PK) to enter Setup Mode."
    eerr "     Do NOT delete the Microsoft certificates unless you want to"
    eerr "     break Windows dual-boot."
    eerr "  4. Back in SteamOS, run: sudo steamos-secureboot enroll"
    die "Enrollment aborted: firmware not in Setup Mode."
  fi

  if [[ $yes != 1 ]]; then
    ewarn "This will write your custom Platform Key, Key Exchange Key and"
    ewarn "signature database into UEFI NVRAM. Microsoft certificates will be"
    ewarn "preserved. Type ENROLL to proceed:"
    local confirm
    read -r confirm || true
    [[ ${confirm:-} == "ENROLL" ]] || die "Enrollment aborted by user."
  fi

  secureboot_backup_keys

  estat "Enrolling keys (Microsoft certificates preserved)"
  _secureboot_sbctl enroll-keys --microsoft
}

# -----------------------------------------------------------------------------
# Update persistence
# -----------------------------------------------------------------------------

secureboot_install_update_service() {
  local script_source="${1:-}"
  if [[ -z $script_source ]]; then
    die "Internal error: no CLI path passed to secureboot_install_update_service."
  fi

  local cli_dir lib_dir
  cli_dir="$(cd -- "$(dirname -- "$script_source")" && pwd)"
  lib_dir="$cli_dir/../lib"

  cmd mkdir -p "$SB_STATE_DIR"
  cmd chmod 700 "$SB_STATE_DIR"
  cmd mkdir -p "$SB_STATE_DIR/lib"
  cmd cp -a "$script_source" "$SB_STATE_DIR/steamos-secureboot"
  cmd chmod 755 "$SB_STATE_DIR/steamos-secureboot"
  cmd cp -a "$lib_dir"/*.sh "$SB_STATE_DIR/lib/"

  # Boot-time service: re-sign anything that changed on this boot (e.g. after
  # steamos-install-grub.service or steamos-install-steamcl.service recreated
  # files).  It runs after those services so it signs their output.
  cat > /tmp/steamos-secureboot.service <<'EOF'
[Unit]
Description=Re-sign SteamOS boot files for UEFI Secure Boot
Documentation=https://github.com/louij2/steamos_custom_install/blob/main/docs/secureboot.md
After=local-fs.target efi.mount esp.mount steamos-install-grub.service steamos-install-steamcl.service
Before=sddm.service
ConditionPathExists=/var/lib/steamos-secureboot/files.json

[Service]
Type=oneshot
ExecStart=/var/lib/steamos-secureboot/steamos-secureboot sign
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  cmd install -m 644 /tmp/steamos-secureboot.service /etc/systemd/system/steamos-secureboot.service

  # Post-update path unit: when SteamOS marks the system as updated, sign the
  # inactive partset BEFORE the reboot that will switch to it.
  cat > /tmp/steamos-secureboot-update.path <<'EOF'
[Unit]
Description=Watch for SteamOS update marker to sign the inactive partset
Documentation=https://github.com/louij2/steamos_custom_install/blob/main/docs/secureboot.md

[Path]
PathExists=/var/lib/steamos-atomupd/system-updated

[Install]
WantedBy=multi-user.target
EOF
  cmd install -m 644 /tmp/steamos-secureboot-update.path /etc/systemd/system/steamos-secureboot-update.path

  cat > /tmp/steamos-secureboot-update.service <<'EOF'
[Unit]
Description=Sign inactive SteamOS partset after an update
Documentation=https://github.com/louij2/steamos_custom_install/blob/main/docs/secureboot.md
After=local-fs.target efi.mount esp.mount
Before=reboot.target poweroff.target shutdown.target sddm.service
ConditionPathExists=/var/lib/steamos-atomupd/system-updated

[Service]
Type=oneshot
ExecStart=/var/lib/steamos-secureboot/steamos-secureboot update
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
EOF
  cmd install -m 644 /tmp/steamos-secureboot-update.service /etc/systemd/system/steamos-secureboot-update.service

  rm -f /tmp/steamos-secureboot.service /tmp/steamos-secureboot-update.path /tmp/steamos-secureboot-update.service

  cmd systemctl daemon-reload
  cmd systemctl enable steamos-secureboot.service
  cmd systemctl enable steamos-secureboot-update.path

  estat "Installed update-persistence units"
  einfo "steamos-secureboot.service re-signs files on every boot."
  einfo "steamos-secureboot-update.path signs the inactive partset when an"
  einfo "update is applied, before the reboot that switches to it."
}

secureboot_print_enrollment_instructions() {
  cat <<'EOF'

------------------------------------------------------------------
Secure Boot key enrollment must be performed manually.

The helper has signed the current boot chain with your own keys.
It has NOT changed any firmware setting and has NOT enabled Secure
Boot.  You must enroll the keys before enabling Secure Boot.

1. Back up your keys (already done if you passed --key-backup).
   Without the backup you cannot recover from a lost key or re-sign
   files after a firmware reset.

2. Reboot into your UEFI firmware setup (usually F2/Del during POST).

3. Put Secure Boot into Setup Mode.  On most boards this means:
     - select "Restore Factory Keys" or "Clear Secure Boot keys", or
     - delete the Platform Key (PK) entry.
   Do NOT delete the Microsoft Windows Production CA or other
   Microsoft certificates if you need Windows dual-boot.

4. Boot back into the installed SteamOS.

5. Run:

       sudo steamos-secureboot enroll

   This calls `sbctl enroll-keys --microsoft`, which installs your
   custom keys while keeping Microsoft's certificates intact.

6. Reboot again, enter firmware setup, and turn Secure Boot ON.

7. (Optional) Leave Setup Mode by setting the Platform Key.  sbctl
   does this automatically during enrollment.

If anything goes wrong, disable Secure Boot in firmware setup and
boot normally; the unsigned files are still present and will boot
with Secure Boot off.

After each SteamOS update, the helper normally signs the new files
automatically.  As a fallback you can also run:

       sudo steamos-secureboot update

before rebooting if a pending update is reported.

------------------------------------------------------------------
EOF
}

# -----------------------------------------------------------------------------
# Setup orchestration
# -----------------------------------------------------------------------------

secureboot_setup() {
  local backup_dir="${1:-}"
  local cli_path="${2:-}"

  secureboot_require_root
  secureboot_require_tools

  if ! secureboot_is_installed_steamos; then
    die "Secure Boot setup must run from the installed SteamOS system (where /esp and /efi are mounted)."
  fi

  secureboot_create_keys
  secureboot_backup_keys "${backup_dir:-}"
  secureboot_sign_all
  secureboot_install_update_service "$cli_path"
  secureboot_print_enrollment_instructions
}
