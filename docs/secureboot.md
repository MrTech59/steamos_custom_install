# Generic UEFI Secure Boot for SteamOS on a normal PC

This document describes the Secure Boot support added to
`louij2/steamos_custom_install`.  It is intentionally **not** Steam Deck
specific: it uses the standard `sbctl` tooling and works on a normal x86-64
motherboard such as an MSI X570.

## What this is and is not

**Goals**

- Keep the existing installer, SATA fixes, and A/B partition layout exactly as
  they are.
- Sign the EFI binaries and kernels that the installer writes to disk.
- Persist signatures across SteamOS A/B updates.
- Preserve Microsoft Secure Boot certificates for Windows dual-boot.
- Never silently enable Secure Boot or silently enroll keys.
- Never flash motherboard firmware.

**Non-goals**

- This does **not** add Steam Deck firmware logic (BIOS/controller updates
  remain disabled by default).
- This does **not** modify the Microsoft key database unless you explicitly
  choose to.
- This does **not** touch any disk other than the one you select.
- This does **not** run from the recovery USB as part of the initial install.
  Key generation and signing happen after you have booted into the installed
  SteamOS.

## Boot chain findings

From inspecting `lib/steps.sh`, `lib/disk.sh`, the upstream
`repair_device.sh`, the SteamOS recovery image, and the VM test:

- The target disk uses an 8-partition GPT layout:
  1. `esp`      64 MiB VFAT  — the EFI System Partition
  2. `efi-A`    32 MiB VFAT  — per-partset boot files for A
  3. `efi-B`    32 MiB VFAT  — per-partset boot files for B
  4. `rootfs-A`  ~5 GiB btrfs — SteamOS root A
  5. `rootfs-B`  ~5 GiB btrfs — SteamOS root B
  6. `var-A`    ext4
  7. `var-B`    ext4
  8. `home`     ext4
- `finalize_part()` creates `/efi/SteamOS` and `/esp/SteamOS/conf` inside the
  chroot, runs `steamos-partsets`, `steamos-bootconf`, `grub-mkimage` and
  `update-grub`.
- The final install step runs `steamcl-install --flags restricted
  --force-extra-removable`, which writes the UEFI boot entry and copies the
  fallback removable path `EFI/Boot/bootx64.efi` and the SteamCL loader
  `EFI/steamos/steamcl.efi` to the ESP.
- In the installed system the ESP is mounted at `/esp`, the active per-partset
  EFI partition at `/efi`, and kernels live under `/boot`.

The verified chain on a generic PC is therefore:

```
UEFI -> /esp/efi/boot/bootx64.efi  (fallback loader)
     -> /esp/efi/steamos/steamcl.efi
     -> /efi/EFI/steamos/grubx64.efi + grub.cfg
     -> /boot/vmlinuz-*
     -> rootfs
```

Valve ships a Microsoft-signed `shim` in some recovery images.  If the
fallback `bootx64.efi` is the Microsoft-signed shim, the firmware trusts it
through the default Microsoft `db`.  The next stages (`steamcl.efi`,
`grubx64.efi`, and the kernel) are **not** signed by Microsoft, so they are
rejected by a stock firmware until we add our own signatures and enroll our
own key.

## Secure Boot architecture

The helper is `bin/steamos-secureboot` with library support in
`lib/secureboot.sh`.

1. **Key hierarchy** — `sbctl create-keys` generates a standard Platform Key
   (PK), Key Exchange Key (KEK) and signature database (db) pair.  The helper
   pins these under `/var/lib/steamos-secureboot` by writing
   `/etc/sbctl/sbctl.conf`.  This keeps keys on a writable partition and makes
   them easy to back up.
2. **Signing** — We sign the exact boot files the installer creates:
   - `/esp/efi/boot/bootx64.efi`
   - `/esp/efi/steamos/steamcl.efi`
   - `/efi/EFI/steamos/grubx64.efi` (on both efi-A and efi-B)
   - `/boot/vmlinuz-*` (on both rootfs-A and rootfs-B)
   We do **not** blindly sign every `.efi` on the ESP.  If a future SteamOS
   update ships a Microsoft-signed `shim*.efi`, our signature-aware skip
   leaves it untouched.
3. **Enrollment** — `sbctl enroll-keys --microsoft` installs the custom keys
   while preserving Microsoft's certificates.  This is only performed when you
   explicitly run `steamos-secureboot enroll` and the firmware is in Setup
   Mode.
4. **Update persistence** — Two systemd units are installed:
   - `steamos-secureboot.service` runs `steamos-secureboot sign` on every
     boot, re-signing anything that was recreated by SteamOS boot services.
   - `steamos-secureboot-update.path` watches for SteamOS's update marker
     (`/var/lib/steamos-atomupd/system-updated`) and triggers
     `steamos-secureboot update`, which signs the inactive partset **before**
     the reboot that switches to it.

## Files that are signed

During setup, on every boot, and after an update the tool signs the following
files when they are present and unsigned:

| Partition | Path | Notes |
|---|---|---|
| ESP (`/esp`) | `efi/boot/bootx64.efi` | UEFI fallback loader |
| ESP (`/esp`) | `efi/steamos/steamcl.efi` | SteamCL chain loader |
| efi-A (`/efi`) | `EFI/steamos/grubx64.efi` | GRUB image for the active partset |
| efi-B (inactive) | `EFI/steamos/grubx64.efi` | GRUB image for the inactive partset |
| rootfs-A (`/`) | `boot/vmlinuz-*` | Linux kernel for partset A |
| rootfs-B (inactive) | `boot/vmlinuz-*` | Linux kernel for partset B |

Config files such as `grub.cfg` and initramfs images are **not** signed by
this tool.  Under a standard shim + GRUB + signed-kernel chain, GRUB loads the
initramfs after shim lockdown; signing it is not required for the boot chain
to verify.

## How SteamOS updates are handled

SteamOS updates are image-based and write into the inactive partset.  They can
replace:

- kernels on the inactive rootfs
- GRUB images and modules on the inactive efi partition
- boot configuration
- files that `steamcl-install` copies to the ESP

Because the update can run while the *other* partset is active, a one-time
signing step is not enough.  The helper installs `steamos-secureboot.service`,
which runs after `local-fs.target` on every boot and re-signs any file that is
not currently signed with your key.  When SteamOS applies an update and marks
`system-updated`, `steamos-secureboot-update.path` signs the inactive partset
before the reboot that switches to it.

If you prefer not to use the service, run the equivalent command manually
after each SteamOS update:

```bash
sudo steamos-secureboot sign
```

And before rebooting into a pending update:

```bash
sudo steamos-secureboot update
```

## Safe installation procedure

### Stage 1 — install SteamOS normally

Boot the official SteamOS recovery USB and install as usual.  The existing
installer is unchanged.

```bash
cd steamos_custom_install
sudo ./repair_device.sh --disk /dev/sda all
```

Replace `/dev/sda` with your actual target disk.  Verify the install boots
into SteamOS before proceeding.

### Stage 2 — configure Secure Boot from inside SteamOS

Once you are logged into the installed SteamOS:

1. Make sure `sbctl` and `openssl` are installed.  On SteamOS:

   ```bash
   sudo steamos-readonly disable
   sudo pacman -S sbctl openssl
   sudo steamos-readonly enable
   ```

2. Generate keys, sign the current boot chain, install the update services,
   and back up the keys to a USB stick:

   ```bash
   cd steamos_custom_install
   sudo ./bin/steamos-secureboot setup --key-backup /run/media/deck/SECUREBOOT-KEYS
   ```

   If you omit `--key-backup`, the tool still copies keys to
   `/var/lib/steamos-secureboot/backup/<timestamp>` and prints the path.

3. The tool prints enrollment instructions.  Read them carefully.

4. Reboot into UEFI setup, enter Setup Mode (clear/reset the Platform Key),
   and boot back into SteamOS.  Do **not** delete Microsoft's certificates if
   you need Windows dual-boot.

5. Enroll your keys while preserving Microsoft's:

   ```bash
   sudo steamos-secureboot enroll
   ```

   You must type `ENROLL` when prompted.

6. Reboot into UEFI setup again and turn **Secure Boot ON**.  Leave Setup
   Mode (sbctl sets the Platform Key during enrollment).

7. Boot SteamOS.  If it boots with Secure Boot enabled, the chain is
   verified.

### Alternative: signing from a live environment

If you cannot boot into SteamOS before enabling Secure Boot, you can sign the
installed disk directly from a Linux live USB:

```bash
sudo ./bin/steamos-secureboot sign --disk /dev/sda
```

This signs the ESP, efi-A/B and rootfs-A/B on the selected disk.  It does not
install the update service or create keys; run `setup` from inside SteamOS
later for persistence.

## Key backup and recovery

During `setup`, the tool copies:

- `/var/lib/steamos-secureboot/keys` — the PK/KEK/db key hierarchy
- `/var/lib/steamos-secureboot` — the sbctl file database, GUID, etc.
- `/etc/sbctl/sbctl.conf` — the sbctl configuration that pins the paths

to your chosen backup location.  Keep this backup somewhere safe and separate
from the machine.

If you lose the keys:

1. Disable Secure Boot in firmware setup and boot normally.
2. Re-run `steamos-secureboot setup` to generate a new key hierarchy.
3. Re-sign the boot chain (`steamos-secureboot sign`).
4. Re-enroll the new keys in Setup Mode.

If you only need to re-sign after a firmware reset that cleared the db but
left the files intact, restore the backup and run:

```bash
sudo cp -a /path/to/backup/keys      /var/lib/steamos-secureboot/keys
sudo cp -a /path/to/backup/sbctl-db  /var/lib/steamos-secureboot
sudo cp -a /path/to/backup/sbctl.conf /etc/sbctl/sbctl.conf
sudo steamos-secureboot sign
```

## Rollback procedure

To go back to Secure Boot off:

1. Reboot into UEFI setup.
2. Turn **Secure Boot OFF**.
3. Optional: restore factory keys if you want the firmware back to its
   out-of-box certificate state.

The unsigned boot files are still present, so the system will boot normally
with Secure Boot disabled.  The `steamos-secureboot.service` will continue to
sign files harmlessly; disable it if you no longer want it:

```bash
sudo systemctl disable --now steamos-secureboot.service
sudo systemctl disable --now steamos-secureboot-update.path
```

## Test report

The following checks were run on the modified project:

- `bash -n` syntax check on `bin/steamos-secureboot`, `lib/secureboot.sh`,
  and `bin/steamos-install`.
- Existing `bats` tests in `tests/cli.bats` and `tests/disk.bats` — all pass.
- New `bats` tests in `tests/secureboot.bats` covering:
  - CLI help and unknown-option handling
  - EFI/kernel file discovery
  - ESP/efi/rootfs signing
  - Signature-aware skip for files signed by another key
  - Root-device-to-whole-disk resolution for both SATA and NVMe names
  - Enrollment requires Setup Mode
  - Enrollment preserves Microsoft certificates (`--microsoft`)
  - Enrollment requires explicit `ENROLL` confirmation
  - Setup refuses to run outside installed SteamOS without `--disk`
  - Sign refuses to run without a disk or installed SteamOS
  - `update` command signs the inactive partset
- WSL image test: a GPT disk image with SteamOS-like partitions was created
  from a real recovery image.  `steamos-secureboot sign --disk` signed
  `bootx64.efi`, `steamcl.efi`, `grubx64.efi` on both efi partitions, and
  `vmlinuz-*` on both rootfs partitions.  All signatures were verified with
  `sbverify` using the generated `db.pem`.

The integration VM test (`tools/vm-test/`) was not re-run, because no
installer partition/formatting/copy logic was changed.

## What cannot be safely automated

- **Firmware enrollment.** The tool never writes UEFI variables automatically.
  You must reboot into Setup Mode and run `steamos-secureboot enroll`
  yourself.  This prevents accidental lockouts.
- **Key backup to removable media.** The tool can copy keys to a path you
  specify, but it cannot decide which USB stick is safe to write to.
- **Installing `sbctl` on SteamOS.** SteamOS keeps `/usr` read-only by default;
  the user must temporarily disable the read-only overlay to install `sbctl`.
- **Recovery-environment setup.** `steamos-secureboot setup` is designed to run
  from the installed SteamOS system where `/efi` and `/esp` are mounted.  It
  can be run from a live environment with `sign --disk`, but the keys and
  systemd service would have to be placed into the target rootfs manually.
- **Third-party kernel modules.** Any out-of-tree kernel module drivers signed
  by another key are outside the scope of this tool.

## Files added or changed

- `bin/steamos-secureboot` — new CLI entrypoint.
- `lib/secureboot.sh` — new library (key management, signing, enrollment,
  update service).
- `tests/secureboot.bats` — new unit tests.
- `docs/secureboot.md` — this document.
- `bin/steamos-install` — usage text now mentions `steamos-secureboot` as the
  post-install Secure Boot step (no functional change).
