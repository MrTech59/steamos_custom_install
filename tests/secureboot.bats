#!/usr/bin/env bats
# Unit tests for lib/secureboot.sh and bin/steamos-secureboot.
#
# These tests do not require root, a real disk, or actual UEFI hardware.  They
# exercise the signing logic, safety checks and CLI surface with mocked sbctl
# and system tools.

load helper

setup() {
  require_modern_bash
  REPO="${BATS_TEST_DIRNAME}/.."
  CALLS="$BATS_TEST_TMPDIR/sbctl-calls"
  export CALLS
}

@test "secureboot CLI --help documents every command" {
  run "$BASH44" "$REPO/bin/steamos-secureboot" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup"* ]]
  [[ "$output" == *"sign"* ]]
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"enroll"* ]]
  [[ "$output" == *"status"* ]]
}

@test "secureboot CLI refuses an unknown option" {
  run "$BASH44" "$REPO/bin/steamos-secureboot" --definitely-not-an-option setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "secureboot CLI requires a command" {
  run "$BASH44" "$REPO/bin/steamos-secureboot"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "secureboot_esp_files discovers the ESP boot files" {
  local tmp="$BATS_TEST_TMPDIR/esp"
  mkdir -p "$tmp/efi/boot" "$tmp/efi/steamos" "$tmp/SteamOS"
  touch "$tmp/efi/boot/bootx64.efi"
  touch "$tmp/efi/steamos/steamcl.efi"

  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    secureboot_esp_files "'"$tmp"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bootx64.efi"* ]]
  [[ "$output" == *"steamcl.efi"* ]]
}

@test "secureboot_efi_files discovers the per-partset GRUB image" {
  local tmp="$BATS_TEST_TMPDIR/efi"
  mkdir -p "$tmp/EFI/steamos"
  touch "$tmp/EFI/steamos/grubx64.efi"

  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    secureboot_efi_files "'"$tmp"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"grubx64.efi"* ]]
}

@test "secureboot_kernel_files discovers kernel images in /boot" {
  local tmp="$BATS_TEST_TMPDIR/rootfs"
  mkdir -p "$tmp/boot"
  touch "$tmp/boot/vmlinuz-linux-neptune-61"
  touch "$tmp/boot/initramfs-linux.img"

  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    secureboot_kernel_files "'"$tmp"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"vmlinuz-linux-neptune-61"* ]]
  [[ "$output" != *"initramfs-linux.img"* ]]
}

@test "secureboot_sign_esp signs bootx64.efi and steamcl.efi" {
  local tmp="$BATS_TEST_TMPDIR/esp"
  mkdir -p "$tmp/efi/boot" "$tmp/efi/steamos"
  touch "$tmp/efi/boot/bootx64.efi"
  touch "$tmp/efi/steamos/steamcl.efi"

  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    _secureboot_sbctl() { echo "$*" >> "'"$CALLS"'"; }
    sbverify() {
      if [[ "$1" == "--cert" ]]; then return 1; fi
      echo "No signature table present"
    }
    secureboot_sign_esp "'"$tmp"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bootx64.efi"* ]]
  [[ "$output" == *"steamcl.efi"* ]]
  [ -f "$CALLS" ]
  [[ "$(cat "$CALLS")" == *"sign -s $tmp/efi/boot/bootx64.efi"* ]]
  [[ "$(cat "$CALLS")" == *"sign -s $tmp/efi/steamos/steamcl.efi"* ]]
}

@test "secureboot_sign_efi signs the GRUB image" {
  local tmp="$BATS_TEST_TMPDIR/efi"
  mkdir -p "$tmp/EFI/steamos"
  touch "$tmp/EFI/steamos/grubx64.efi"

  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    _secureboot_sbctl() { echo "$*" >> "'"$CALLS"'"; }
    sbverify() {
      if [[ "$1" == "--cert" ]]; then return 1; fi
      echo "No signature table present"
    }
    secureboot_sign_efi "'"$tmp"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"grubx64.efi"* ]]
  [ -f "$CALLS" ]
  [[ "$(cat "$CALLS")" == *"sign -s $tmp/EFI/steamos/grubx64.efi"* ]]
}

@test "secureboot_sign_rootfs signs kernel images" {
  local tmp="$BATS_TEST_TMPDIR/rootfs"
  mkdir -p "$tmp/boot"
  touch "$tmp/boot/vmlinuz-linux-neptune-61"

  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    _secureboot_sbctl() { echo "$*" >> "'"$CALLS"'"; }
    sbverify() {
      if [[ "$1" == "--cert" ]]; then return 1; fi
      echo "No signature table present"
    }
    secureboot_sign_rootfs "'"$tmp"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"vmlinuz-linux-neptune-61"* ]]
  [ -f "$CALLS" ]
  [[ "$(cat "$CALLS")" == *"sign -s $tmp/boot/vmlinuz-linux-neptune-61"* ]]
}

@test "secureboot_sign_file skips files signed by another key" {
  local tmp="$BATS_TEST_TMPDIR"
  touch "$tmp/signed.efi"

  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    _secureboot_sbctl() { echo "$*" >> "'"$CALLS"'"; }
    # Pretend the file has an embedded signature that is not ours.
    sbverify() { return 1; }
    secureboot_file_is_unsigned() { return 1; }
    secureboot_sign_file "'"$tmp"'/signed.efi"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping file signed by another key"* ]]
  [[ ! -f "$CALLS" ]]
}

@test "secureboot_root_disk strips nvme partition suffix" {
  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    findmnt() { echo "/dev/nvme0n1p4"; }
    secureboot_root_disk
  '
  [ "$status" -eq 0 ]
  [ "$output" = "/dev/nvme0n1" ]
}

@test "secureboot_root_disk strips sata partition suffix" {
  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    findmnt() { echo "/dev/sda4"; }
    secureboot_root_disk
  '
  [ "$status" -eq 0 ]
  [ "$output" = "/dev/sda" ]
}

@test "enroll aborts when firmware is not in Setup Mode" {
  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    _secureboot_sbctl() { [[ "$1" != status ]] && echo "$*" >> "'"$CALLS"'"; }
    secureboot_require_root() { :; }
    secureboot_require_tools() { :; }
    secureboot_enroll_keys 1
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"Setup Mode"* ]]
  [[ "$output" == *"Microsoft"* ]]
  [[ ! -f "$CALLS" ]]
}

@test "enroll preserves Microsoft certificates" {
  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    _secureboot_sbctl() {
      echo "$*" >> "'"$CALLS"'"
      if [[ "$1" == status ]]; then
        echo "Secure Boot: Setup Mode"
      fi
    }
    secureboot_require_root() { :; }
    secureboot_require_tools() { :; }
    secureboot_backup_keys() { :; }
    secureboot_enroll_keys 1
  ' <<< "ENROLL"
  [ "$status" -eq 0 ]
  [ -f "$CALLS" ]
  [[ "$(cat "$CALLS")" == *"enroll-keys --microsoft"* ]]
}

@test "enroll requires explicit ENROLL confirmation" {
  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    _secureboot_sbctl() {
      if [[ "$1" == status ]]; then
        echo "Secure Boot: Setup Mode"
      else
        echo "$*" >> "'"$CALLS"'"
      fi
    }
    secureboot_require_root() { :; }
    secureboot_require_tools() { :; }
    secureboot_backup_keys() { :; }
    secureboot_enroll_keys 0
  ' <<< "maybe"
  [ "$status" -ne 0 ]
  [[ ! -f "$CALLS" ]]
}

@test "setup refuses to run outside installed SteamOS without --disk" {
  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    secureboot_require_root() { :; }
    secureboot_setup "" /bin/true
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"installed SteamOS"* ]]
}

@test "sign refuses to run without a disk or installed SteamOS" {
  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    secureboot_require_root() { :; }
    secureboot_require_tools() { :; }
    secureboot_sign_all
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"Pass --disk"* || "$output" == *"installed SteamOS"* ]]
}

@test "update command signs the inactive partset" {
  run "$BASH44" -c '
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/secureboot.sh"
    secureboot_require_root() { :; }
    secureboot_require_tools() { :; }
    secureboot_is_installed_steamos() { return 0; }
    secureboot_sign_inactive() { echo "sign-inactive-called"; }
    secureboot_sign_all() { echo "sign-all-called"; }
    steamos_secureboot_cmd="update"
    secureboot_update
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"sign-inactive-called"* ]]
}
