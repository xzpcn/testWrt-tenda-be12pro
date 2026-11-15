#!/bin/bash
# diy-part2: 在 feeds install 之后、copy .config 之前执行
# 工作流调用位置: openwrt/ 目录下
# 主要做: 主机名、IP、版本标识等轻量定制 + honk 源码树就位, 不动内核

# 1. 默认 LAN IP 改成 192.168.1.3
sed -i 's/192\.168\.1\.1/192.168.1.3/g' package/base-files/files/bin/config_generate
if ! grep -q '192\.168\.1\.3' package/base-files/files/bin/config_generate; then
  echo "ERROR: LAN 默认 IP 192.168.1.3 未生效" >&2; exit 1
fi

# =====================================================================
# 添加自定义软件源--- rc.local 守护进程（改用 >> 追加防止抹除）
# =====================================================================
mkdir -p package/base-files/files/etc
cat > package/base-files/files/etc/rc.local << 'EOF'
#!/bin/sh
(
    sleep 5
    mkdir -p /etc/apk/repositories.d
    mkdir -p /etc/opkg
    # 第一行可以用 > 或者是用 >>（如果你想保留原厂自带的注释，这里也必须用 >>）
    # 为了保险，如果你想完全不破坏原厂注释，这里全部统一改为 >> 
    echo 'https://down.dllkids.xyz/openwrt-feed/jell/25.12/aarch64_cortex-a53/packages.adb' >> /etc/apk/repositories.d/customfeeds.list
    echo 'src/gz custom_jell_adb https://down.dllkids.xyz/openwrt-feed/jell/25.12/aarch64_cortex-a53/packages.adb' >> /etc/opkg/customfeeds.list 
    # 核心修正：后续的写入必须全部使用 >> 追加，绝对不能用单大于号 > !
    echo 'https://down.dllkids.xyz/openwrt-feed/25.12/aarch64_cortex-a53/packages.adb' >> /etc/apk/repositories.d/customfeeds.list
    echo 'src/gz custom_dllkids_adb https://down.dllkids.xyz/openwrt-feed/25.12/aarch64_cortex-a53/packages.adb' >> /etc/opkg/customfeeds.list
    # 放行未签名策略
    echo "option allow_untrusted" >> /etc/apk/apk.conf
    echo "option check_signature 0" >> /etc/opkg.conf
) &
exit 0
EOF
chmod +x package/base-files/files/etc/rc.local

# =====================================================================
# 【智能多频隔离 + 信道自动】双重保险开机 UCI 初始化脚本
# =====================================================================
mkdir -p package/base-files/files/etc/uci-defaults
cat > package/base-files/files/etc/uci-defaults/99-default-wifi << 'EOF'
#!/bin/sh
# 策略 1：首先将所有无线物理硬件（radio）的信道强行设置为自动（auto）
uci -q show wireless | grep "=wifi-device" | cut -d'.' -f2 | cut -d'=' -f1 | while read -r device; do
    uci set wireless.${device}.channel='auto'
done
uci commit wireless

# 策略 2：通过设备代号的物理索引（数字特征）进行无线名称和加密的切分
uci -q show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1 | while read -r iface; do
    device=$(uci -q get wireless.${iface}.device)
    [ -z "$device" ] && continue

    if echo "$device" | grep -qE "1$|2$|5g|wlan1"; then
        uci set wireless.${iface}.ssid='DT-5G'
        uci set wireless.${iface}.encryption='sae'
    else
        uci set wireless.${iface}.ssid='ImmortalWrt'
        uci set wireless.${iface}.encryption='psk2'
    fi
    uci set wireless.${iface}.key='mqy-4708'
done
uci commit wireless

# 策略 3：通过排队顺序终极切割，确保原厂驱动双频百分之百完美剥离
ifaces=$(uci -q show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1)
count=0
for iface in $ifaces; do
    count=$((count + 1))
    if [ "$count" -eq 1 ]; then
        uci set wireless.${iface}.ssid='ImmortalWrt'
        uci set wireless.${iface}.encryption='psk2'
    else
        uci set wireless.${iface}.ssid='DT-5G'
        uci set wireless.${iface}.encryption='sae'
    fi
    uci set wireless.${iface}.key='mqy-4708'
done
uci commit wireless
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-default-wifi


# 2. 默认主机名 -> NatserverWrt (顶栏侧边品牌等取 hostname)
sed -i "s/hostname='[^']*'/hostname='NatserverWrt'/g" package/base-files/files/bin/config_generate
if ! grep -q "hostname='NatserverWrt'" package/base-files/files/bin/config_generate; then
  echo "ERROR: hostname NatserverWrt 未生效" >&2; exit 1
fi

# 3. 固件名 -> NatserverWrt (CONFIG_VERSION_DIST 符号不存在, 改 version.mk 的兜底值;
#    影响镜像文件名前缀 + DISTRIB_ID + openwrt_release 的 %D 显示)
sed -i 's/\$(VERSION_DIST),OpenWrt)/$(VERSION_DIST),NatserverWrt)/' include/version.mk
if ! grep -q '$(VERSION_DIST),NatserverWrt)' include/version.mk; then
  echo "ERROR: VERSION_DIST NatserverWrt 未生效" >&2; exit 1
fi

# 4. 固件版本描述 (LuCI 概览/登录窗口的 Firmware Version)
if [ -f package/base-files/files/etc/openwrt_release ]; then
  echo "DISTRIB_DESCRIPTION='NatserverWrt snapshot + honk (Tenda BE12 Pro)'" >> package/base-files/files/etc/openwrt_release
fi

# 5. honk 源码就位
#    官方 feed daeuniverse/openwrt-packages 的 honk 包不在 Makefile 里下载源码:
#    Build/Prepare 只认包目录下的 ./src (见 feeds/daeuniverse/honk/Makefile 的注释),
#    所以要在这里把 honk 源码 clone 进 feeds/daeuniverse/honk/src。
#    feeds update/install 已经跑完, 这一步不会被覆盖。
#    升级版本: 只改下面 HONK_TAG, 必须是 https://github.com/daeuniverse/honk/tags 里的
#    一个 tag; 工作流装哪个 rustc/nightly/bpf-linker 是从源码里的 pin 文件现场读的,
#    会跟着一起换, 不需要改工作流。
#    注: 包版本 (apk 里的 0.1.0_beta6) 由 feed 的 Makefile 自己写死, 换 tag 时如果
#    feed 没跟着更新, 编出来的二进制版本号会显示成 feed 里那个, 功能不受影响。
HONK_TAG=v0.1.0-beta.6
HONK_FEED_DIR=feeds/daeuniverse
HONK_SRC_DIR="$HONK_FEED_DIR/honk/src"

[ -d "$HONK_FEED_DIR/honk" ] || {
  echo "ERROR: 没找到 $HONK_FEED_DIR/honk, daeuniverse feed 没装上 (检查 diy-part1)" >&2
  exit 1
}
if [ ! -d "$HONK_SRC_DIR" ]; then
  git clone --depth 1 --branch "$HONK_TAG" https://github.com/daeuniverse/honk "$HONK_SRC_DIR" || {
    echo "ERROR: honk $HONK_TAG 源码拉取失败" >&2
    exit 1
  }
fi
# 已经有一份源码树时不覆盖 (万一是手工放进去的), 但版本不对一定要停下来
HONK_SRC_TAG=$(git -C "$HONK_SRC_DIR" describe --tags --always 2>/dev/null || echo "非 git 目录")
[ "$HONK_SRC_TAG" = "$HONK_TAG" ] || {
  echo "ERROR: $HONK_SRC_DIR 是 $HONK_SRC_TAG, 不是 $HONK_TAG" >&2
  echo "ERROR: 确认无误后删掉该目录再重跑 (rm -rf $HONK_SRC_DIR)" >&2
  exit 1
}
# honk 的构建脚本依赖这几个文件: 两个 rust 工具链 pin、bpf-linker/doona 版本 pin、
# 前端拉取脚本。少任何一个, Build/Compile 一定炸, 现在报出来最省时间
for f in rust-toolchain.toml crates/honk-ebpf/rust-toolchain.toml \
         .github/ci/pins.env ci/fetch-doona.sh Cargo.toml crates/honk-core/Cargo.toml; do
  [ -f "$HONK_SRC_DIR/$f" ] || { echo "ERROR: honk 源码缺少 $f" >&2; exit 1; }
done
echo "OK: honk 源码 $HONK_SRC_TAG, 稳定工具链 $(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$HONK_SRC_DIR/rust-toolchain.toml" | head -1), eBPF 工具链 $(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$HONK_SRC_DIR/crates/honk-ebpf/rust-toolchain.toml" | head -1)"

./scripts/feeds list | grep -E "^(honk|luci-app-honk|luci-lib-daeuniverse|vmlinux-btf|v2ray-geo)" \
  || echo "WARN: honk 相关 feed 未列出, 请检查 diy-part1 是否生效"

# 6. 浏览器标签页标题 + 登录窗口大标题 (fanchmwrt 主题硬编码 FanchmWrt, 与 hostname 无关)
sed -i 's|<title>FanchmWrt</title>|<title>NatserverWrt</title>|' package/fcm/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/header.ut
if ! grep -q '<title>NatserverWrt</title>' package/fcm/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/header.ut; then
  echo "ERROR: 浏览器标签 <title>NatserverWrt</title> 未生效 (header.ut 结构变了?)" >&2; exit 1
fi
sed -i "s/'FanchmWrt'/'NatserverWrt'/" package/fcm/luci-theme-fanchmwrt/htdocs/luci-static/resources/view/fanchmwrt/sysauth.js
if ! grep -q "'NatserverWrt'" package/fcm/luci-theme-fanchmwrt/htdocs/luci-static/resources/view/fanchmwrt/sysauth.js; then
  echo "ERROR: 登录窗口标题 NatserverWrt 未生效 (sysauth.js 结构变了?)" >&2; exit 1
fi
if grep -q "'FanchmWrt'" package/fcm/luci-theme-fanchmwrt/htdocs/luci-static/resources/view/fanchmwrt/sysauth.js; then
  echo "ERROR: sysauth.js 仍残留 'FanchmWrt'" >&2; exit 1
fi
echo "OK: 标签页/登录窗口标题 -> NatserverWrt"

# 动态生成一份只含官方源、不含任何第三方 dae/honk 源的 distfeeds.list 预设文件
# 这样打包固件时，系统会自动用这个干净的文件覆盖生成的默认文件
cat << 'EOF' > files/etc/apk/repositories.d/distfeeds.list
https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/packages/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/base/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/luci/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/packages/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/routing/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/telephony/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/video/packages.adb
EOF

echo "===== diy-part2 阶段所有配置调整就绪 ====="
