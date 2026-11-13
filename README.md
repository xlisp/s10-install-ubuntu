# Samsung Galaxy S10 (SM-G973N 韩版) 原生 Ubuntu 26.04 安装项目

把韩版 Galaxy S10（Exynos 9820，`beyond1lte`）刷成**原生 Ubuntu 26.04 LTS**（非 Ubuntu Touch）。

> ⚠️ **硬件现状（mainline 内核 7.2，Nura wiki 2026-10）**：
> ✅ 屏幕/显示、触摸（冷启动后）、USB 网络、内部存储、震动
> ⚠️ 电池（慢充）、suspend 已禁用（内核已知问题）
> ❌ WiFi / 蓝牙 / 蜂窝 / 相机 / 音频 / GPS / GPU 加速（纯软渲染）
> 刷机后手机 = 一台带屏、靠 USB 连电脑联网的 Linux 小主机。**userdata 全部数据清空。**

## 最终架构

```
S-Boot（三星原厂引导，不可替换，不传 DTB → mainline 内核必须经 U-Boot）
  └─ U-Boot（chiffathefox/exynos9820 分支 → boot 分区，自带 beyond1lte DTB + UFS/显示驱动）
       └─ EFI → systemd-boot（ESP 分区，ext4）
            ├─ rescue.conf  → 内核 + busybox 救援 initramfs（安装器，安装完自动切默认项）
            └─ ubuntu.conf  → 内核 root=PARTLABEL=ubuntu-root（最终态）
                 └─ Ubuntu 26.04 (resolute) — userdata 内嵌 GPT 的 ext4 分区
```

userdata 分区被当作整块磁盘，内建 GPT：

| 分区 | 大小 | 文件系统 | 作用 |
|---|---|---|---|
| `esp` | 512MiB | ext4 | systemd-boot + vmlinuz + 救援 initramfs |
| `ubuntu-root` | ~110GiB | ext4 (PARTLABEL=ubuntu-root) | Ubuntu rootfs |
| （未分区尾部） | 1GiB | raw | payload 暂存区（安装器从这里读取） |

## 三个关键环境事实（踩过的坑）

1. **S-Boot 不能直接引导 mainline 内核**（不传 DTB）→ boot 分区必须是 U-Boot；
   mainline 内核只在 U-Boot 的 EFI+DTB 链路下才能启动。
2. **S10 Download 模式没有 fastboot**（S20+ 才有）→ 刷 recovery/U-Boot 用 heimdall
   （本机源码编译 v1.4.2，链接参数需 `-framework IOKit CoreFoundation Security`）。
   **heimdall 刷大分区会中断**（pmOS 官方注释）→ 只用它刷小镜像，大数据走 adb。
3. **recovery/TWRP 内核（4.14）不可靠**：loop 设备写入黑洞、vfat/ext4 挂载失败、
   无嵌套分区重扫、toybox dd 语义怪异 → **所有文件系统操作要么在 chroot（ubuntu-base
   自带 C 工具：sfdisk/mke2fs/debugfs）要么在救援内核（mainline，一切正常）里做**。
   另外 Ubuntu 26.04 的 coreutils 是 **Rust 实现**，其 `dd` 在 recovery 的老内核 chroot
   里会 panic —— 一律避免在 chroot 里用 dd。

## 目录结构

```
build/
├── flash/
│   ├── boot-stock-backup.img   原厂 boot 备份（恢复安卓的命根子，勿删！）
│   ├── recovery.img            LineageOS recovery（被 TWRP 替代亦可）
│   ├── u-boot.img              U-Boot Android boot 镜像 → 刷入 boot 分区
│   ├── ubuntu-base.tar.gz      Ubuntu 26.04.1 base rootfs
│   ├── staging-payload.tar.gz  暂存区 blob（rootfs源+debs+内核+ESP素材+救援initramfs）
│   ├── initramfs-rescue.gz     busybox 救援 initramfs
│   ├── twrp-stage.sh           设备端：暂存 payload + 预置 ESP（TWRP 内运行）
│   └── final-flash.sh          Mac 端驱动：推文件 + 跑设备端脚本 + 重启
├── assets/
│   ├── vmlinuz                 pmOS/Nura mainline 内核 7.2.0-rc2 (EFI stub)
│   ├── esp/                    ESP 内容素材（systemd-boot、loader 配置）
│   ├── rootfs/                 rootfs overlay（USB 网络/串口/apt 源等）
│   ├── resolve-debs.py         deb 依赖闭包解析器（TUNA Packages 索引）
│   └── mkbootimg_lite.py       Android boot v0 打包器（S10 参数）
├── rescue/init                 救援安装器脚本（mainline 内核 + busybox 运行）
├── build-rescue.sh             构建救援 initramfs + 暂存 blob
├── stage-esp.sh → flash/twrp-stage.sh   （已合并为 twrp-stage.sh）
├── Heimdall/build/bin/heimdall 已编译 heimdall CLI
└── uboot/out/u-boot.bin        已编译 U-Boot（→ u-boot.img）
```

## 完整流程

### 阶段 0：准备（本仓库已完成的构建）

- `brew`（TUNA 镜像）+ 源码编译：heimdall、GNU make 4.4、bash 5.2（~/tools/bash52）
- 交叉编译 U-Boot：`aarch64-linux-musl-gcc`（本机已有 musl-cross），
  `./cruelbuild`-式流程：`make O=../out CROSS_COMPILE=aarch64-linux-musl- exynos9820_defconfig && make -j`
- 从 Nura edge 仓库下载 `linux-postmarketos-exynos9820-7.2.0-r1.apk`（vmlinuz+modules），
  从 Alpine 仓库提取 systemd-bootaa64.efi、busybox-static、静态版 e2fsprogs 的动态 mke2fs+musl
- 从 TUNA 下载 ubuntu-base-26.04.1-arm64（**不含 systemd**！→ 本地按 Packages 索引解析
  145 个 deb 闭包：systemd/udev/kmod/openssh-server/sudo/fdisk/dosfstools…）
- `./build-rescue.sh` → initramfs-rescue.gz + staging-payload.tar.gz

### 阶段 1：解锁链路（本机已做）

1. 手机 OEM 解锁（开发者选项 → OEM 解锁 → Download 模式长按音量+；**已解锁可跳过**）
2. `heimdall flash --RECOVERY recovery.img`（或用户自行刷 TWRP）→ 进入 recovery
3. **备份原厂 boot**：`adb shell dd if=/dev/block/by-name/boot of=/tmp/boot.bak && adb pull`
4. 刷 TWRP 后先做一次**冷启动**（触摸屏在软重启后失效，冷启动恢复 —— Nura 已知问题）

### 阶段 2：分区（TWRP 内，本机已做，脚本化见 git 历史）

在 TWRP 的 chroot（ubuntu-base + fdisk deb）里对 userdata 分区内建 GPT：

```
label: gpt
name="esp", size=512MiB, type=uefi
name="ubuntu-root", size=28828416, type=linux      # 余下 1GiB 为暂存区
```

并把 **U-Boot** 写入 boot 分区（`dd if=u-boot.img of=/dev/block/by-name/boot`）。

### 阶段 3：一键刷入（final-package）

前提：TWRP 已就位、userdata 已按上表分区、boot 分区刷过 U-Boot 后被覆盖也不影响
（本包自带 U-Boot）。手机 adb 已授权（TWRP 下弹窗点允许；触摸失灵就先冷启动）。

```bash
cd ~/PyPro/s10-install-ubuntu
adb push final-package /tmp/pkg
adb shell sh /tmp/pkg/FLASH-ME.sh     # 跑完自动重启
```

脚本做四件事：boot 分区刷 U-Boot（大字体 + blkmap x8 修复）→ payload 写入暂存区 →
chroot mke2fs+debugfs 构建 ESP（systemd-boot + extlinux 双引导，默认 rescue）→
重启。随后救援安装器在 mainline 内核上自动完成安装并切换默认启动项，再次重启即
进入 Ubuntu 26.04（纯终端）。

调试通道：rescue 起来后 USB NCM 网卡出现（Mac 侧 `sudo ifconfig enX 172.16.42.2/24 up`），
`nc 172.16.42.1 23` 进 busybox shell；屏幕上 panic=30 会把错误信息停留 30 秒可读。

### 首次启动后（阶段 4）

- 屏幕：fbcon 控制台 + getty@tty1（账号 `ubuntu` / `root`，密码均 `ubuntu`）
- USB 串口：`screen /dev/tty.usbmodem* 115200`（root 自动登录）
- USB 网络：Mac 侧 `sudo ifconfig enX 172.16.42.2/24 up`（enX = 新出现的 USB 网卡），
  手机侧 172.16.42.1；共享网络：
  ```bash
  sudo sysctl -w net.inet.ip.forwarding=1
  echo "nat on en0 from 172.16.42.0/24 to any -> (en0)" | sudo pfctl -f -
  sudo pfctl -e
  ```
- SSH：`ssh ubuntu@172.16.42.1`（openssh-server 已预装）
- 装桌面：`sudo apt update && sudo apt install lxqt sddm`（TUNA ubuntu-ports 源已配好）

### 回退安卓

- `heimdall flash --BOOT flash/boot-stock-backup.img`（或 Odin 刷原厂完整固件）
- userdata 恢复出厂即可重建（GPT 会被 Android 重写）

## 已知坑速查

| 症状 | 原因/解法 |
|---|---|
| 卡三星 logo | boot 分区镜像无法被 S-Boot 引导（如直启 mainline 内核）→ 重刷 U-Boot |
| 触摸失灵 | TWRP/recovery 软重启后的已知问题 → 冷启动（长按电源 10s） |
| 授权弹窗点不动 | 同上，先冷启动再点允许 |
| recovery/loop 下写入丢失 | 4.14 recovery 内核 loop 黑洞 → 用 staging+chroot 方案（本仓库已如此） |
| chroot 里 dd 段错误 | Ubuntu 26.04 Rust coreutils 在老内核 panic → 换 recovery 的 toybox dd |
| mksh heredoc 报错 | recovery 的 mksh heredoc 临时文件问题 → 全部 printf+管道/文件 |
| rescue 循环重启 | init 顺序错误（busybox --install 需先挂 /proc）→ 已修复；panic=30 便于读屏 |
| GPT "消失" | 4K 扇区设备 LBA1 = 字节 4096，不是 512 —— 检查位置要对 |
