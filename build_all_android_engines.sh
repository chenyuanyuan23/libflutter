#!/bin/bash

# Flutter Engine Android 平台编译脚本
# 编译所有Android平台版本，输出目录名称与Flutter SDK一致
# 默认启用增量编译以提高编译速度

set -e  # 遇到错误立即退出

# 路径配置
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

# 编译模式选项 - 默认启用增量编译
INCREMENTAL_BUILD=true   # 默认启用增量编译
SKIP_GN_CONFIG=false
FORCE_REBUILD=false
ENABLE_X64=false         # 默认不编译x64架构
ENABLE_STRIP=true        # 默认strip（生成更小的发布版本）
CUSTOM_JOBS=0            # 用户自定义每个ninja的并行数，0表示自动计算
MAX_PARALLEL=6           # 同时运行的ninja进程数，默认2

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --incremental|-i)
                INCREMENTAL_BUILD=true
                log_info "显式启用增量编译模式"
                shift
                ;;
            --no-incremental|--full)
                INCREMENTAL_BUILD=false
                log_info "禁用增量编译，使用完整编译"
                shift
                ;;
            --skip-gn|-s)
                SKIP_GN_CONFIG=true
                log_info "跳过GN配置阶段"
                shift
                ;;
            --force|-f)
                FORCE_REBUILD=true
                log_info "强制完整重新编译"
                shift
                ;;
            --enable-x64)
                ENABLE_X64=true
                log_info "启用x64架构编译"
                shift
                ;;
            --strip)
                ENABLE_STRIP=true
                log_info "显式启用strip"
                shift
                ;;
            --no-strip)
                ENABLE_STRIP=false
                log_info "禁用strip（保留调试符号）"
                shift
                ;;
            --jobs|-j)
                CUSTOM_JOBS="$2"
                log_info "自定义每个ninja并行数: ${CUSTOM_JOBS}"
                shift 2
                ;;
            --parallel|-p)
                MAX_PARALLEL="$2"
                log_info "自定义并行ninja进程数: ${MAX_PARALLEL}"
                shift 2
                ;;
            --help|-h)
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

# 显示帮助信息
show_help() {
    echo "Flutter Engine Android 平台编译脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -i, --incremental    显式启用增量编译模式（默认已启用）"
    echo "      --no-incremental 禁用增量编译，使用完整编译"
    echo "      --full           同 --no-incremental"
    echo "  -s, --skip-gn        跳过GN配置阶段（仅编译）"
    echo "  -f, --force          强制完整重新编译（清理后重新构建）"
    echo "      --enable-x64     启用x64架构编译（默认不编译x64）"
    echo "      --strip          显式启用strip（默认已启用）"
    echo "      --no-strip       保留调试符号（生成unstripped版本）"
    echo "  -j, --jobs N         指定每个ninja的并行编译数（默认: 自动按并行数平分）"
    echo "  -p, --parallel N     指定同时运行的ninja进程数（默认: 2）"
    echo "  -h, --help           显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                   # 增量编译arm/arm64平台（默认模式）"
    echo "  $0 --enable-x64      # 增量编译所有平台（包括x64）"
    echo "  $0 --no-incremental # 完整编译arm/arm64平台"
    echo "  $0 --skip-gn        # 跳过配置，直接编译"
    echo "  $0 --force          # 强制完整重新编译"
    echo "  $0 --no-strip       # 编译保留调试符号（用于调试）"
    echo "  $0 -j 8             # 每个ninja用8线程"
    echo "  $0 -p 1             # 纯串行（内存紧张时使用）"
    echo "  $0 -p 3 -j 4        # 3个ninja并行，每个用4线程"
}

# 检查是否在正确的目录
if [ ! -f "flutter_unified_repo/engine/src/flutter/tools/gn" ] && [ ! -f "flutter/tools/gn" ]; then
    log_error "请确保 flutter_engine_dev 根目录下存在 flutter_unified_repo 或在 engine/src 目录下运行"
    exit 1
fi

# 确定工作目录
if [ -f "flutter_unified_repo/engine/src/flutter/tools/gn" ]; then
    # 在根目录运行，切换到engine/src
    cd flutter_unified_repo/engine/src
    log_info "切换到Flutter统一仓库: flutter_unified_repo/engine/src"
elif [ -f "flutter/tools/gn" ]; then
    # 已经在engine/src目录
    log_info "当前在engine/src目录"
fi

# 获取CPU核心数并计算并行编译数
CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "4")
if [ "$CUSTOM_JOBS" -gt 0 ] 2>/dev/null; then
    JOBS=$CUSTOM_JOBS
else
    # 按并行ninja数平分核心，确保总并发不超过硬件能力
    JOBS=$(( (CORES + 2) / MAX_PARALLEL ))
    # 至少保证每个ninja有2个线程
    [ "$JOBS" -lt 2 ] && JOBS=2
fi
log_info "CPU核心数: ${CORES}，并行ninja数: ${MAX_PARALLEL}，每个ninja -j${JOBS}（总并发: $((JOBS * MAX_PARALLEL))）"

# 查找llvm-strip工具
find_strip_tool() {
    local cpu_arch=$1

    # 确定NDK架构名称
    local ndk_arch
    case "$cpu_arch" in
        "arm")
            ndk_arch="arm-linux-androideabi"
            ;;
        "arm64")
            ndk_arch="aarch64-linux-android"
            ;;
        "x64")
            ndk_arch="x86_64-linux-android"
            ;;
    esac

    # 在flutter/buildtools中查找llvm-strip
    local strip_tool=""

    # 方法1: 使用flutter/buildtools中的llvm-strip (推荐)
    if [ -f "flutter/buildtools/mac-arm64/clang/bin/llvm-strip" ]; then
        strip_tool="flutter/buildtools/mac-arm64/clang/bin/llvm-strip"
    elif [ -f "flutter/buildtools/mac-x64/clang/bin/llvm-strip" ]; then
        strip_tool="flutter/buildtools/mac-x64/clang/bin/llvm-strip"
    elif [ -f "flutter/buildtools/linux-x64/clang/bin/llvm-strip" ]; then
        strip_tool="flutter/buildtools/linux-x64/clang/bin/llvm-strip"
    fi

    # 方法2: 使用NDK中的llvm-strip
    if [ -z "$strip_tool" ] && [ -f "flutter/third_party/android_tools/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip" ]; then
        strip_tool="flutter/third_party/android_tools/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
    fi

    # 方法3: 使用系统llvm-strip
    if [ -z "$strip_tool" ] && command -v llvm-strip &> /dev/null; then
        strip_tool="llvm-strip"
    fi

    echo "$strip_tool"
}

# Strip libflutter.so
strip_libflutter() {
    local build_dir=$1
    local cpu_arch=$2
    local libflutter_path="${build_dir}/libflutter.so"
    local stripped_path="${build_dir}/libflutter_stripped.so"

    if [ ! -f "$libflutter_path" ]; then
        log_warning "libflutter.so不存在，跳过strip: ${libflutter_path}"
        return 1
    fi

    local strip_tool=$(find_strip_tool "$cpu_arch")

    if [ -z "$strip_tool" ]; then
        log_error "找不到llvm-strip工具，无法strip"
        return 1
    fi

    log_info "使用 ${strip_tool} strip ${libflutter_path}"

    # 获取原始大小
    local original_size=$(ls -lh "$libflutter_path" | awk '{print $5}')

    # 执行strip
    if "$strip_tool" -o "$stripped_path" "$libflutter_path"; then
        local stripped_size=$(ls -lh "$stripped_path" | awk '{print $5}')
        log_success "Strip完成: ${original_size} -> ${stripped_size}"

        # 替换原文件
        mv "$stripped_path" "$libflutter_path"
        return 0
    else
        log_error "Strip失败: ${libflutter_path}"
        return 1
    fi
}

# 构建编译配置数组
build_configs() {
    # 基础配置（arm和arm64）- 使用GN生成的原始目录名
    CONFIGS=(
        "android_profile:arm:profile:"
        "android_release:arm:release:"
        "android_profile_arm64:arm64:profile:"
        "android_release_arm64:arm64:release:"
    )
    
    # 根据ENABLE_X64变量决定是否添加x64配置
    if [ "$ENABLE_X64" = "true" ]; then
        CONFIGS+=(
            "android_profile_x64:x64:profile:"
            "android_release_x64:x64:release:"
        )
        log_info "已启用x64架构编译"
    else
        log_info "x64架构编译已禁用（使用 --enable-x64 启用）"
    fi
}

# 获取GN生成的实际目录名
get_generated_dir() {
    local cpu_arch=$1
    local runtime_mode=$2
    
    case "${cpu_arch}_${runtime_mode}" in
        "arm_profile")
            echo "out/android_profile"
            ;;
        "arm_release")
            echo "out/android_release"
            ;;
        "arm64_profile")
            echo "out/android_profile_arm64"
            ;;
        "arm64_release")
            echo "out/android_release_arm64"
            ;;
        "x64_profile")
            echo "out/android_profile_x64"
            ;;
        "x64_release")
            echo "out/android_release_x64"
            ;;
    esac
}

# 检查现有构建是否有效
check_existing_build() {
    local generated_dir=$1
    local output_dir=$2
    
    # 检查构建文件是否存在
    if [ -f "${generated_dir}/build.ninja" ] && [ -f "${generated_dir}/args.gn" ]; then
        # 检查是否有libflutter.so（表示之前编译成功过）
        if [ -f "${generated_dir}/libflutter.so" ]; then
            log_info "发现有效的现有构建: ${generated_dir}"
            return 0
        else
            log_warning "构建配置存在但缺少编译产物: ${generated_dir}"
            return 1
        fi
    else
        log_info "未找到现有构建配置: ${generated_dir}"
        return 1
    fi
}

# 清理构建目录
clean_build_dir() {
    local generated_dir=$1
    local output_dir=$2
    
    if [ -d "$generated_dir" ]; then
        log_info "清理构建目录: ${generated_dir}"
        rm -rf "$generated_dir"
    fi
    
    local target_dir="out/${output_dir}"
    if [ -d "$target_dir" ]; then
        log_info "清理目标目录: ${target_dir}"
        rm -rf "$target_dir"
    fi
}

# 智能配置函数 - 支持增量编译
smart_build_config() {
    local config=$1
    IFS=':' read -r output_dir cpu_arch runtime_mode extra_params <<< "$config"
    
    # 构建目录就是output_dir
    local build_dir="out/${output_dir}"
    
    # 强制重新编译模式
    if [ "$FORCE_REBUILD" = "true" ]; then
        log_info "强制重新编译: ${output_dir}"
        if [ -d "$build_dir" ]; then
            log_info "清理构建目录: ${build_dir}"
            rm -rf "$build_dir"
        fi
    fi
    
    # 跳过GN配置模式
    if [ "$SKIP_GN_CONFIG" = "true" ]; then
        if [ -f "${build_dir}/build.ninja" ]; then
            log_info "跳过GN配置，使用现有构建: ${output_dir}"
            return 0
        else
            log_warning "未找到现有构建配置，将执行GN配置: ${output_dir}"
        fi
    fi
    
    # 增量编译模式检查
    if [ "$INCREMENTAL_BUILD" = "true" ] && check_existing_build "$build_dir" "$output_dir"; then
        log_success "使用现有构建配置（增量模式）: ${output_dir}"
        return 0
    fi
    
    # 执行GN配置
    log_info "开始配置 ${output_dir} (${cpu_arch} ${runtime_mode})"
    
    # 构建GN参数
    local gn_args="--android --android-cpu ${cpu_arch} --runtime-mode ${runtime_mode}"
    if [ "$runtime_mode" = "debug" ]; then
        gn_args="${gn_args} --unopt"
    fi
    
    # 添加额外参数
    if [ -n "$extra_params" ]; then
        gn_args="${gn_args} ${extra_params}"
    fi
    
    # 运行GN配置
    log_info "执行: ./flutter/tools/gn ${gn_args}"
    if ! ./flutter/tools/gn $gn_args; then
        log_error "GN配置失败: ${output_dir}"
        return 1
    fi
    
    log_success "配置完成: ${output_dir}"
    return 0
}

# 编译函数 - 直接在GN生成的目录中编译
compile_config() {
    local config=$1
    IFS=':' read -r output_dir cpu_arch runtime_mode extra_params <<< "$config"
    
    # 获取GN生成的实际目录名（现在output_dir就是目标目录）
    local build_dir="out/${output_dir}"
    
    if [ ! -d "$build_dir" ]; then
        log_error "目录不存在: ${build_dir}"
        return 1
    fi
    
    log_info "开始编译 ${output_dir}"
    log_info "执行: ninja -C ${build_dir} -j${JOBS}"

    if ninja -C "$build_dir" -j"$JOBS"; then
        log_success "编译完成: ${output_dir}"
        
        # 检查libflutter.so是否生成
        if [ -f "${build_dir}/libflutter.so" ]; then
            local size=$(ls -lh "${build_dir}/libflutter.so" | awk '{print $5}')
            log_success "libflutter.so 生成成功 (${size}): ${build_dir}/libflutter.so"
        else
            log_warning "libflutter.so 未找到: ${build_dir}/libflutter.so"
        fi
        
        return 0
    else
        log_error "编译失败: ${output_dir}"
        return 1
    fi
}

# 显示编译模式信息
show_build_mode() {
    echo
    log_info "=== 编译模式配置 ==="
    if [ "$FORCE_REBUILD" = "true" ]; then
        log_warning "模式: 强制完整重新编译"
    elif [ "$SKIP_GN_CONFIG" = "true" ]; then
        log_info "模式: 跳过GN配置，仅编译"
    elif [ "$INCREMENTAL_BUILD" = "true" ]; then
        log_info "模式: 增量编译（默认推荐）⚡"
    else
        log_info "模式: 标准完整编译"
    fi
    if [ "$ENABLE_STRIP" = "true" ]; then
        log_info "Strip: 已启用（默认，生成更小的发布版本）"
    else
        log_info "Strip: 未启用（保留调试符号）"
    fi
    echo
}

# Ctrl+C 时杀掉所有 ninja 进程
cleanup() {
    trap - INT TERM
    echo
    log_warning "收到中断信号，正在停止所有编译任务..."
    killall ninja 2>/dev/null
    kill 0 2>/dev/null
}
trap cleanup INT TERM

# 主函数
main() {
    # 解析命令行参数
    parse_args "$@"
    
    # 构建编译配置数组
    build_configs
    
    log_info "开始Flutter Engine Android平台编译"
    log_info "目标平台: ${#CONFIGS[@]} 个配置"
    
    # 显示编译模式
    show_build_mode
    
    # 显示所有配置
    for config in "${CONFIGS[@]}"; do
        IFS=':' read -r output_dir cpu_arch runtime_mode extra_params <<< "$config"
        log_info "  - ${output_dir} (${cpu_arch} ${runtime_mode})"
    done
    
    echo
    
    # 第一阶段: 配置所有构建
    log_info "=== 第一阶段: 配置所有构建 ==="
    local failed_configs=()
    
    for config in "${CONFIGS[@]}"; do
        IFS=':' read -r output_dir cpu_arch runtime_mode extra_params <<< "$config"
        if ! smart_build_config "$config"; then
            failed_configs+=("$output_dir")
        fi
        echo
    done
    
    # 检查配置失败的项目
    if [ ${#failed_configs[@]} -gt 0 ]; then
        log_error "以下配置失败:"
        for failed in "${failed_configs[@]}"; do
            log_error "  - $failed"
        done
        exit 1
    fi
    
    log_success "所有配置完成"
    echo
    
    # 第二阶段: 并行编译
    log_info "=== 第二阶段: 开始编译 ==="

    local current_jobs=0
    local pids=()
    local job_names=()

    for config in "${CONFIGS[@]}"; do
        IFS=':' read -r output_dir cpu_arch runtime_mode extra_params <<< "$config"

        # 等待空闲槽位
        while [ $current_jobs -ge $MAX_PARALLEL ]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    wait "${pids[$i]}"
                    local exit_code=$?
                    if [ $exit_code -eq 0 ]; then
                        log_success "编译任务完成: ${job_names[$i]}"
                    else
                        log_error "编译任务失败: ${job_names[$i]}"
                    fi
                    unset pids[$i]
                    unset job_names[$i]
                    ((current_jobs--))
                    break
                fi
            done
            sleep 1
        done

        # 启动新的编译任务
        log_info "启动编译任务: $output_dir"
        compile_config "$config" &
        local pid=$!
        pids+=($pid)
        job_names+=("$output_dir")
        ((current_jobs++))
    done

    # 等待所有任务完成（用 sleep 轮询，确保 Ctrl+C 能中断）
    log_info "等待所有编译任务完成..."
    while true; do
        local all_done=true
        for pid in "${pids[@]}"; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                all_done=false
                break
            fi
        done
        $all_done && break
        sleep 1
    done
    # 收集退出码
    for pid in "${pids[@]}"; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done

    # Strip阶段（如果启用）
    if [ "$ENABLE_STRIP" = "true" ]; then
        echo
        log_info "=== Strip阶段: 移除调试符号 ==="
        for config in "${CONFIGS[@]}"; do
            IFS=':' read -r output_dir cpu_arch runtime_mode extra_params <<< "$config"
            local build_dir="out/${output_dir}"
            strip_libflutter "$build_dir" "$cpu_arch"
        done
    fi

    # 第三阶段: 验证结果
    log_info "=== 第三阶段: 验证编译结果 ==="
    local success_count=0
    local total_count=${#CONFIGS[@]}
    
    echo
    log_info "编译结果汇总:"
    echo "┌─────────────────────────────┬──────────┬─────────────┐"
    echo "│ 配置名称                    │ 状态     │ 文件大小    │"
    echo "├─────────────────────────────┼──────────┼─────────────┤"
    
    for config in "${CONFIGS[@]}"; do
        IFS=':' read -r output_dir cpu_arch runtime_mode extra_params <<< "$config"
        local target_dir="out/${output_dir}"
        local libflutter_path="${target_dir}/libflutter.so"
        
        if [ -f "$libflutter_path" ]; then
            local size=$(ls -lh "$libflutter_path" | awk '{print $5}')
            printf "│ %-27s │ %-8s │ %-11s │\n" "$output_dir" "✅ 成功" "$size"
            ((success_count++))
        else
            printf "│ %-27s │ %-8s │ %-11s │\n" "$output_dir" "❌ 失败" "N/A"
        fi
    done
    
    echo "└─────────────────────────────┴──────────┴─────────────┘"
    echo
    
    # 最终结果
    if [ $success_count -eq $total_count ]; then
        log_success "所有 ${total_count} 个Android平台编译成功！"
        echo
        log_info "编译产物位置:"
        for config in "${CONFIGS[@]}"; do
            IFS=':' read -r output_dir cpu_arch runtime_mode extra_params <<< "$config"
            echo "  - out/${output_dir}/libflutter.so"
        done
        echo
        log_info "可以使用以下命令复制到Flutter SDK:"
        echo "  cp out/android_release_arm64/libflutter.so ~/.flutter/cache/artifacts/engine/android-arm64-release/"
        echo "  cp out/android_profile_arm64/libflutter.so ~/.flutter/cache/artifacts/engine/android-arm64-profile/"
        echo "  cp out/android_release/libflutter.so ~/.flutter/cache/artifacts/engine/android-arm-release/"
        echo "  cp out/android_profile/libflutter.so ~/.flutter/cache/artifacts/engine/android-arm-profile/"
        if [ "$ENABLE_X64" = "true" ]; then
            echo "  cp out/android_release_x64/libflutter.so ~/.flutter/cache/artifacts/engine/android-x64-release/"
            echo "  cp out/android_profile_x64/libflutter.so ~/.flutter/cache/artifacts/engine/android-x64-profile/"
        fi
        echo
        log_info "编译模式使用方法:"
        echo "  $0                  # 增量编译arm/arm64（默认模式，推荐）⚡"
        echo "  $0 --enable-x64     # 增量编译所有平台（包括x64）"
        echo "  $0 --no-incremental # 完整重新编译"
        echo "  $0 --skip-gn        # 跳过配置直接编译"
    else
        log_error "编译完成，但有 $((total_count - success_count)) 个平台失败"
        exit 1
    fi
}

# 运行主函数
main "$@"
