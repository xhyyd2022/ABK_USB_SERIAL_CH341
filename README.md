# ABK USB Serial CH340/CH341/CH430 Module

ABK（AnyBase Kernel）自定义外部模块，用于在 ABK 构建 GKI 内核时自动**启用**并
（在源码缺失时）**注入** WCH CH340 / CH341 / CH430 等 USB 转串口（USB-Serial）驱动。

驱动以**内建（`=y`）**方式编译进内核，避免单独打包 `.ko` 的复杂流程，刷入后
内核原生支持 USB 转串口，无需额外模块加载。

## 支持的内核线

ABK 支持 5.10 / 5.15 / 6.1 / 6.6 / 6.12。`ch341.c` 在不同内核线上的
`usb_control_msg_recv()`、`asm/unaligned.h`、`break_ctl` 返回值等接口存在差异，
因此本模块按内核版本内置了对应源码，**绝不跨版本混用**：

| 内核线 | 内置驱动 | 关键差异 |
| --- | --- | --- |
| 5.10 | `files/drivers/ch341-5.10.c` | 无 `usb_control_msg_recv()` |
| 5.15 | `files/drivers/ch341-5.15.c` | 无 `usb_control_msg_recv()` |
| 6.1 | `files/drivers/ch341-6.1.c` | `usb_control_msg_recv()` |
| 6.6 | `files/drivers/ch341-6.6.c` | `break_ctl` 返回 `int` |
| 6.12 | `files/drivers/ch341-6.12.c` | `<linux/unaligned.h>` |

内核版本从 `$KERNEL_ROOT/common/Makefile` 的 `VERSION`/`PATCHLEVEL` 读取，
读取失败时回退到 ABK 提供的 `ABK_BUILD_KERNEL_VERSION`；无法识别时直接失败退出。

## 目录结构

```text
ABK_USB_SERIAL_CH341/
├── setup.sh                      # ABK 入口脚本（已 chmod +x）
├── module.conf                   # 模块元数据
├── scripts/
│   ├── libabk.sh                 # ABK 通用工具函数
│   └── usb_serial_ch341.sh       # 核心注入逻辑
└── files/
    └── drivers/
        ├── ch341-5.10.c          # 各内核线驱动（未改动上游逻辑）
        ├── ch341-5.15.c
        ├── ch341-6.1.c
        ├── ch341-6.6.c
        └── ch341-6.12.c
```

## 工作阶段

| 阶段 | 行为 |
| --- | --- |
| `after_patch` | 检测内核版本 → 确保驱动存在 → 校验 usbserial 核心 → 修改 Makefile/Kconfig → 写入 `$DEFCONFIG` → 校验结果 |
| `before_build` | 空操作（驱动与配置已在 `after_patch` 完成） |

## 安全设计（重要）

1. **不覆盖树内驱动**：默认保留 `$KERNEL_ROOT/common/drivers/usb/serial/ch341.c`。
   厂商/GKI 树可能带有回移植修复，覆盖可能造成回退。只有树内缺失 `ch341.c` 时
   才注入对应内核线的驱动；如需强制覆盖，设置环境变量
   `ABK_USB_SERIAL_FORCE_INJECT=1`。
2. **不注入 usbserial 核心**：`usb-serial.c` / `generic.c` / `bus.c` 必须已存在于
   内核树，缺失时直接失败退出。把另一内核版本的 core 混进源码树会破坏编译，
   完整内核树（含 GKI `common/`）始终包含这些文件。
3. **幂等**：配置文件先删旧行再追加；Makefile/Kconfig 只在缺失时插入。
4. **防错**：`set -euo pipefail`；定位、版本识别、core 校验、写入后校验任一失败
   都会 `exit 1`，构建立即中断，避免产出坏内核。
5. **阶段顺序**：`after_patch`（build.yml 第 3400 行）在 `编译内核`（第 5804 行）
   之前，配置改动会被 `build/build.sh` 的 `make gki_defconfig` 采用；bazel 路径
   会把 `gki_defconfig` 的差异提取进 `ksu.fragment`，改动同样保留。
6. **`USB_SERIAL` 由 `=m` 改为 `=y`**：GKI 6.1/6.6/6.12 的 `gki_defconfig` 默认
   `CONFIG_USB_SERIAL=m`。改为内建后不再产出 `usbserial.ko`，因此必须同步清理
   `common/modules.bzl` 中的该条目（见下文第 9 步），否则 bazel 构建失败。
   `CONFIG_USB_SERIAL_FTDI_SIO=m` 保持不变，仍可正常链接到内建的 usbserial。

## 内部逻辑

1. 环境检查：`abk_require_env KERNEL_ROOT DEFCONFIG CUSTOM_EXTERNAL_MODULE_STAGE`。
2. 定位源码：优先 `$KERNEL_ROOT/common/drivers/usb/serial`，回退 `$KERNEL_ROOT/drivers/usb/serial`。
3. 识别内核版本并选择 `files/drivers/ch341-<版本>.c`。
4. 确保驱动：树内已有则保留；缺失或强制注入时安装（安装前备份为 `*.abk.bak`）。
5. 校验 `usb-serial.c` / `generic.c` / `bus.c` 存在。
6. Makefile 确保：
   - `obj-$(CONFIG_USB_SERIAL) += usbserial.o`
   - `usbserial-y := usb-serial.o generic.o bus.o`
   - `obj-$(CONFIG_USB_SERIAL_CH341) += ch341.o`
7. Kconfig 确保 `config USB_SERIAL` / `USB_SERIAL_GENERIC` / `USB_SERIAL_CH341` 存在。
8. `$DEFCONFIG` 幂等写入：

   ```ini
   CONFIG_USB_SERIAL=y
   CONFIG_USB_SERIAL_GENERIC=y
   CONFIG_USB_SERIAL_CH341=y
   ```

9. 若存在 `$KERNEL_ROOT/common/modules.bzl`（bazel 构建的模块清单），移除其中
   的 `drivers/usb/serial/usbserial.ko`。因为 `USB_SERIAL=y` 后不再产出
   `usbserial.ko`，若清单仍列出会导致 bazel 报“模块缺失”。这与 ABK 对
   `zram.ko`/`zsmalloc.ko` 的处理方式一致（`build.yml` 第 3135 行）。

10. 校验上述所有改动确实落地。

## 在 ABK 中填写

把本模块推送到你的 GitHub 仓库后，在 ABK 的“自定义外部模块”输入框中填写仓库地址
与阶段参数，多个模块用 `|` 分隔：

```text
https://github.com/xhyyd2022/ABK_USB_SERIAL_CH341;after_patch
```

- **阶段**：必须为 `after_patch`。
- **App**：构建设置 → 自定义外部模块 → 填入上面的字符串。
- **GitHub Actions**：触发 `build.yml` 时，把 `custom_external_modules` 输入设为：

  ```text
  https://github.com/xhyyd2022/ABK_USB_SERIAL_CH341;after_patch
  ```

## VID/PID 覆盖

| 芯片 | VID:PID |
| --- | --- |
| CH340 / CH340G / CH430 | `1a86:7523` |
| CH341 / CH341A | `1a86:5523`、`1a86:7522` |
| CH340 适配器 | `2184:0057` |
| CH341 克隆 | `4348:5523` |
| CH340/CH430 适配器 | `9986:7523` |
| CH341（5.10/5.15 额外） | `1a86:5512` |

CH430 与 CH340 共用 `1a86:7523` 及同一套 CH34x UART 协议。

## 本地验证（可选）

```bash
tmp="$(mktemp -d)"
mkdir -p "$tmp/common/drivers/usb/serial" "$tmp/common/arch/arm64/configs"
printf 'VERSION = 6\nPATCHLEVEL = 1\nSUBLEVEL = 0\n' > "$tmp/common/Makefile"
printf 'obj-$(CONFIG_USB_SERIAL)\t\t\t+= usbserial.o\nusbserial-y := usb-serial.o generic.o bus.o\n' \
  > "$tmp/common/drivers/usb/serial/Makefile"
printf 'menuconfig USB_SERIAL\n\tbool "USB Serial"\n\nif USB_SERIAL\n\nendif # USB_SERIAL\n' \
  > "$tmp/common/drivers/usb/serial/Kconfig"
touch "$tmp/common/drivers/usb/serial/usb-serial.c" \
      "$tmp/common/drivers/usb/serial/generic.c" \
      "$tmp/common/drivers/usb/serial/bus.c"
printf 'CONFIG_TTY=y\n' > "$tmp/common/arch/arm64/configs/gki_defconfig"

export KERNEL_ROOT="$tmp" DEFCONFIG="$tmp/common/arch/arm64/configs/gki_defconfig"
export CUSTOM_EXTERNAL_MODULE_STAGE=after_patch
bash setup.sh   # 第一次
bash setup.sh   # 第二次应为幂等
grep -c 'USB_SERIAL_CH341=y' "$DEFCONFIG"
```

## 许可证

本模块整体以 **GPL-2.0** 发布，完整协议文本见 [`LICENSE`](LICENSE)。

`files/drivers/ch341-*.c` 来自 Linux 主线内核 `drivers/usb/serial/ch341.c`
（`SPDX-License-Identifier: GPL-2.0`），保持上游逻辑不变；来源与版本说明见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
