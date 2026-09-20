# Kernel patch adaptations for R5S

按内核版本存储已适配好的 OpenWrt 补丁集。

## 结构

    6.12.110/
    ├── generic-backport-6.12/
    ├── generic-pending-6.12/
    ├── generic-hack-6.12/
    ├── rockchip-patches-6.12/
    ├── patch-report.txt
    └── READY

由 build-r5s-openwrt.yml 在 linux-stable 模式下自动生成并推送。
