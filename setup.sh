#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# ABK custom external module entry point.
#
# Repository root must contain this file and it must be executable:
#   chmod +x setup.sh
#
# ABK clones the repository and runs `bash setup.sh` from the repository root
# during the configured stage. Required environment (provided by ABK):
#   KERNEL_ROOT                  kernel source tree (e.g. $GITHUB_WORKSPACE/$CONFIG)
#   DEFCONFIG                    $KERNEL_ROOT/common/arch/arm64/configs/gki_defconfig
#   CUSTOM_EXTERNAL_MODULE_STAGE after_patch or before_build
#
# This module is designed for the after_patch stage and is safe to re-run.

set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$MODULE_DIR/module.conf" ]; then
  # shellcheck disable=SC1091
  source "$MODULE_DIR/module.conf"
fi

# shellcheck disable=SC1091
source "$MODULE_DIR/scripts/libabk.sh"
# shellcheck disable=SC1091
source "$MODULE_DIR/scripts/usb_serial_ch341.sh"

abk_require_env KERNEL_ROOT DEFCONFIG CUSTOM_EXTERNAL_MODULE_STAGE

module_name="${ABK_MODULE_NAME:-USB Serial CH340/CH341/CH430}"
module_version="${ABK_MODULE_VERSION:-unknown}"

abk_log "module: $module_name"
abk_log "version: $module_version"
abk_log "stage: $CUSTOM_EXTERNAL_MODULE_STAGE"
abk_log "config: ${CONFIG:-unknown}"
abk_log "kernel root: $KERNEL_ROOT"
abk_log "defconfig: $DEFCONFIG"

case "$CUSTOM_EXTERNAL_MODULE_STAGE" in
  after_patch)
    abk_usb_serial_apply
    ;;

  before_build)
    abk_log "before_build: nothing to do (driver and configs are applied in after_patch)"
    ;;

  *)
    abk_die "unsupported CUSTOM_EXTERNAL_MODULE_STAGE: $CUSTOM_EXTERNAL_MODULE_STAGE"
    ;;
esac

abk_log "done"
