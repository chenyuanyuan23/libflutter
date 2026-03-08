# libflutter - Flutter Engine 自定义编译工具集

自动化管理 Flutter Engine 的版本切换、补丁应用、编译和产物提取。

## 快速开始

```bash
# 1. 切换到目标版本（首次运行会自动克隆 depot_tools 和 Flutter SDK 仓库）
./switch_engine_version.sh 3.41.4

# 2. 编译 Android 引擎（arm/arm64 的 profile + release）
./build_all_android_engines.sh

# 3. 复制并压缩 libflutter.so
./copy_libflutter.sh
```

## 目录结构

```
libflutter/
├── switch_engine_version.sh     # 版本切换 + 补丁应用 + gclient sync
├── build_all_android_engines.sh # Android 引擎编译
├── copy_libflutter.sh           # 编译产物复制并压缩
├── patches_backup/              # 补丁文件目录
│   ├── 0001-image_crash_fix.patch
│   ├── 0001-image_crash_fix_v3.38.patch
│   └── 0001-image_crash_fix_v3.41.0+.patch
├── flutter_unified_repo/        # (自动创建) Flutter SDK 仓库 + 引擎源码
├── depot_tools/                 # (自动创建) Google depot_tools
└── [版本号]/                    # (编译后生成) libflutter.so 压缩包
```

## 脚本说明

### switch_engine_version.sh - 版本切换

管理 Flutter Engine 版本，自动应用补丁并同步依赖。

```bash
./switch_engine_version.sh <版本号>              # 切换版本 + 应用补丁 + gclient sync
./switch_engine_version.sh <版本号> --no-sync     # 跳过 gclient sync
./switch_engine_version.sh <版本号> --clean-snapshot  # 清理旧 snapshot 产物
./switch_engine_version.sh --sync-only            # 仅运行 gclient sync
./switch_engine_version.sh --list                 # 列出可用版本
./switch_engine_version.sh --current              # 显示当前版本
```

工作流程:
1. 检查环境（depot_tools、flutter_unified_repo 不存在时自动创建）
2. checkout 到目标版本 tag
3. 创建分支 `<版本>-image_crash`
4. 根据版本自动选择并应用对应补丁
5. 运行 gclient sync 同步引擎依赖（失败自动重试）

### build_all_android_engines.sh - 引擎编译

编译 Android 平台的 Flutter Engine，支持增量编译和并行编译。

```bash
./build_all_android_engines.sh               # 增量编译 arm/arm64（默认）
./build_all_android_engines.sh --enable-x64  # 包含 x64 架构
./build_all_android_engines.sh --no-strip    # 保留调试符号
./build_all_android_engines.sh --force       # 强制完整重新编译
./build_all_android_engines.sh -p 3 -j 4    # 3 个 ninja 并行，每个 4 线程
```

### copy_libflutter.sh - 产物提取

从编译输出目录复制 libflutter.so 并压缩为 zip。

```bash
./copy_libflutter.sh                     # 交互式选择版本号
./copy_libflutter.sh --version 3.41.4    # 指定版本号
./copy_libflutter.sh --auto-version      # 自动检测版本号
./copy_libflutter.sh --include-x64       # 包含 x64 架构
./copy_libflutter.sh --dry-run           # 预览模式
```

输出结构:
```
./3.41.4/
├── android-arm-release/libflutter.so.zip
├── android-arm-profile/libflutter.so.zip
├── android-arm64-release/libflutter.so.zip
└── android-arm64-profile/libflutter.so.zip
```

## 补丁说明

`patches_backup/` 目录下的补丁文件按版本自动选择:

| 版本范围 | 补丁文件 |
|---------|---------|
| >= 3.41.0 | `*v3.41.0+*.patch` |
| < 3.41.0 | `*v3.38*.patch` |
| 未匹配 | 通用补丁（不含 `_v3.` 的文件） |

## 前置条件

- macOS 或 Linux
- Git
- Python 3
- 网络连接（首次运行需要克隆仓库和同步依赖）

depot_tools 和 Flutter SDK 仓库会在首次运行时自动克隆，无需手动安装。
