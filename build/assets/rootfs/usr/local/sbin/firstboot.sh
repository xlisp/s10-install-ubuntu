#!/bin/sh
# One-time post-install jobs on the device
set -x

# Generate modules.dep so modprobe works for out-of-tree/optional modules
if command -v depmod >/dev/null 2>&1; then
    depmod -a
fi

# Disable broken suspend (known issue on exynos9820 mainline)
systemctl mask sleep.target suspend.target hibernate.target 2>/dev/null || true

touch /var/lib/firstboot-done
