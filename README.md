## SM-G973N（韩版 KT 定制，beyond1）安装原生Ubuntu

* 关键参数到手：base=0x10000000, kernel_offset=0x8000, tags=0x100, page_size=2048（真实 S10 boot 镜像解析出来的）。刷机顺序也定型了：先刷 recovery → 备份原厂 boot → TWRP 里分区+装系统 → 最后才替换 boot 为 U-Boot（保证可回退）。
* Nura/postmarketOS 的 mainline 内核（linux-postmarketos-exynos9820，接近 mainline、内核 7.2）+ 手工组装 Ubuntu rootfs 刷入 userdata 分区，U-Boot（chiffathefox fork）负责 EFI 启动。 
* fastboot 一直没出现 —— 这基本证实了 S10（Exynos 9820 这一代）的 Download 模式不支持 fastboot（那是 S20/S21 之后才加的），所以首次刷机必须走 heimdall（macOS 上的 Odin 替代品），需要从源码编译。 
* GNU make 4.4.1 就位，重启 U-Boot 编译；TWRP 官方 CDN 有防爬，改用 LineageOS 官方 recovery（同一用途，API 直链无防爬）：

