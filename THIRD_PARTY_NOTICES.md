# Third-Party Notices

This module bundles unmodified Linux kernel driver sources:

| File | Origin | License |
| --- | --- | --- |
| `files/drivers/ch341-5.10.c` | `drivers/usb/serial/ch341.c` (Linux v5.10) | GPL-2.0 |
| `files/drivers/ch341-5.15.c` | `drivers/usb/serial/ch341.c` (Linux v5.15) | GPL-2.0 |
| `files/drivers/ch341-6.1.c` | `drivers/usb/serial/ch341.c` (Linux v6.1) | GPL-2.0 |
| `files/drivers/ch341-6.6.c` | `drivers/usb/serial/ch341.c` (Linux v6.6) | GPL-2.0 |
| `files/drivers/ch341-6.12.c` | `drivers/usb/serial/ch341.c` (Linux v6.12) | GPL-2.0 |

Upstream: <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/serial/ch341.c>

The kernel source is distributed under the GNU General Public License v2.0.
See the `SPDX-License-Identifier` header in each file for details.

The files are byte-for-byte upstream copies for their respective kernel line.
No functional driver logic was changed. CH340/CH341/CH430 support comes from the
upstream device id table (notably `1a86:7523` for CH340/CH430).
