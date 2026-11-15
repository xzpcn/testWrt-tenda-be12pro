#!/bin/bash
# diy-part1: 在 feeds update 之前执行, 主要加第三方源
# 工作流调用位置: openwrt/ 目录下

# 1. 彻底清除前人在 feeds.conf.default 中遗留的冲突残留行（防止再次报第 11 或 13 行错误）
sed -i '/luci-app-temp-status/d' feeds.conf.default
sed -i '/temp-status/d' feeds.conf.default
# Add third-party feeds
#cat >> feeds.conf.default << 'EOF'
#src-git kenzo https://github.com/kenzok8/openwrt-packages
#src-git small https://github.com/kenzok8/small
#EOF

# 2. 正常添加符合 Feeds 规范的 kenzok8 dae/daed 源
if ! grep -q "openwrt-daede" feeds.conf.default; then
  echo 'src-git daede https://github.com/kenzok8/openwrt-daede.git' >> feeds.conf.default
fi

# golang 版本问题不在这里动: github.com/golang/go 是 go 语言本身, 里面没有
# lang/golang (openwrt 的 golang 包定义在 openwrt/packages feed), 早先的 clone
# 一直是 cp: cannot stat ... No such file or directory, 属于空转。
# dae 需要的 go 1.27 由 diy-part2.sh 第 5 段处理 (那时 feeds 已经 update/install
# 完, 注入 feeds/packages/lang/golang/ 才不会被 feeds update 覆盖掉)。

# 3. 针对“单体插件仓库”temp-status，不采用 feeds 源机制，直接 git clone 丢进本地 package 目录
# 这样能完全避开 feeds.conf.default 的语法解析，且百分之百能被编译识别
mkdir -p package/custom
git clone --depth 1 https://github.com/OneNAS-space/luci-app-temp-status package/custom/luci-app-temp-status
# 打印 feeds.conf.default 结构，确保控制台日志干净无污染
echo "===== feeds.conf.default 内容 ====="
cat feeds.conf.default
