#!/usr/bin/env bash
# Optional release step requiring an Apple Developer ID and stored notarytool credentials.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dmg_path="${1:-$(ls -t "$project_root"/dist/SevenZip-*-macOS-arm64.dmg 2>/dev/null | head -1)}"
profile="${NOTARY_PROFILE:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "公证必须在安装 Xcode 的 macOS 环境执行。" >&2
    exit 1
fi
if [[ -z "$profile" ]]; then
    echo "请设置 NOTARY_PROFILE（用 xcrun notarytool store-credentials 在本机钥匙串创建）。" >&2
    exit 1
fi
if [[ "${APP_SIGN_IDENTITY:--}" == "-" ]]; then
    echo "公证要求 Developer ID 签名；请设置 APP_SIGN_IDENTITY。" >&2
    exit 1
fi
if [[ ! -f "$dmg_path" ]]; then
    echo "未找到待公证 DMG：$dmg_path" >&2
    exit 1
fi

xcrun notarytool submit "$dmg_path" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
echo "公证并装订票据完成：$dmg_path"
