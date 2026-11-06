# 七压 SevenZip

**基于 7-Zip 26.05 官方引擎的原生 macOS 图形界面**（Apple Silicon · SwiftUI)

[![License: LGPL v3](https://img.shields.io/badge/License-LGPL_v3-blue.svg)](LICENSE)
[![build](https://github.com/clawdbuddy/SevenZip/actions/workflows/build.yml/badge.svg)](https://github.com/clawdbuddy/SevenZip/actions/workflows/build.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20%7C%20Apple%20Silicon-lightgrey)
![Engine](https://img.shields.io/badge/engine-7--Zip%2026.05-green)

官方 7-Zip 在 macOS 上只有命令行 `7zz`。本项目保留官方引擎源码原样编译，用原生 SwiftUI 实现图形界面——不是把 Windows 的 `7zFM.exe` 跨平台移植。中文名「七压」，英文名 SevenZip，随系统语言自动切换。

## 功能特性

- **7zFM 交互范式**：菜单栏 + 大图标工具栏 + 地址栏 + 文件列表 + 状态栏，压缩包像文件夹一样双击进入，`..` 返回上级，支持右键上下文菜单
- **双窗格（F9）**：左右两个独立浏览窗格，Tab 或点击切换焦点，F5/F6 跨窗格复制/移动（磁盘 ⇄ 归档双向）
- **列排序与视图模式**：名称/大小/压缩后/修改时间点击表头排序；详细资料 / 大图标两种视图；归档内平铺视图（不折叠目录）
- **嵌套归档**：压缩包里的压缩包双击直接进入（临时解压、只读），`..` 逐层退出，地址栏显示 `outer.zip\inner.7z\`
- **全格式支持**：7z / ZIP / RAR / TAR / GZ / XZ 的浏览、解压、测试；7z / ZIP / TAR 的创建与修改（添加、删除、重命名条目）
- **旧编码 ZIP 中文乱码修复**：自动识别 GBK/GB18030 编码的旧式 ZIP（Windows 中文环境打包）,PUA 映射无损恢复文件名，列表、选择性解压、落地重命名全链路生效
- **加密归档**：7z 文件名加密、ZIP AES-256；密码经 stdin 管道传递，不出现在命令行参数、环境变量或日志中；列表失败后自动弹出密码重试
- **Finder 深度集成**:右键一级菜单（Finder Sync 扩展：用七压打开 / 解压到当前目录 / 压缩所选项目）+ 服务菜单；应用内「工具 → 文件类型关联」复选框面板，可绑定/移除各格式的默认打开方式；关联后 Finder 中各格式显示专属文档图标
- **Quick Look 空格预览**：选中压缩包按空格即显示摘要行（格式·压缩方法·Solid·文件数·原始→物理大小与压缩率）与可展开树形清单（含 GBK 乱码恢复）；2 秒/1 万条目截断保护，加密归档明确提示
- **Finder 快速操作**：预览面板与右键「快速操作」中的「用七压解压」「用七压压缩」（Touch Bar 同显）
- **解压对话框**：目标目录记忆与浏览、同名子文件夹、路径模式（完整路径/平铺）、消除根目录重复、覆盖模式、密码输入（可显示明文）
- **属性面板**：归档总计（条目数/原始大小/压缩后/压缩率）+ 单条目 CRC、压缩方法、属性、加密标记
- **压缩对话框高级区**：压缩方法（7z: LZMA2/LZMA/PPMd/BZip2/Copy;ZIP: Deflate/BZip2/LZMA/PPMd/Copy)、字典大小、词长、固实块开关、自由参数透传；密码二次确认（不一致即禁建）+ 可显示明文；ZIP 加密方法（AES-256/ZipCrypto)；排除资源叉（._*)；压缩后删除源文件（带警示）
- **主窗口信息列**：名称/大小/压缩后/修改时间/创建时间/注释/子文件夹数/文件数，全部支持表头排序；状态栏显示「已选 X / 共 Y 个对象」
- **专业选项**：压缩级别、CPU 线程、分卷、macOS 元数据排除；批量压缩/解压队列、格式转换、多算法校验和（CRC32/CRC64/SHA-1/SHA-256/SHA-512/BLAKE2sp）；浅色/深色/跟随系统外观；列表网格线开关
- **工具**：性能测试 Benchmark（`7zz b` 实时输出 + 总评分）、启动时检查更新（可关闭）、重置所有设置
- **命令行**：应用内附 `SevenZipCLI`，与 GUI 共用同一套命令构造逻辑，适合脚本自动化

## 系统要求

- Apple Silicon Mac(M1 及更新，ARM64)
- macOS 13 或更新
- 构建：Xcode Command Line Tools（无需完整 Xcode;Swift 5.9+)

## 构建

```bash
git clone https://github.com/clawdbuddy/SevenZip.git
cd SevenZip
bash scripts/build-macos.sh
open dist/SevenZip.app
```

构建产物：

| 产物 | 说明 |
| --- | --- |
| `dist/SevenZip.app` | 可直接运行的应用（ad-hoc 签名） |
| `dist/SevenZip-macOS-arm64.zip` | 分发压缩包 |
| `dist/SevenZip-macOS-arm64.dmg` | 拖拽安装磁盘镜像 |

构建脚本会校验内置的 7-Zip 官方源码包 SHA-256，按官方 `cmpl_mac_arm64.mak` 编译 `7zz`，再编译 SwiftUI 应用并打包签名。纯 CLT 环境自动回退到兼容 SDK（macOS 27 SDK 起 `@State` 依赖仅随完整 Xcode 分发的宏插件）。

正式发布（Developer ID 签名 + 公证）:

```bash
APP_SIGN_IDENTITY="Developer ID Application: YOUR_NAME (TEAM_ID)" \
NOTARY_PROFILE="my-notary-profile" bash scripts/build-macos.sh
```

## 使用

**文件关联（对标 Windows 7-Zip 的「选项 → 系统」）**：菜单栏 `工具 → 文件类型关联…`，勾选即绑定双击打开，取消勾选恢复系统默认。

**Finder 服务**:Finder 中右键归档 → `服务`（或`快速服务`):

- `七压/用七压打开` / `解压到当前目录`（仅归档）
- `七压/压缩所选项目`（任意文件/文件夹，同目录生成 zip)

快捷键可在 `系统设置 → 键盘 → 键盘快捷键 → 服务` 中配置。服务若不显示，注销重登一次即可。

**Finder 右键一级菜单（Finder Sync 扩展）**：首次安装后需在 `系统设置 → 隐私与安全性 → 扩展 → Finder` 中勾选「SevenZip Finder」（macOS 强制手动启用）。右键选中归档：使用七压打开 / 解压到… / 解压到当前目录 / 解压到 "名称/" / 测试压缩包；右键任意文件：添加到压缩包… / 压缩并邮件… / CRC SHA 子菜单（CRC32、CRC64、SHA-1、SHA-256）。

**Quick Look 空格预览**：选中压缩包按空格即可查看内容清单，无需打开应用（首次使用若未生效，运行一次主程序或注销重登）。

**双窗格与快捷键**：`F9` 开关双窗格，`Tab` 切换焦点窗格，`F5`/`F6` 跨窗格复制/移动，`⌘R` 刷新，`⌘↑` 返回上级，`⌘L` 运行日志。

**其他工具**：`工具 → 性能测试（Benchmark）` 跑 `7zz b` 查看压缩/解压评分；`帮助 → 检查更新` 对比 GitHub Releases；`帮助 → 重置所有设置` 恢复默认偏好；`查看 → 显示网格线` 切换列表网格线。

**命令行**:

```bash
SevenZip.app/Contents/MacOS/SevenZipCLI list archive.7z
SevenZip.app/Contents/MacOS/SevenZipCLI extract archive.zip DEST [ENTRY ...]
read -s P; printf '%s\n' "$P" | SevenZipCLI test encrypted.7z --password-stdin
```

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `Sources/ArchiveCore/` | GUI/CLI 共用：命令构造、路径安全检查、列表解析、旧编码文件名恢复 |
| `Sources/SevenZip/` | SwiftUI 文件管理器（双窗格外壳 ContentView + 窗格实现 PaneView）、NSTableView/NSCollectionView 列表、后台任务队列、Finder 服务入口 |
| `Sources/SevenZipCLI/` | 命令行入口 |
| `Extensions/QuickLookPreview/` | Quick Look 空格预览扩展（沙箱，内嵌 7zz 引擎；摘要行 + 树形清单） |
| `Extensions/FinderSync/` | Finder Sync 右键菜单扩展 |
| `Extensions/QuickAction/` | Finder 快速操作扩展（解压/压缩两个 appex，共用控制器） |
| `Resources/` | Info.plist、应用图标、各格式 Finder 文档图标（TypeIcons/)、双语应用名 |
| `scripts/build-macos.sh` | 一键构建：7zz 引擎 + 应用 + 扩展 + 打包 + 签名 |
| `scripts/build-extensions.sh` | 手工 .appex 管线：swiftc 编译（`-parse-as-library` + `_NSExtensionMain` 入口）+ 沙箱签名 |
| `scripts/make-icon.swift` · `make-type-icons.swift` | 程序化生成应用图标与类型图标（iconset → icns) |
| `scripts/check-engine.sh` · `tests/check-advanced-engine.sh` | 引擎端到端测试 |
| `Tests/ArchiveCoreTests/` | XCTest 单元测试（需完整 Xcode) |
| `third_party/7z2605-src.tar.xz` | 7-Zip 26.05 官方源码包（SHA-256 校验） |

## 验证

```bash
bash scripts/check-engine.sh dist/SevenZip.app/Contents/Resources/bin/7zz
bash tests/check-advanced-engine.sh dist/SevenZip.app/Contents/Resources/bin/7zz
swift test -c release --arch arm64        # 需完整 Xcode（含 XCTest)
codesign --verify --deep --verbose=2 dist/SevenZip.app
hdiutil verify dist/SevenZip-macOS-arm64.dmg
```

## 安全说明

- 解压前已对归档内路径做绝对路径与 `..` 穿越检查；符号链接与压缩炸弹仍需专门审计，只解压可信来源的归档
- 密码仅通过子进程匿名 stdin 管道传递
- 默认 ad-hoc 签名仅供本机使用；跨机器分发需 Developer ID 签名与 Apple 公证
- Bundle ID 默认为 `org.sevenzip.app`，正式发行建议替换为自己拥有的 ID

## 许可证

本项目 GUI 代码采用 [LGPL-3.0](LICENSE)。内置的 7-Zip 引擎版权归 **Igor Pavlov** 及相应贡献者，遵循其 LGPL/BSD 条款与 unRAR 限制（许可文本已包含在应用的 `Contents/Resources/licenses/` 中）。本项目不是 7-Zip 官方产品。

## 上游来源

- 7-Zip 官方：<https://www.7-zip.org/>
- 官方源码仓库：<https://github.com/ip7z/7zip>
- 引擎版本：**26.05** · 源码包 SHA-256:`0b6080b8c3e7a579161d2d495224c0e51c467576cb4c7048b0ab485ef44cc22e`
