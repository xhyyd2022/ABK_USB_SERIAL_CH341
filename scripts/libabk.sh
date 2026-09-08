#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Shared helpers for the ABK USB Serial CH340/CH341/CH430 external module.
# The public API mirrors the helpers used by the other ABK external modules
# (abk_log / abk_die / abk_require_env / abk_set_config ...).

abk_log() {
  printf '[ABK usb-serial] %s\n' "$*"
}

abk_warn() {
  printf '[ABK usb-serial][warn] %s\n' "$*" >&2
}

abk_die() {
  printf '[ABK usb-serial][error] %s\n' "$*" >&2
  exit 1
}

abk_require_env() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      abk_die "required environment variable is empty: $name"
    fi
  done
}

abk_require_file() {
  local path="$1"
  [ -f "$path" ] || abk_die "required file not found: $path"
}

abk_require_dir() {
  local path="$1"
  [ -d "$path" ] || abk_die "required directory not found: $path"
}

abk_common_dir() {
  abk_require_env KERNEL_ROOT
  printf '%s/common\n' "$KERNEL_ROOT"
}

# abk_install_file <source> <target>
# Copies a bundled file into the kernel tree. Idempotent: skips when the
# target already matches byte-for-byte, backs up a differing target once.
abk_install_file() {
  local src="$1"
  local dst="$2"

  abk_require_file "$src"

  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    abk_log "unchanged: $dst"
    return 0
  fi

  if [ -f "$dst" ] && [ ! -f "$dst.abk.bak" ]; then
    cp -f "$dst" "$dst.abk.bak"
    abk_log "backup: $dst -> $dst.abk.bak"
  fi

  install -D -m 0644 "$src" "$dst"
  abk_log "installed: $src -> $dst"
}

# abk_append_line_once <file> <line>
# Appends <line> only when it is not already present (exact match).
abk_append_line_once() {
  local file="$1"
  local line="$2"

  abk_require_file "$file"
  if ! grep -Fqx -- "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
    abk_log "append line to $file: $line"
  else
    abk_log "line already present in $file: $line"
  fi
}

# abk_config_line <symbol> <value>
abk_config_line() {
  local symbol="${1#CONFIG_}"
  local value="$2"

  case "$value" in
    n) printf '# CONFIG_%s is not set\n' "$symbol" ;;
    *) printf 'CONFIG_%s=%s\n' "$symbol" "$value" ;;
  esac
}

# abk_set_config <symbol> <value> [file]
# Removes any previous definition and appends the requested one. Idempotent.
abk_set_config() {
  local symbol="${1#CONFIG_}"
  local value="$2"
  local file="${3:-${DEFCONFIG:-}}"
  local tmp

  [ -n "$file" ] || abk_die "DEFCONFIG is empty and no config file was provided"
  abk_require_file "$file"

  tmp="$(mktemp)"
  grep -v -E "^(CONFIG_${symbol}=|# CONFIG_${symbol} is not set$)" "$file" > "$tmp" || true
  abk_config_line "$symbol" "$value" >> "$tmp"
  mv "$tmp" "$file"

  abk_log "set CONFIG_${symbol}=$value in $file"
}

abk_enable_config() {
  abk_set_config "$1" y "${2:-${DEFCONFIG:-}}"
}

# abk_kconfig_has_config <file> <symbol>
# Matches both "config SYMBOL" and "menuconfig SYMBOL" entries.
abk_kconfig_has_config() {
  local file="$1"
  local symbol="$2"
  grep -Eq "^[[:space:]]*(menuconfig|config)[[:space:]]+${symbol}([[:space:]]|$)" "$file"
}

# abk_kconfig_insert_after <file> <ere-pattern> <block-file>
abk_kconfig_insert_after() {
  local file="$1"
  local pattern="$2"
  local block="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v pat="$pattern" -v blk="$block" '
    { print }
    !done && $0 ~ pat {
      while ((getline line < blk) > 0) print line
      close(blk)
      done = 1
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# abk_kconfig_insert_before <file> <ere-pattern> <block-file>
abk_kconfig_insert_before() {
  local file="$1"
  local pattern="$2"
  local block="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v pat="$pattern" -v blk="$block" '
    !done && $0 ~ pat {
      while ((getline line < blk) > 0) print line
      close(blk)
      done = 1
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}
