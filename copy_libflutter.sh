#!/bin/bash

# Flutter Engine libflutter.so 复制并压缩脚本
# 直接从编译输出目录复制 libflutter.so 文件，按版本号和平台组织，并压缩为zip格式
# 使用方法: ./copy_libflutter.sh [选项]

set -e  # 遇到错误立即退出

# 脚本版本
SCRIPT_VERSION="3.0.0"

# 默认配置
DEFAULT_VERSION_MODE="interactive"  # interactive, date, git, manual
INCLUDE_X64=false  # 默认不包含 x64
FORCE_OVERWRITE=true
DRY_RUN=false
VERBOSE=false

# 全局变量
DETECTED_VERSION=""
VERSION_SOURCE=""
VERSION_DETAILS=""
FINAL_VERSION=""
ENGINE_SRC_PATH=""
SCRIPT_DIR=""  # 脚本所在目录

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${CYAN}[VERBOSE]${NC} $1"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
Flutter Engine libflutter.so 复制并压缩脚本 v${SCRIPT_VERSION}

用法: $0 [选项]

说明:
  直接从 engine/src/out/ 目录复制 libflutter.so 文件（无需 Flutter SDK）

选项:
  -v, --version VERSION    手动指定Flutter版本号 (如: 3.38.7)
      --auto-version       自动检测版本号（跳过交互确认）
      --date-version       使用日期作为版本号（格式: YYYY.MM.DD）
      --include-x64        包含x64架构的复制（默认不包含）
      --skip-x64           跳过x64架构的复制（默认行为）
      --force              强制覆盖现有文件（默认启用）
      --no-force           不覆盖现有文件
      --dry-run            预览操作，不实际复制文件
      --verbose            显示详细日志
  -h, --help               显示此帮助信息

示例:
  $0                       # 交互式选择版本号（默认）
  $0 --version 3.38.7      # 使用指定版本号
  $0 --auto-version        # 自动使用检测到的版本号
  $0 --include-x64         # 包含x64架构
  $0 --dry-run --verbose   # 预览模式，显示详细信息

目标目录结构:
  ./[版本号]/android-arm-release/libflutter.so.zip
  ./[版本号]/android-arm-profile/libflutter.so.zip
  ./[版本号]/android-arm64-release/libflutter.so.zip
  ./[版本号]/android-arm64-profile/libflutter.so.zip
  ./[版本号]/android-x64-release/libflutter.so.zip    (--include-x64)
  ./[版本号]/android-x64-profile/libflutter.so.zip    (--include-x64)

EOF
}

# 解析命令行参数
parse_args() {
    VERSION_MODE="$DEFAULT_VERSION_MODE"
    MANUAL_VERSION=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                VERSION_MODE="manual"
                MANUAL_VERSION="$2"
                if [ -z "$MANUAL_VERSION" ]; then
                    log_error "版本号不能为空"
                    exit 1
                fi
                shift 2
                ;;
            --auto-version)
                VERSION_MODE="git"
                shift
                ;;
            --date-version)
                VERSION_MODE="date"
                shift
                ;;
            --include-x64)
                INCLUDE_X64=true
                log_info "将包含x64架构"
                shift
                ;;
            --skip-x64)
                INCLUDE_X64=false
                shift
                ;;
            --force)
                FORCE_OVERWRITE=true
                shift
                ;;
            --no-force)
                FORCE_OVERWRITE=false
                log_info "禁用强制覆盖模式"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                log_info "预览模式：不会实际复制文件"
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 检测版本号信息
detect_version_info() {
    # 重置全局变量
    DETECTED_VERSION=""
    VERSION_SOURCE=""
    VERSION_DETAILS=""

    if [ -d "../flutter_unified_repo/.git" ]; then
        cd ../flutter_unified_repo

        # 1. 首先尝试从分支名提取版本号（如 3.38.7-image_crash）
        local branch_name=$(git branch --show-current 2>/dev/null)
        if [[ "$branch_name" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            DETECTED_VERSION="${BASH_REMATCH[1]}"
            VERSION_SOURCE="分支名"
            VERSION_DETAILS="从分支 '$branch_name' 中提取"
        fi

        # 2. 如果分支名没有版本号，尝试获取最近的版本标签
        if [ -z "$DETECTED_VERSION" ]; then
            local tag_version=$(git describe --tags --abbrev=0 HEAD 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
            if [ -n "$tag_version" ]; then
                DETECTED_VERSION="$tag_version"
                VERSION_SOURCE="Git标签"
                VERSION_DETAILS="最近的版本标签"
            fi
        fi

        # 3. 如果还是没有，使用git hash
        if [ -z "$DETECTED_VERSION" ]; then
            local git_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
            DETECTED_VERSION="git-${git_hash}"
            VERSION_SOURCE="Git Hash"
            VERSION_DETAILS="当前提交的短hash"
        fi

        cd - > /dev/null
    else
        DETECTED_VERSION=$(date +"%Y.%m.%d")
        VERSION_SOURCE="日期"
        VERSION_DETAILS="当前日期"
    fi
}

# 交互式版本号确认
interactive_version_confirm() {
    # 直接调用，设置全局变量
    detect_version_info

    # 所有显示信息输出到 stderr
    echo >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "${CYAN}版本号检测结果${NC}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "检测到版本号: ${GREEN}${DETECTED_VERSION}${NC}" >&2
    echo -e "来源: ${BLUE}${VERSION_SOURCE}${NC} (${VERSION_DETAILS})" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo >&2

    while true; do
        echo -e "是否使用检测到的版本号 ${GREEN}${DETECTED_VERSION}${NC}?" >&2
        echo -e "  ${GREEN}[Y]${NC} 使用检测到的版本号 (默认)" >&2
        echo -e "  ${BLUE}[N]${NC} 自定义输入版本号" >&2
        echo -e "  ${RED}[Q]${NC} 退出脚本" >&2
        echo >&2
        read -p "请输入选择 [y/n/q]: " choice

        case "$(echo "$choice" | tr '[:upper:]' '[:lower:]')" in
            ""|"y"|"yes")
                FINAL_VERSION="$DETECTED_VERSION"
                return 0
                ;;
            "n"|"no"|"custom")
                while true; do
                    echo >&2
                    read -p "请输入自定义版本号 (格式: x.y.z): " custom_version
                    if [[ "$custom_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        FINAL_VERSION="$custom_version"
                        return 0
                    else
                        echo -e "${RED}错误: 版本号格式不正确，请使用 x.y.z 格式 (如: 3.38.7)${NC}" >&2
                    fi
                done
                ;;
            "q"|"quit"|"exit")
                echo >&2
                log_info "用户取消操作" >&2
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请输入 Y、N 或 Q${NC}" >&2
                echo >&2
                ;;
        esac
    done
}

# 获取版本号
get_version() {
    case "$VERSION_MODE" in
        "manual")
            FINAL_VERSION="$MANUAL_VERSION"
            ;;
        "interactive")
            interactive_version_confirm
            ;;
        "git")
            detect_version_info
            FINAL_VERSION="$DETECTED_VERSION"
            ;;
        "date")
            FINAL_VERSION=$(date +"%Y.%m.%d")
            ;;
        *)
            log_error "未知的版本模式: $VERSION_MODE"
            exit 1
            ;;
    esac
}

# 检查源文件是否存在
check_source_files() {
    ENGINE_SRC_PATH="$(realpath ../flutter_unified_repo/engine/src)"
    local out_dir="${ENGINE_SRC_PATH}/out"

    if [ ! -d "$ENGINE_SRC_PATH" ]; then
        log_error "未找到Flutter Engine源码目录: $ENGINE_SRC_PATH"
        log_error "请确保脚本在正确的位置执行"
        exit 1
    fi

    if [ ! -d "$out_dir" ]; then
        log_error "未找到编译输出目录: $out_dir"
        log_error "请先运行编译脚本生成引擎文件"
        exit 1
    fi

    log_verbose "源码目录检查通过: $ENGINE_SRC_PATH"
    log_verbose "输出目录检查通过: $out_dir"
}

# 定义平台配置: 源目录名:目标目录名
get_platform_configs() {
    local configs=(
        "android_release:android-arm-release"
        "android_profile:android-arm-profile"
        "android_release_arm64:android-arm64-release"
        "android_profile_arm64:android-arm64-profile"
    )

    if [ "$INCLUDE_X64" = "true" ]; then
        configs+=(
            "android_release_x64:android-x64-release"
            "android_profile_x64:android-x64-profile"
        )
    fi

    echo "${configs[@]}"
}

# 复制单个平台的 libflutter.so
copy_single_platform() {
    local src_dir="$1"      # 如: android_release
    local dst_dir_name="$2" # 如: android-arm-release
    local version="$3"

    local src_file="${ENGINE_SRC_PATH}/out/${src_dir}/libflutter.so"
    local dst_base="${SCRIPT_DIR}/${version}/${dst_dir_name}"
    local dst_file="${dst_base}/libflutter.so"
    local zip_file="${dst_file}.zip"

    # 检查源文件
    if [ ! -f "$src_file" ]; then
        log_warning "源文件不存在: $src_file"
        return 1
    fi

    # 获取源文件大小
    local src_size=$(ls -lh "$src_file" | awk '{print $5}')

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[预览] $dst_dir_name: $src_file -> $zip_file (${src_size})"
        return 0
    fi

    # 检查目标文件是否已存在
    if [ -f "$zip_file" ] && [ "$FORCE_OVERWRITE" = "false" ]; then
        log_warning "目标文件已存在，跳过: $zip_file"
        return 1
    fi

    # 创建目标目录
    mkdir -p "$dst_base"

    # 复制文件
    if cp "$src_file" "$dst_file"; then
        # 压缩文件
        if zip -j -q "$zip_file" "$dst_file"; then
            local zip_size=$(ls -lh "$zip_file" | awk '{print $5}')
            log_success "$dst_dir_name: 复制并压缩成功 (原始: ${src_size}, 压缩后: ${zip_size})"
            # 删除未压缩的文件
            rm -f "$dst_file"
            return 0
        else
            log_error "$dst_dir_name: 压缩失败"
            rm -f "$dst_file"
            return 1
        fi
    else
        log_error "$dst_dir_name: 复制失败"
        return 1
    fi
}

# 主复制函数
copy_libflutter_files() {
    local version="$1"
    local target_base_dir="${SCRIPT_DIR}/${version}"

    log_info "开始从编译输出目录复制 libflutter.so 文件到版本目录: $version"
    log_info "源目录: ${ENGINE_SRC_PATH}/out/"

    local configs=($(get_platform_configs))
    local success_count=0
    local total_count=${#configs[@]}
    local failed_platforms=()
    local skipped_platforms=()

    echo
    log_info "平台配置汇总 (共 ${total_count} 个):"
    for config in "${configs[@]}"; do
        IFS=':' read -r src_dir dst_dir <<< "$config"
        local src_file="${ENGINE_SRC_PATH}/out/${src_dir}/libflutter.so"
        if [ -f "$src_file" ]; then
            local size=$(ls -lh "$src_file" | awk '{print $5}')
            log_info "  ✓ ${dst_dir} (${size})"
        else
            log_warning "  ✗ ${dst_dir} (源文件不存在)"
        fi
    done
    echo

    # 复制每个平台
    for config in "${configs[@]}"; do
        IFS=':' read -r src_dir dst_dir <<< "$config"

        if copy_single_platform "$src_dir" "$dst_dir" "$version"; then
            ((success_count++))
        else
            local src_file="${ENGINE_SRC_PATH}/out/${src_dir}/libflutter.so"
            if [ ! -f "$src_file" ]; then
                skipped_platforms+=("$dst_dir")
            else
                failed_platforms+=("$dst_dir")
            fi
        fi
    done

    # 显示结果汇总
    echo
    log_info "复制结果汇总:"
    echo "┌─────────────────────────────┬──────────┬─────────────┬─────────────┐"
    echo "│ 平台                        │ 状态     │ 原始大小    │ 压缩后大小  │"
    echo "├─────────────────────────────┼──────────┼─────────────┼─────────────┤"

    for config in "${configs[@]}"; do
        IFS=':' read -r src_dir dst_dir <<< "$config"
        local zip_file="${SCRIPT_DIR}/${version}/${dst_dir}/libflutter.so.zip"
        local src_file="${ENGINE_SRC_PATH}/out/${src_dir}/libflutter.so"

        if [[ " ${skipped_platforms[@]} " =~ " ${dst_dir} " ]]; then
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$dst_dir" "⏭ 跳过" "不存在" "N/A"
        elif [[ " ${failed_platforms[@]} " =~ " ${dst_dir} " ]]; then
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$dst_dir" "❌ 失败" "N/A" "N/A"
        elif [ "$DRY_RUN" = "true" ]; then
            local src_size=$(ls -lh "$src_file" 2>/dev/null | awk '{print $5}' || echo "N/A")
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$dst_dir" "🔍 预览" "$src_size" "预估"
        elif [ -f "$zip_file" ]; then
            local src_size=$(ls -lh "$src_file" 2>/dev/null | awk '{print $5}' || echo "N/A")
            local zip_size=$(ls -lh "$zip_file" | awk '{print $5}')
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$dst_dir" "✅ 成功" "$src_size" "$zip_size"
        else
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$dst_dir" "❌ 失败" "N/A" "N/A"
        fi
    done

    echo "└─────────────────────────────┴──────────┴─────────────┴─────────────┘"
    echo

    # 最终结果
    local actual_total=$((total_count - ${#skipped_platforms[@]}))

    if [ "$DRY_RUN" = "true" ]; then
        log_info "预览完成！共 ${total_count} 个平台配置"
        log_info "使用 --dry-run 以外的参数执行实际复制"
    elif [ ${#skipped_platforms[@]} -gt 0 ]; then
        log_warning "跳过的平台 (源文件不存在): ${skipped_platforms[*]}"
        log_info "请先运行 build_all_android_engines.sh 编译这些平台"
    fi

    if [ "$DRY_RUN" = "false" ]; then
        if [ $success_count -eq $actual_total ] && [ $actual_total -gt 0 ]; then
            log_success "所有 ${success_count} 个平台复制成功！"
            echo
            log_info "文件已复制并压缩到目录: ${target_base_dir}/"
            log_info "目录结构:"
            if command -v tree >/dev/null 2>&1; then
                tree "$target_base_dir" 2>/dev/null || find "$target_base_dir" -type f -name "*.so.zip" | sort
            else
                find "$target_base_dir" -type f -name "*.so.zip" | sort
            fi
        elif [ $success_count -gt 0 ]; then
            log_warning "部分平台复制成功: ${success_count}/${actual_total}"
            if [ ${#failed_platforms[@]} -gt 0 ]; then
                log_error "失败的平台: ${failed_platforms[*]}"
            fi
        else
            log_error "没有平台复制成功"
            exit 1
        fi
    fi
}

# 主函数
main() {
    echo "Flutter Engine libflutter.so 复制并压缩脚本 v${SCRIPT_VERSION}"
    echo "=================================================="
    echo "(直接从编译输出目录复制，无需 Flutter SDK)"
    echo

    # 设置脚本所在目录（libflutter目录）
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    log_verbose "脚本目录: $SCRIPT_DIR"

    # 解析参数
    parse_args "$@"

    # 检查当前目录
    if [ ! -f "README.md" ] || [ "$(basename $(pwd))" != "libflutter" ]; then
        log_error "请在libflutter目录下运行此脚本"
        log_error "当前目录: $(pwd)"
        exit 1
    fi

    # 检查源文件
    check_source_files

    # 获取版本号
    get_version
    log_info "使用版本号: $FINAL_VERSION"

    # 显示配置信息
    echo
    log_info "配置信息:"
    log_info "  版本号: $FINAL_VERSION"
    log_info "  包含x64: $INCLUDE_X64"
    log_info "  强制覆盖: $FORCE_OVERWRITE"
    log_info "  预览模式: $DRY_RUN"
    log_info "  详细日志: $VERBOSE"
    log_info "  源目录: ${ENGINE_SRC_PATH}/out/"
    echo

    # 执行主要流程
    copy_libflutter_files "$FINAL_VERSION"

    echo
    log_success "脚本执行完成！"
}

# 运行主函数
main "$@"
