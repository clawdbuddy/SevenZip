#!/usr/bin/env bash
# 手工 .appex 构建管线（SwiftPM 不支持构建应用扩展，改用 swiftc 直接编译打包）。
# 用法：bash scripts/build-extensions.sh [app_bundle_path]
# 产物：<app>/Contents/PlugIns/SevenZipQuickLook.appex 与 SevenZipFinderSync.appex
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="${1:-$project_root/dist/SevenZip.app}"
sdk="$(xcrun --show-sdk-path)"
target="arm64-apple-macos14.0"
signing_identity="${APP_SIGN_IDENTITY:--}"
engine="$app_root/Contents/Resources/bin/7zz"

if [[ ! -d "$app_root/Contents" ]]; then
    echo "错误：未找到 app bundle：$app_root（请先运行 build-macos.sh 或传入正确路径）。" >&2
    exit 1
fi

sign_item() {  # sign_item <路径> <entitlements|->
    if [[ "$signing_identity" == "-" ]]; then
        if [[ "$2" == "-" ]]; then
            codesign --force --sign - "$1"
        else
            codesign --force --sign - --entitlements "$2" "$1"
        fi
    else
        if [[ "$2" == "-" ]]; then
            codesign --force --sign "$signing_identity" --options runtime --timestamp "$1"
        else
            codesign --force --sign "$signing_identity" --options runtime --timestamp \
                --entitlements "$2" "$1"
        fi
    fi
}

mkdir -p "$app_root/Contents/PlugIns"

build_appex() {  # build_appex <名称> <模块名> <源码目录> <entitlements> [额外 .swift ...]
    local name="$1" module="$2" src_dir="$3" entitlements="$4"
    shift 4
    local appex="$app_root/Contents/PlugIns/$name.appex"
    echo "  构建 $name.appex"
    rm -rf "$appex"
    mkdir -p "$appex/Contents/MacOS"
    # 扩展无 @main 入口：-parse-as-library 去掉 _main 要求，
    # 入口改为 Foundation 提供的 NSExtensionMain（与 Xcode appex 模板一致）。
    swiftc -O -parse-as-library -sdk "$sdk" -target "$target" -module-name "$module" \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -framework Foundation -framework AppKit -framework Quartz -framework FinderSync \
        "$src_dir"/*.swift "$@" \
        -o "$appex/Contents/MacOS/$name"
    cp "$src_dir/Info.plist" "$appex/Contents/Info.plist"
    # macOS 26+ 的 pkd 强制要求扩展带 app-sandbox entitlement，否则拒绝注册。
    sign_item "$appex/Contents/MacOS/$name" "$entitlements"
    sign_item "$appex" "$entitlements"
}

# Quick Look：空格预览归档清单。复用 ArchiveCore.swift（仅依赖 Foundation，
# 含 7zz 清单解析与 GBK 名称恢复），直接编译进扩展。
# 沙箱扩展只能执行自身 bundle 内的程序，故把 7zz 拷入扩展并以 sandbox+inherit 签署。
build_appex SevenZipQuickLook SevenZipQuickLook \
    "$project_root/Extensions/QuickLookPreview" \
    "$project_root/Extensions/QuickLookPreview/Entitlements.plist" \
    "$project_root/Sources/ArchiveCore/ArchiveCore.swift"
ql_appex="$app_root/Contents/PlugIns/SevenZipQuickLook.appex"
if [[ -x "$engine" ]]; then
    mkdir -p "$ql_appex/Contents/Resources/bin"
    cp "$engine" "$ql_appex/Contents/Resources/bin/7zz"
    chmod 755 "$ql_appex/Contents/Resources/bin/7zz"
    sign_item "$ql_appex/Contents/Resources/bin/7zz" \
        "$project_root/Extensions/QuickLookPreview/EngineEntitlements.plist"
    # 内嵌引擎变化后重签扩展本体。
    sign_item "$ql_appex" "$project_root/Extensions/QuickLookPreview/Entitlements.plist"
else
    echo "警告：未找到 7zz（$engine），Quick Look 扩展将无法列出归档内容。" >&2
fi

# Finder Sync：右键一级菜单（打开 / 解压到当前目录 / 压缩所选项目）。
build_appex SevenZipFinderSync SevenZipFinderSync \
    "$project_root/Extensions/FinderSync" \
    "$project_root/Extensions/FinderSync/Entitlements.plist"

echo "扩展构建完成：$app_root/Contents/PlugIns"
