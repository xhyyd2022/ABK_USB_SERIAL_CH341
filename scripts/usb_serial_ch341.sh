#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Core logic for the ABK USB Serial CH340/CH341/CH430 external module.
#
# Stage: after_patch (source tree integrated, before the final defconfig and
# build steps). The module:
#   1. locates drivers/usb/serial and detects the kernel version,
#   2. ensures a CH34x driver is present (version-matched bundled driver is
#      only injected when the tree has none, unless force-inject is set),
#   3. verifies the usbserial core sources exist,
#   4. wires ch341/usbserial into the serial Makefile and Kconfig,
#   5. enables the required CONFIG symbols in $DEFCONFIG,
#   6. verifies every change landed.
#
# Every step is idempotent so the module can be re-run safely.
#
# Safety notes:
#   - The in-tree ch341.c is NEVER overwritten by default. Vendor/GKI trees may
#     carry backported fixes; set ABK_USB_SERIAL_FORCE_INJECT=1 to override.
#   - usbserial core sources (usb-serial.c/generic.c/bus.c) are required, not
#     injected: every full kernel tree ships them and mixing a different
#     kernel's core into the tree would break the build.

abk_usb_serial_files_dir() {
  printf '%s/files\n' "$MODULE_DIR"
}

# Locate drivers/usb/serial, supporting both the GKI common/ layout and a
# plain KERNEL_ROOT/drivers layout.
abk_usb_serial_dir() {
  abk_require_env KERNEL_ROOT

  if [ -d "$KERNEL_ROOT/common/drivers/usb/serial" ]; then
    printf '%s/common/drivers/usb/serial\n' "$KERNEL_ROOT"
  elif [ -d "$KERNEL_ROOT/drivers/usb/serial" ]; then
    printf '%s/drivers/usb/serial\n' "$KERNEL_ROOT"
  else
    abk_die "cannot locate drivers/usb/serial under KERNEL_ROOT=$KERNEL_ROOT"
  fi
}

# Echo the "<major>.<minor>" kernel version. Prefers the kernel Makefile and
# falls back to the ABK_BUILD_KERNEL_VERSION variable exported by ABK.
abk_usb_serial_kernel_version() {
  local common="$1"
  local makefile="$common/Makefile"
  local version patchlevel

  if [ -f "$makefile" ]; then
    version="$(awk '$1 == "VERSION" && $2 == "=" { print $3; exit }' "$makefile")"
    patchlevel="$(awk '$1 == "PATCHLEVEL" && $2 == "=" { print $3; exit }' "$makefile")"
    if [ -n "$version" ] && [ -n "$patchlevel" ]; then
      printf '%s.%s\n' "$version" "$patchlevel"
      return 0
    fi
  fi

  if [ -n "${ABK_BUILD_KERNEL_VERSION:-}" ]; then
    printf '%s\n' "$ABK_BUILD_KERNEL_VERSION"
    return 0
  fi

  abk_die "cannot determine kernel version from $makefile or ABK_BUILD_KERNEL_VERSION"
}

# Echo the bundled driver matching <version>. Dies for unsupported lines.
abk_usb_serial_driver_source() {
  local version="$1"
  local files candidate

  files="$(abk_usb_serial_files_dir)"
  candidate="$files/drivers/ch341-${version}.c"

  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  abk_die "unsupported kernel version '$version' (bundled drivers: 5.10 5.15 6.1 6.6 6.12)"
}

# Ensure a CH34x driver is present. Injection only happens when the tree has
# no ch341.c, or when ABK_USB_SERIAL_FORCE_INJECT=1 is set.
abk_usb_serial_install_driver() {
  local dir="$1"
  local version="$2"
  local target="$dir/ch341.c"
  local force="${ABK_USB_SERIAL_FORCE_INJECT:-0}"
  local source

  if [ -f "$target" ] && [ "$force" != "1" ]; then
    abk_log "in-tree driver kept: $target (set ABK_USB_SERIAL_FORCE_INJECT=1 to overwrite)"
    return 0
  fi

  source="$(abk_usb_serial_driver_source "$version")"
  abk_install_file "$source" "$target"
}

# usbserial core sources must exist; never inject a different kernel's core.
abk_usb_serial_require_core() {
  local dir="$1"
  local core

  for core in usb-serial.c generic.c bus.c; do
    if [ ! -f "$dir/$core" ]; then
      abk_die "required USB serial core source missing: $dir/$core (a full kernel tree ships it; do not mix another kernel's core)"
    fi
  done

  abk_log "usbserial core sources present"
}

abk_usb_serial_ensure_makefile() {
  local dir="$1"
  local makefile="$dir/Makefile"

  abk_require_file "$makefile"

  if ! grep -Eq '^[[:space:]]*obj-\$\(CONFIG_USB_SERIAL\)' "$makefile"; then
    abk_append_line_once "$makefile" 'obj-$(CONFIG_USB_SERIAL)			+= usbserial.o'
  else
    abk_log "Makefile already links usbserial.o"
  fi

  if ! grep -Eq '^[[:space:]]*usbserial-y[[:space:]]*[:+]?=' "$makefile"; then
    abk_append_line_once "$makefile" 'usbserial-y := usb-serial.o generic.o bus.o'
  else
    local obj
    for obj in usb-serial.o generic.o bus.o; do
      if grep -Eq "^[[:space:]]*usbserial-y.*[[:space:]]${obj}([[:space:]]|$)" "$makefile"; then
        abk_log "Makefile already builds usbserial-y ${obj}"
      else
        abk_append_line_once "$makefile" "usbserial-y += ${obj}"
      fi
    done
  fi

  if ! grep -Eq '^[[:space:]]*obj-\$\(CONFIG_USB_SERIAL_CH341\)' "$makefile"; then
    abk_append_line_once "$makefile" 'obj-$(CONFIG_USB_SERIAL_CH341)			+= ch341.o'
  else
    abk_log "Makefile already links ch341.o"
  fi
}

abk_usb_serial_ensure_kconfig() {
  local dir="$1"
  local kconfig="$dir/Kconfig"
  local block

  abk_require_file "$kconfig"

  if ! grep -Eq '^[[:space:]]*(menuconfig|config)[[:space:]]+USB_SERIAL([[:space:]]|$)' "$kconfig"; then
    abk_die "Kconfig does not define USB_SERIAL: $kconfig"
  fi

  if ! abk_kconfig_has_config "$kconfig" USB_SERIAL_GENERIC; then
    block="$(mktemp)"
    cat > "$block" <<'EOF'
config USB_SERIAL_GENERIC
	bool "USB Generic Serial Driver"
	help
	  Say Y here if you want to use the generic USB serial driver.
	  This is required by the CH340/CH341/CH430 adapter support.

EOF
    if grep -Eq '^[[:space:]]*if[[:space:]]+USB_SERIAL([[:space:]]|$)' "$kconfig"; then
      abk_kconfig_insert_after "$kconfig" '^[[:space:]]*if[[:space:]]+USB_SERIAL([[:space:]]|$)' "$block"
    else
      cat "$block" >> "$kconfig"
    fi
    rm -f "$block"
    abk_log "injected config USB_SERIAL_GENERIC into $kconfig"
  else
    abk_log "Kconfig already defines USB_SERIAL_GENERIC"
  fi

  if ! abk_kconfig_has_config "$kconfig" USB_SERIAL_CH341; then
    block="$(mktemp)"
    cat > "$block" <<'EOF'
config USB_SERIAL_CH341
	tristate "USB Winchiphead CH340/CH341/CH430 Single Port Serial Driver"
	help
	  Say Y here if you want to use a Winchiphead CH340, CH341/CH341A
	  or CH430 single port USB to serial adapter. These chips share the
	  WCH CH34x UART protocol handled by this driver.

	  To compile this driver as a module, choose M here: the
	  module will be called ch341.

EOF
    if grep -Eq '^[[:space:]]*endif.*USB_SERIAL' "$kconfig"; then
      abk_kconfig_insert_before "$kconfig" '^[[:space:]]*endif.*USB_SERIAL' "$block"
    else
      cat "$block" >> "$kconfig"
    fi
    rm -f "$block"
    abk_log "injected config USB_SERIAL_CH341 into $kconfig"
  else
    abk_log "Kconfig already defines USB_SERIAL_CH341"
  fi
}

abk_usb_serial_enable_configs() {
  abk_require_env DEFCONFIG

  abk_enable_config USB_SERIAL
  abk_enable_config USB_SERIAL_GENERIC
  abk_enable_config USB_SERIAL_CH341
}

# GKI lists usbserial.ko in common/modules.bzl for bazel builds. Once
# CONFIG_USB_SERIAL=y the .ko is no longer produced, so the entry must be
# dropped or bazel fails with a missing-module error. Mirrors ABK's zram
# handling in build.yml.
abk_usb_serial_prune_bazel_modules() {
  local common="$1"
  local modules_bzl="$common/modules.bzl"

  if [ ! -f "$modules_bzl" ]; then
    abk_log "modules.bzl not present, skipping bazel module-list update"
    return 0
  fi

  if grep -q '"drivers/usb/serial/usbserial\.ko"' "$modules_bzl"; then
    sed -i 's|"drivers/usb/serial/usbserial\.ko",\?||g' "$modules_bzl"
    abk_log "removed usbserial.ko from modules.bzl (now builtin)"
  else
    abk_log "usbserial.ko already absent from modules.bzl"
  fi
}

# Fail loudly if any expected change did not land.
abk_usb_serial_verify() {
  local dir="$1"
  local common
  local makefile="$dir/Makefile"
  local kconfig="$dir/Kconfig"

  common="$(cd "$dir/../../.." && pwd)"

  grep -Eq '^[[:space:]]*obj-\$\(CONFIG_USB_SERIAL\)' "$makefile" ||
    abk_die "Makefile is missing the CONFIG_USB_SERIAL link"
  grep -Eq '^[[:space:]]*obj-\$\(CONFIG_USB_SERIAL_CH341\)' "$makefile" ||
    abk_die "Makefile is missing the CONFIG_USB_SERIAL_CH341 link"

  abk_kconfig_has_config "$kconfig" USB_SERIAL ||
    abk_die "Kconfig is missing USB_SERIAL"
  abk_kconfig_has_config "$kconfig" USB_SERIAL_GENERIC ||
    abk_die "Kconfig is missing USB_SERIAL_GENERIC"
  abk_kconfig_has_config "$kconfig" USB_SERIAL_CH341 ||
    abk_die "Kconfig is missing USB_SERIAL_CH341"

  abk_require_env DEFCONFIG
  grep -qxF 'CONFIG_USB_SERIAL=y' "$DEFCONFIG" ||
    abk_die "DEFCONFIG is missing CONFIG_USB_SERIAL=y"
  grep -qxF 'CONFIG_USB_SERIAL_GENERIC=y' "$DEFCONFIG" ||
    abk_die "DEFCONFIG is missing CONFIG_USB_SERIAL_GENERIC=y"
  grep -qxF 'CONFIG_USB_SERIAL_CH341=y' "$DEFCONFIG" ||
    abk_die "DEFCONFIG is missing CONFIG_USB_SERIAL_CH341=y"

  if [ -f "$common/modules.bzl" ] &&
     grep -q '"drivers/usb/serial/usbserial\.ko"' "$common/modules.bzl"; then
    abk_die "modules.bzl still lists usbserial.ko while CONFIG_USB_SERIAL=y"
  fi

  abk_log "verification passed"
}

abk_usb_serial_apply() {
  local dir common version

  dir="$(abk_usb_serial_dir)"
  common="$(cd "$dir/../../.." && pwd)"
  version="$(abk_usb_serial_kernel_version "$common")"

  abk_log "serial dir: $dir"
  abk_log "kernel version: $version"

  abk_usb_serial_install_driver "$dir" "$version"
  abk_usb_serial_require_core "$dir"
  abk_usb_serial_ensure_makefile "$dir"
  abk_usb_serial_ensure_kconfig "$dir"
  abk_usb_serial_enable_configs
  abk_usb_serial_prune_bazel_modules "$common"
  abk_usb_serial_verify "$dir"
}
