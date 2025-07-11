# Flutter Engine libflutter.so 复制并压缩脚本

这个脚本通过创建临时 Flutter 工程并打包 APK 的方式来获取 libflutter.so 文件，然后按版本号和平台组织并压缩为 zip 格式。

## 主要特性

- **新的获取方式**: 通过创建 Flutter 工程打包 APK 来获取 libflutter.so，而不是直接从编译输出复制
- **自动依赖检查**: 自动检查并安装必要的工具（Flutter SDK、zip、unzip 等）
- **多平台支持**: 支持 ARM、ARM64、x64 架构的 release 和 profile 模式
- **版本号检测**: 自动从 Git 分支名或标签检测版本号
- **交互式确认**: 提供友好的交互界面确认版本号
- **预览模式**: 支持 dry-run 模式预览操作
- **详细日志**: 提供详细的执行日志和进度显示

## 使用方法

### 基本用法

```bash
# 交互式运行（推荐）
./copy_libflutter.sh

# 使用指定版本号
./copy_libflutter.sh --version 3.29.3

# 自动检测版本号（跳过交互）
./copy_libflutter.sh --auto-version

# 使用日期作为版本号
./copy_libflutter.sh --date-version
```

### 高级选项

```bash
# 预览模式（不实际执行）
./copy_libflutter.sh --dry-run --verbose

# 跳过 x64 架构
./copy_libflutter.sh --skip-x64

# 强制覆盖现有文件
./copy_libflutter.sh --force

# 跳过依赖检查
./copy_libflutter.sh --skip-deps-check

# 指定 Flutter SDK 路径
./copy_libflutter.sh --flutter-sdk-path /path/to/flutter

# 手动安装模式（仅提示，不自动安装）
./copy_libflutter.sh --manual-install
```

## 输出目录结构

脚本会在当前目录下创建以下结构：

```
./[版本号]/
├── android-arm-release/
│   └── libflutter.so.zip
├── android-arm-profile/
│   └── libflutter.so.zip
├── android-arm64-release/
│   └── libflutter.so.zip
├── android-arm64-profile/
│   └── libflutter.so.zip
├── android-x64-release/        (可选)
│   └── libflutter.so.zip
└── android-x64-profile/        (可选)
    └── libflutter.so.zip
```

## 工作原理

1. **依赖检查**: 检查并安装必要的工具（Flutter SDK、zip、unzip 等）
2. **版本检测**: 从 Git 分支名、标签或使用日期自动检测版本号
3. **临时工程**: 创建临时的 Flutter 工程
4. **APK 打包**: 为每个平台配置使用本地引擎打包 APK
5. **文件提取**: 从 APK 中提取 libflutter.so 文件
6. **压缩存储**: 将文件压缩为 zip 格式并按平台组织
7. **清理**: 自动清理临时文件

## 前置条件

- 已编译的 Flutter Engine（在 `../flutter_unified_repo/engine/src/out` 目录下）
- macOS 或 Linux 系统
- 网络连接（用于下载 Flutter SDK，如果未安装）

## 依赖工具

脚本会自动检查并尝试安装以下工具：

- **Flutter SDK**: 用于创建工程和打包 APK
- **zip/unzip**: 用于压缩和解压文件
- **curl/wget**: 用于下载 Flutter SDK（如果需要）

## 版本号检测规则

1. **分支名检测**: 如果当前分支名包含版本号（如 `3.29.3-image_crash`），会提取版本号
2. **Git 标签**: 如果没有分支版本号，会查找最近的版本标签
3. **Git Hash**: 如果都没有，会使用 Git 提交的短 hash
4. **日期**: 如果不在 Git 仓库中，会使用当前日期

## 故障排除

### Flutter SDK 未找到
```bash
# 指定 Flutter SDK 路径
./copy_libflutter.sh --flutter-sdk-path /path/to/flutter

# 或者手动安装模式
./copy_libflutter.sh --manual-install
```

### 编译输出不存在
确保已经运行了 Flutter Engine 的编译脚本，并且在 `../flutter_unified_repo/engine/src/out` 目录下有相应的编译输出。

### 权限问题
```bash
# 确保脚本有执行权限
chmod +x copy_libflutter.sh
```

## 示例输出

```
Flutter Engine libflutter.so 复制并压缩脚本 v2.0.0
==================================================

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
版本号检测结果
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
检测到版本号: 3.29.3
来源: 分支名 (从分支 '3.29.3-image_crash' 中提取)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

打包配置汇总:
  - android-arm-release (arm release)
  - android-arm-profile (arm profile)
  - android-arm64-release (arm64 release)
  - android-arm64-profile (arm64 profile)
  - android-x64-release (x64 release)
  - android-x64-profile (x64 profile)

打包和提取结果汇总:
┌─────────────────────────────┬──────────┬─────────────┬─────────────┐
│ 平台                        │ 状态     │ 原始大小    │ 压缩后大小  │
├─────────────────────────────┼──────────┼─────────────┼─────────────┤
│ android-arm-release         │ ✅ 成功  │ 从APK提取   │ 15M         │
│ android-arm-profile         │ ✅ 成功  │ 从APK提取   │ 18M         │
│ android-arm64-release       │ ✅ 成功  │ 从APK提取   │ 18M         │
│ android-arm64-profile       │ ✅ 成功  │ 从APK提取   │ 22M         │
│ android-x64-release         │ ✅ 成功  │ 从APK提取   │ 20M         │
│ android-x64-profile         │ ✅ 成功  │ 从APK提取   │ 24M         │
└─────────────────────────────┴──────────┴─────────────┴─────────────┘

所有 6 个平台打包并提取成功！
```

## 更新日志

### v2.0.0
- 重构脚本，改为通过 APK 打包方式获取 libflutter.so
- 添加自动依赖检查和安装功能
- 改进版本号检测逻辑
- 添加预览模式和详细日志
- 优化用户交互界面
- 添加错误处理和清理机制
