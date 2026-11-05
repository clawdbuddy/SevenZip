# P0 / P1 / P2 实施状态与验收清单

日期：2026-11-05；基线：7-Zip 26.05，SwiftUI，Apple Silicon ARM64。

**实施状态分级**：代码已实现 ≠ Mac 已构建通过 ≠ 通过安全与产品验收。当前开发环境为 Linux x86_64，不能编译 SwiftUI 或生成真实 DMG。

## P0 — 基础可用性

| 功能 | 代码状态 | 验收待办 |
| --- | --- | --- |
| 双栏目录与列表、路径搜索 | 已实现 | macOS GUI 文件树/表格交互测试 |
| 全部/选择性解压 | 已实现 | 中文、符号链接、超长路径、分卷测试 |
| 通过 stdin 输入压缩/解压密码 | 已实现 | macOS 终端外 `Process` 密码交互测试 |
| 运行进度与取消 | 已实现 | 并行刷新、进程取消后归档状态测试 |
| 文件拖入、Finder 文件关联 | 已实现基本接口 | Finder 双击与 `.onOpenURL` 实机验证 |
| 路径拒绝、已有文件冲突策略 | 已实现基础检查 | 恶意符号链接、归档炸弹、TOCTOU 安全审计 |

## P1 — 专业归档管理

| 功能 | 代码状态 | 验收待办 |
| --- | --- | --- |
| Quick Look 内容预览 | 已实现临时解压+预览 | 图片/PDF/文本、关闭窗口后清理、恶意链接测试 |
| 7z/ZIP 添加、删除、重命名 | 已实现 | 断电/磁盘满/取消、加密归档与冲突测试 |
| 7z/ZIP AES 加密与隐藏 7z 文件名 | 已实现 | Mac GUI 交互及密码错误回归 |
| 分卷、压缩级别、线程数、过滤系统元数据 | 已实现 | Mac 大文件、多分卷、恢复性测试 |
| 批量压缩与批量解压队列 | 已实现基础队列 | 失败继续策略与持久化队列尚需完善 |
| 压缩格式转换 | 已实现临时提取/拒绝符号链接/再压缩 | 大文件、磁盘满、失败恢复及原子提交尚需验收 |

## P2 — 开发者与正式发行

| 功能 | 状态 | 验收待办 |
| --- | --- | --- |
| 双栏文件管理 | 左侧本机目录/归档目录切换 + 右侧归档表格已实现 | 本机端拖拽、双向同步与快捷键待完善 |
| CLI / GUI 复用命令引擎 | 已实现共享 ArchiveCore | Mac ARM64 CLI 运行测试 |
| SHA-256、批量任务 | 已实现 | 归档摘要格式、历史持久化待完善 |
| Mac 性能测试 | 已提供可重复执行脚本 | M 系列真实速度/内存/温升数据待测 |
| `.app` / ZIP / DMG 输出 | 已实现脚本 | macOS 生成/启动/安装验收 |
| Developer ID 签名、notarytool、公证 | 已实现可选脚本 | 需用户自己的证书/钥匙串配置及苹果验收 |
| Finder Sync 右键扩展 | 已提供源代码模板，未打包 | 需独立 Xcode `.appex` target、App Group、目录监控及权限设计 |
| App Store 沙箱发行 | 尚未实现 | 当前非 App Store 工程，需 Sandbox entitlements 与审核 |
| 可复现归档、崩溃恢复 | 尚未实现 | 需时间戳规范、事务日志与故障注入 |

## 已在 Linux 的同版官方 7zz 上通过的测试

- `scripts/check-engine.sh`：7z/ZIP 创建、列表、校验、解压及内容比较。
- `tests/check-advanced-engine.sh`：选择性解压、7z/ZIP 密码创建和校验、分卷、改名、删除。
- `bash -n`：脚本语法检查。
- Swift XCTest 已编写，但需在 Mac 上执行 `swift test -c release --arch arm64`。

## Mac 验收命令

```bash
bash scripts/build-macos.sh
bash scripts/check-engine.sh dist/SevenZipMac.app/Contents/Resources/bin/7zz
bash tests/check-advanced-engine.sh dist/SevenZipMac.app/Contents/Resources/bin/7zz
dist/SevenZipMac.app/Contents/MacOS/SevenZipMacCLI list /path/to/test.7z
bash scripts/benchmark-macos.sh /path/to/your-test-data
hdiutil verify dist/SevenZipMac-macOS-arm64.dmg
```

**安全边界**：目前未完成安全沙箱、符号链接穿透与归档炸弹限制。对来源不可信的压缩包，只允许在隔离环境测试，不能宣称安全验收通过。
