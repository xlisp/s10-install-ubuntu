# Samsung Galaxy S10 (SM-G973N, beyond1lte) — 原生 Ubuntu 26.04 安装项目

把韩版 Galaxy S10（Exynos 9820）刷成**原生 Ubuntu Linux**（非 Ubuntu Touch）。

## 方案架构

```
S-Boot (三星原厂引导，不可替换)
  └─ U-Boot (chiffathefox/exynos9820 分支，boot 分区，带 UFS/pinctrl/显示驱动)
       └─ UEFI boot → systemd-boot (ESP 分区)
            └─ Linux 7.2 (linux-postmarketos-exynos9820，EFI stub + U-Boot 提供的 DTB)
                 └─ Ubuntu 26.04 (resolute) rootfs — ext4 "ubuntu-root" 分区
```

- userdata 分区被当作一整块磁盘，内建 GPT：`esp`(512MiB, fat32) + `ubuntu-root`(ext4)
- 这是 Nura/postmarketOS exynos9820 通用端口的布局，内核/硬件支持全部来自它的 mainline 内核

## 硬件现状（内核 7.2，官方 wiki 2026-10）

| ✅ 可用 | ⚠️ 部分 | ❌ 不可用 |
|---|---|---|
| 屏幕显示 | 触摸(冷启动后有效) | WiFi / 蓝牙 |
| USB 网络(设备侧172.16.42.1) | 电池/慢充 | 蜂窝/通话/SMS |
| 内部存储、USB 串口(ttyGS0) | 震动 | 相机 / 音频 / GPS |
| | | GPU 加速(纯软渲染)、休眠(已禁用) |

## 目录结构

```
build/
├── Heimdall/          heimdall v1.4.2 源码+编译产物 (Mac 上唯一的刷机工具)
├── uboot/u-boot/      chiffathefox U-Boot (exynos9820 分支)
├── kernel/            linux-postmarketos-exynos9820-7.2.0-r1.apk (Nura edge 仓库)
├── vm/                ubuntu-base-26.04.1-base-arm64.tar.gz
├── assets/
│   ├── vmlinuz                     内核 (EFI stub)
│   ├── systemd-bootaa64.efi        systemd-boot 引导器 (Alpine systemd 包提取)
│   ├── esp/                        ESP 内容: loader.conf + entries + EFI/BOOT
│   ├── rootfs/                     rootfs 配置 overlay (USB网络/gadget/serial/apt源)
│   ├── resolve-debs.py             deb 依赖闭包解析器 (TUNA Packages 索引)
│   └── mkbootimg_lite.py           Android boot v0 镜像打包器 (S10 参数)
└── flash/
    ├── recovery.img                LineageOS 官方 recovery (替代 TWRP)
    ├── debs/                       systemd/udev/kmod/openssh-server/sudo... 闭包
    ├── modules.tar.gz              内核模块
    ├── install-ubuntu.sh           设备端安装脚本 (recovery shell 中运行)
    ├── flash-uboot.sh              设备端: 备份原厂boot + 刷 U-Boot
    └── boot-stock-backup.img       (刷机时生成) 原厂 boot 备份 — 务必保留!
```

## 刷机流程（`build/flash.sh` 分步执行）

1. `heimdall flash --RECOVERY flash/recovery.img` （Download 模式，S10 不支持 fastboot）
2. 进 recovery（音量+ + Bixby + 电源），**先备份原厂 boot 分区**
3. adb push 全部 payload 到 recovery 的 /tmp（RAM）
4. `sh /tmp/install-ubuntu.sh`：在设备 chroot 里用 sfdisk 分区、mke2fs/mkfs.vfat 格式化、
   解压 ubuntu-base、dpkg 安装 systemd 全家桶、写入 USB 网络等配置
5. `sh /tmp/flash-uboot.sh`：备份 + 把 U-Boot boot.img 写入 boot 分区
6. 重启 → S-Boot → U-Boot → systemd-boot → 内核 → Ubuntu

## 关键决策记录

- **S10 Download 模式无 fastboot**（S20+ 才有），首次刷机必须 heimdall（本机源码编译 v1.4.2）
- **heimdall v1.4.2 刷大分区会中断**（pmOS 官方注释）→ 只用它刷小体积 recovery，大数据走 adb
- **TWRP 官方 CDN 防爬** → 用 LineageOS 官方 recovery 替代（同为 recovery 分区镜像）
- **ubuntu-base 26.04 不带 systemd** → 本地按 TUNA Packages 索引解析 deb 闭包(145个)，
  推到设备后 chroot+dpkg 安装，无需设备联网
- **分区/格式化全部在设备 chroot 内完成**（sfdisk/mke2fs/mkfs.vfat 来自 base+deb），
  Mac 无需 mkfs/e2fsprogs/qemu（这台 Intel Mac 是 Homebrew Tier 3，装不上 bottle）
- **分区暴露用 losetup -P**（内核对“分区内分区”的启动时扫描由 pmOS 实践证明可行）
- mkbootimg 参数从真实 S10 boot 镜像解析：base=0x10000000, kernel=0x8000, tags=0x100, page=2048, v0 头

## 首次启动后

- 屏幕: fbcon 内核控制台 + getty@tty1（触摸可登录，账号 ubuntu/ubuntu，root 密码 ubuntu）
- USB 串口: Mac 上 `screen /dev/tty.usbmodem* 115200`（root 自动登录）
- USB 网络: Mac 侧 IP 172.16.42.2（共享网络见下），设备 172.16.42.1，`ssh ubuntu@172.16.42.1`
- 装桌面: `sudo apt update && sudo apt install lxqt sddm`（走 TUNA 源）

### Mac 共享网络给手机 (macOS)

```bash
sudo sysctl -w net.inet.ip.forwarding=1
echo "nat on en0 from 172.16.42.0/24 to any -> (en0)" | sudo pfctl -f -
sudo pfctl -e
# USB 网卡接口名用 `netstat -rn` 看（通常是 enX, 172.16.42.2/24 需手动配）
sudo ifconfig enX 172.16.42.2/24 up
```

### 回退安卓

- boot 分区: `heimdall flash --BOOT flash/boot-stock-backup.img`（或 Odin 刷原厂固件）
- userdata: 恢复出厂设置即重建（GPT 布局会被 Android 重新格式化）

## 已知坑

- 触摸在软重启后失效 → 关机再开机（power cycle）恢复
- 快充不可用；无线充电电量状态误报
- suspend 已通过 systemd mask 禁用（内核已知问题）
- S10 的 Download 模式无 fastboot（S20+ 才有），必须用 heimdall
- heimdall v1.4.2 刷大分区会中断 → 本方案只用它刷小体积 recovery，大数据走 adb
