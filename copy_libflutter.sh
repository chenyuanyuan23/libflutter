#!/bin/bash

# Flutter Engine libflutter.so 复制并压缩脚本
# 通过创建Flutter工程打包APK的方式获取libflutter.so文件，按版本号和平台组织，并压缩为zip格式
# 使用方法: ./copy_libflutter.sh [选项]

set -e  # 遇到错误立即退出

# 脚本版本
SCRIPT_VERSION="2.0.0"

# 默认配置
DEFAULT_VERSION_MODE="interactive"  # interactive, date, git, manual
INCLUDE_X64=true
FORCE_OVERWRITE=true
DRY_RUN=false
VERBOSE=false
SKIP_DEPS_CHECK=false
MANUAL_INSTALL=false
FLUTTER_SDK_PATH=""

# 全局变量
DETECTED_VERSION=""
VERSION_SOURCE=""
VERSION_DETAILS=""
FINAL_VERSION=""
TEMP_PROJECT_DIR=""
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

选项:
  -v, --version VERSION    手动指定Flutter版本号 (如: 3.29.3)
      --auto-version       自动检测版本号（跳过交互确认）
      --date-version       使用日期作为版本号（格式: YYYY.MM.DD）
      --skip-x64           跳过x64架构的复制
      --force              强制覆盖现有文件
      --dry-run            预览操作，不实际复制文件
      --verbose            显示详细日志
      --skip-deps-check    跳过依赖检查
      --manual-install     手动安装模式（仅提示，不自动安装）
      --flutter-sdk-path   指定Flutter SDK路径
  -h, --help               显示此帮助信息

示例:
  $0                       # 交互式选择版本号（默认）
  $0 --version 3.29.3      # 使用指定版本号
  $0 --auto-version        # 自动使用检测到的版本号
  $0 --date-version        # 使用日期版本号
  $0 --skip-x64 --force    # 跳过x64，强制覆盖
  $0 --dry-run --verbose   # 预览模式，显示详细信息

目标目录结构:
  ./[版本号]/android-arm-release/libflutter.so.zip
  ./[版本号]/android-arm-profile/libflutter.so.zip
  ./[版本号]/android-arm64-release/libflutter.so.zip
  ./[版本号]/android-arm64-profile/libflutter.so.zip
  ./[版本号]/android-x64-release/libflutter.so.zip    (可选)
  ./[版本号]/android-x64-profile/libflutter.so.zip    (可选)

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
            --skip-x64)
                INCLUDE_X64=false
                log_info "将跳过x64架构"
                shift
                ;;
            --force)
                FORCE_OVERWRITE=true
                log_info "启用强制覆盖模式"
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
            --skip-deps-check)
                SKIP_DEPS_CHECK=true
                log_info "跳过依赖检查"
                shift
                ;;
            --manual-install)
                MANUAL_INSTALL=true
                log_info "手动安装模式"
                shift
                ;;
            --flutter-sdk-path)
                FLUTTER_SDK_PATH="$2"
                if [ -z "$FLUTTER_SDK_PATH" ]; then
                    log_error "Flutter SDK路径不能为空"
                    exit 1
                fi
                shift 2
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

# 检查并安装依赖
check_and_install_dependencies() {
    if [ "$SKIP_DEPS_CHECK" = "true" ]; then
        log_info "跳过依赖检查"
        return 0
    fi
    
    log_info "检查必要的依赖工具..."
    
    # 检查基础工具
    local missing_tools=()
    
    # 检查 unzip
    if ! command -v unzip &> /dev/null; then
        missing_tools+=("unzip")
    fi
    
    # 检查 zip
    if ! command -v zip &> /dev/null; then
        missing_tools+=("zip")
    fi
    
    # 检查 curl 或 wget
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        missing_tools+=("curl")
    fi
    
    # 安装缺失的基础工具
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_warning "检测到缺少以下工具: ${missing_tools[*]}"
        
        if [ "$MANUAL_INSTALL" = "true" ]; then
            log_error "请手动安装缺失的工具: ${missing_tools[*]}"
            exit 1
        fi
        
        # 尝试自动安装
        install_basic_tools "${missing_tools[@]}"
    fi
    
    # 检查 Flutter SDK
    check_flutter_sdk
    
    log_success "依赖检查完成"
}

# 安装基础工具
install_basic_tools() {
    local tools=("$@")
    
    log_info "尝试自动安装工具: ${tools[*]}"
    
    # 检测系统类型
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            log_info "使用 Homebrew 安装工具..."
            for tool in "${tools[@]}"; do
                case "$tool" in
                    "unzip"|"zip")
                        # 这些通常已经预装在 macOS 上
                        log_warning "$tool 应该已经预装，请检查系统"
                        ;;
                    "curl")
                        # curl 通常已经预装在 macOS 上
                        log_warning "curl 应该已经预装，请检查系统"
                        ;;
                esac
            done
        else
            log_error "未找到 Homebrew，请手动安装缺失的工具"
            exit 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            log_info "使用 apt-get 安装工具..."
            sudo apt-get update
            for tool in "${tools[@]}"; do
                sudo apt-get install -y "$tool"
            done
        elif command -v yum &> /dev/null; then
            log_info "使用 yum 安装工具..."
            for tool in "${tools[@]}"; do
                sudo yum install -y "$tool"
            done
        else
            log_error "未找到支持的包管理器，请手动安装缺失的工具"
            exit 1
        fi
    else
        log_error "不支持的操作系统，请手动安装缺失的工具"
        exit 1
    fi
}

# 检查 Flutter SDK
check_flutter_sdk() {
    local flutter_cmd="flutter"
    
    # 如果指定了 Flutter SDK 路径
    if [ -n "$FLUTTER_SDK_PATH" ]; then
        if [ -f "$FLUTTER_SDK_PATH/bin/flutter" ]; then
            flutter_cmd="$FLUTTER_SDK_PATH/bin/flutter"
            export PATH="$FLUTTER_SDK_PATH/bin:$PATH"
            log_info "使用指定的 Flutter SDK: $FLUTTER_SDK_PATH"
        else
            log_error "指定的 Flutter SDK 路径无效: $FLUTTER_SDK_PATH"
            exit 1
        fi
    fi
    
    # 检查 Flutter 是否可用
    if ! command -v "$flutter_cmd" &> /dev/null; then
        log_warning "未找到 Flutter SDK"
        
        if [ "$MANUAL_INSTALL" = "true" ]; then
            log_error "请手动安装 Flutter SDK"
            log_error "下载地址: https://flutter.dev/docs/get-started/install"
            exit 1
        fi
        
        # 尝试自动安装 Flutter
        install_flutter_sdk
    else
        log_info "Flutter SDK 检查通过"
        log_verbose "Flutter 版本: $($flutter_cmd --version | head -1)"
    fi
    
    # 运行基本的 Flutter 版本检查
    log_info "运行 Flutter 环境检查..."
    if ! $flutter_cmd --version > /dev/null 2>&1; then
        log_error "Flutter 基本检查失败，请检查 Flutter 安装"
        exit 1
    fi
    
    # 只在详细模式下运行完整的 doctor 检查
    if [ "$VERBOSE" = "true" ]; then
        log_info "运行详细的 Flutter doctor 检查..."
        # 使用超时和错误处理避免 Broken pipe 问题
        timeout 30 $flutter_cmd doctor 2>/dev/null || log_warning "Flutter doctor 检查超时或出现问题，但基本功能正常"
    fi
}

# 安装 Flutter SDK
install_flutter_sdk() {
    log_info "开始安装 Flutter SDK..."
    
    # 确定下载 URL
    local flutter_url=""
    local flutter_file=""
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if [[ $(uname -m) == "arm64" ]]; then
            flutter_url="https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_stable.zip"
            flutter_file="flutter_macos_arm64_stable.zip"
        else
            flutter_url="https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_stable.zip"
            flutter_file="flutter_macos_stable.zip"
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        flutter_url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_stable.tar.xz"
        flutter_file="flutter_linux_stable.tar.xz"
    else
        log_error "不支持的操作系统，请手动安装 Flutter SDK"
        exit 1
    fi
    
    # 创建安装目录
    local install_dir="$HOME/flutter"
    if [ -d "$install_dir" ]; then
        log_warning "Flutter 目录已存在: $install_dir"
        read -p "是否删除并重新安装? [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            rm -rf "$install_dir"
        else
            log_error "安装取消"
            exit 1
        fi
    fi
    
    # 下载 Flutter
    log_info "下载 Flutter SDK..."
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    if command -v curl &> /dev/null; then
        curl -L -o "$flutter_file" "$flutter_url"
    elif command -v wget &> /dev/null; then
        wget -O "$flutter_file" "$flutter_url"
    else
        log_error "需要 curl 或 wget 来下载 Flutter SDK"
        exit 1
    fi
    
    # 解压 Flutter
    log_info "解压 Flutter SDK..."
    if [[ "$flutter_file" == *.zip ]]; then
        unzip -q "$flutter_file"
        mv flutter "$install_dir"
    elif [[ "$flutter_file" == *.tar.xz ]]; then
        tar -xf "$flutter_file"
        mv flutter "$install_dir"
    fi
    
    # 清理临时文件
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    # 添加到 PATH
    export PATH="$install_dir/bin:$PATH"
    
    # 提示用户添加到 shell 配置
    log_success "Flutter SDK 安装完成: $install_dir"
    log_info "请将以下行添加到您的 shell 配置文件 (~/.bashrc, ~/.zshrc 等):"
    log_info "export PATH=\"$install_dir/bin:\$PATH\""
    
    # 运行 flutter doctor
    log_info "运行初始化检查..."
    flutter doctor
}

# 检测版本号信息
detect_version_info() {
    # 重置全局变量
    DETECTED_VERSION=""
    VERSION_SOURCE=""
    VERSION_DETAILS=""
    
    if [ -d "../flutter_unified_repo/.git" ]; then
        cd ../flutter_unified_repo
        
        # 1. 首先尝试从分支名提取版本号（如 3.29.3-image_crash）
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
                        echo -e "${RED}错误: 版本号格式不正确，请使用 x.y.z 格式 (如: 3.29.3)${NC}" >&2
                    fi
                done
                ;;
            "q"|"quit"|"exit")
                echo >&2
                log_info "用户取消操作" >&2  # 输出到 stderr
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
            # FINAL_VERSION 已在 interactive_version_confirm 中设置
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

# 定义平台配置
get_platform_configs() {
    local configs=(
        "android_release:android-arm-release:arm:release:armeabi-v7a"
        "android_profile:android-arm-profile:arm:profile:armeabi-v7a"
        "android_release_arm64:android-arm64-release:arm64:release:arm64-v8a"
        "android_profile_arm64:android-arm64-profile:arm64:profile:arm64-v8a"
    )
    
    if [ "$INCLUDE_X64" = "true" ]; then
        configs+=(
            "android_release_x64:android-x64-release:x64:release:x86_64"
            "android_profile_x64:android-x64-profile:x64:profile:x86_64"
        )
    fi
    
    echo "${configs[@]}"
}

# 创建临时 Flutter 工程
create_temp_flutter_project() {
    log_info "创建临时 Flutter 工程..."
    
    # 在 SCRIPT_DIR/_temp/ 下创建临时目录
    local temp_base_dir="${SCRIPT_DIR}/_temp"
    mkdir -p "$temp_base_dir"
    
    TEMP_PROJECT_DIR="$temp_base_dir/flutter_project_$(date +%s)"
    log_verbose "临时工程目录: $TEMP_PROJECT_DIR"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[预览] 将在 $TEMP_PROJECT_DIR 创建临时 Flutter 工程"
        return 0
    fi
    
    mkdir -p "$TEMP_PROJECT_DIR"
    cd "$TEMP_PROJECT_DIR"
    
    # 创建最小化的 Flutter 工程
    if ! flutter create temp_flutter_app --template=app --platforms=android; then
        log_error "Flutter 工程创建失败"
        rm -rf "$TEMP_PROJECT_DIR"
        exit 1
    fi
    
    # 检查目录是否创建成功
    if [ ! -d "temp_flutter_app" ]; then
        log_error "Flutter 工程目录创建失败: temp_flutter_app"
        rm -rf "$TEMP_PROJECT_DIR"
        exit 1
    fi
    
    # 不要在这里切换到 temp_flutter_app 目录，让后续函数自己处理
    # cd temp_flutter_app
    
    log_success "临时 Flutter 工程创建完成"
    
    # 返回到 libflutter 目录
    cd - > /dev/null
}

# 配置本地引擎
configure_local_engine() {
    local build_config="$1"  # 如: android_release
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[预览] 配置本地引擎: $build_config"
        return 0
    fi
    
    log_verbose "配置本地引擎: $build_config"
    
    # 确保在工程目录中
    cd "$TEMP_PROJECT_DIR/temp_flutter_app"
}

# 为特定平台打包 APK
build_apk_for_platform() {
    local build_config="$1"    # 如: android_release
    local platform_dir="$2"    # 如: android-arm-release
    local arch="$3"             # 如: arm
    local mode="$4"             # 如: release
    local target_abi="$5"       # 如: armeabi-v7a
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[预览] 打包 APK: $platform_dir ($arch $mode)"
        return 0
    fi
    
    log_info "打包 APK: $platform_dir ($arch $mode)"
    
    # 确保在工程目录中
    cd "$TEMP_PROJECT_DIR/temp_flutter_app"
    
    # 构建 APK 命令
    local flutter_cmd="flutter"
    local build_args=()
    
    # 添加本地引擎参数
    build_args+=("build" "apk")
    build_args+=("--local-engine=$build_config")
    build_args+=("--local-engine-src-path=$ENGINE_SRC_PATH")
    build_args+=("--local-engine-host" "host_release")
    
    # 添加目标平台
    case "$arch" in
        "arm")
            build_args+=("--target-platform=android-arm")
            ;;
        "arm64")
            build_args+=("--target-platform=android-arm64")
            ;;
        "x64")
            build_args+=("--target-platform=android-x64")
            ;;
    esac
    
    # 添加构建模式
    if [ "$mode" = "profile" ]; then
        build_args+=("--profile")
    fi
    
    # 执行构建
    log_verbose "执行命令: $flutter_cmd ${build_args[*]}"
    
    if $flutter_cmd "${build_args[@]}"; then
        log_success "APK 打包成功: $platform_dir"
        return 0
    else
        log_error "APK 打包失败: $platform_dir"
        return 1
    fi
}

# 从 APK 提取 libflutter.so
extract_libflutter_from_apk() {
    local platform_dir="$1"    # 如: android-arm-release
    local target_abi="$2"       # 如: armeabi-v7a
    local version="$3"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[预览] 从 APK 提取 libflutter.so: $platform_dir"
        return 0
    fi
    
    log_verbose "从 APK 提取 libflutter.so: $platform_dir"
    
    # APK 文件路径
    local apk_file="$TEMP_PROJECT_DIR/temp_flutter_app/build/app/outputs/flutter-apk/app-release.apk"
    if [ ! -f "$apk_file" ]; then
        apk_file="$TEMP_PROJECT_DIR/temp_flutter_app/build/app/outputs/apk/release/app-release.apk"
    fi
    
    if [ ! -f "$apk_file" ]; then
        log_error "未找到 APK 文件"
        return 1
    fi
    
    # 使用脚本目录作为基准目录
    local libflutter_dir="$SCRIPT_DIR"
    
    # 在 _temp 目录下创建临时提取目录
    local extract_dir="${libflutter_dir}/_temp/extract_$(date +%s)_$$"
    mkdir -p "$extract_dir"
    cd "$extract_dir"
    
    # 提取 APK 内容
    if ! unzip -q "$apk_file"; then
        log_error "解压 APK 失败"
        rm -rf "$extract_dir"
        return 1
    fi
    
    # 查找 libflutter.so 文件
    local libflutter_path="lib/$target_abi/libflutter.so"
    if [ ! -f "$libflutter_path" ]; then
        log_error "在 APK 中未找到 libflutter.so: $libflutter_path"
        rm -rf "$extract_dir"
        return 1
    fi
    
    # 获取文件大小
    local src_size=$(ls -lh "$libflutter_path" | awk '{print $5}')
    
    # 目标目录和文件
    local target_base_dir="${libflutter_dir}/${version}"
    local dst_dir="${target_base_dir}/${platform_dir}"
    local dst_file="${dst_dir}/libflutter.so"
    local zip_file="${dst_file}.zip"
    
    # 检查目标文件是否已存在
    if [ -f "$zip_file" ] && [ "$FORCE_OVERWRITE" = "false" ]; then
        log_warning "目标zip文件已存在，跳过: $zip_file"
        rm -rf "$extract_dir"
        return 1
    fi
    
    # 创建目标目录
    mkdir -p "$dst_dir"
    
    # 复制并压缩文件
    if cp "$libflutter_path" "$dst_file"; then
        if zip -j "$zip_file" "$dst_file"; then
            # 获取压缩后的文件大小
            local zip_size=$(ls -lh "$zip_file" | awk '{print $5}')
            log_success "$platform_dir: 提取并压缩成功 (原始: ${src_size}, 压缩后: ${zip_size})"
            
            # 删除未压缩的文件
            rm -f "$dst_file"
            
            # 清理临时目录
            rm -rf "$extract_dir"
            return 0
        else
            log_error "$platform_dir: 压缩失败"
            rm -rf "$extract_dir"
            return 1
        fi
    else
        log_error "$platform_dir: 复制文件失败"
        rm -rf "$extract_dir"
        return 1
    fi
}

# 清理临时工程
cleanup_temp_project() {
    if [ -n "$TEMP_PROJECT_DIR" ] && [ -d "$TEMP_PROJECT_DIR" ]; then
        log_verbose "清理临时工程: $TEMP_PROJECT_DIR"
        if [ "$DRY_RUN" = "false" ]; then
            rm -rf "$TEMP_PROJECT_DIR"
        fi
    fi
}

# 清理所有临时目录
cleanup_all_temp() {
    if [ -n "$SCRIPT_DIR" ] && [ -d "${SCRIPT_DIR}/_temp" ]; then
        log_info "清理临时目录: ${SCRIPT_DIR}/_temp"
        if [ "$DRY_RUN" = "false" ]; then
            rm -rf "${SCRIPT_DIR}/_temp"
        fi
    fi
}

# 主复制函数
copy_libflutter_files() {
    local version="$1"
    local target_base_dir="./${version}"
    
    log_info "开始通过 APK 打包方式获取 libflutter.so 文件到版本目录: $version"
    
    if [ "$DRY_RUN" = "false" ]; then
        mkdir -p "$target_base_dir"
    fi
    
    local configs=($(get_platform_configs))
    local success_count=0
    local total_count=${#configs[@]}
    local failed_platforms=()
    
    echo
    log_info "打包配置汇总:"
    for config in "${configs[@]}"; do
        IFS=':' read -r build_dir platform_dir arch mode target_abi <<< "$config"
        log_info "  - ${platform_dir} (${arch} ${mode})"
    done
    echo
    
    # 创建临时 Flutter 工程
    create_temp_flutter_project
    
    # 为每个平台配置打包 APK 并提取 libflutter.so
    for config in "${configs[@]}"; do
        IFS=':' read -r build_config platform_dir arch mode target_abi <<< "$config"
        
        log_info "处理平台: $platform_dir"
        
        # 配置本地引擎
        configure_local_engine "$build_config"
        
        # 打包 APK
        if build_apk_for_platform "$build_config" "$platform_dir" "$arch" "$mode" "$target_abi"; then
            # 从 APK 提取 libflutter.so
            if extract_libflutter_from_apk "$platform_dir" "$target_abi" "$version"; then
                ((success_count++))
            else
                failed_platforms+=("$platform_dir")
            fi
        else
            failed_platforms+=("$platform_dir")
        fi
    done
    
    # 清理临时工程
    cleanup_temp_project
    
    # 显示结果汇总
    echo
    log_info "打包和提取结果汇总:"
    echo "┌─────────────────────────────┬──────────┬─────────────┬─────────────┐"
    echo "│ 平台                        │ 状态     │ 原始大小    │ 压缩后大小  │"
    echo "├─────────────────────────────┼──────────┼─────────────┼─────────────┤"
    
    # 使用脚本目录检查文件
    for config in "${configs[@]}"; do
        IFS=':' read -r build_config platform_dir arch mode target_abi <<< "$config"
        local zip_file="${SCRIPT_DIR}/${version}/${platform_dir}/libflutter.so.zip"
        if [[ " ${failed_platforms[@]} " =~ " ${platform_dir} " ]]; then
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$platform_dir" "❌ 失败" "N/A" "N/A"
        elif [ "$DRY_RUN" = "true" ]; then
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$platform_dir" "🔍 预览" "预估大小" "预估减小"
        elif [ -f "$zip_file" ]; then
            local zip_size=$(ls -lh "$zip_file" | awk '{print $5}')
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$platform_dir" "✅ 成功" "从APK提取" "$zip_size"
        else
            printf "│ %-27s │ %-8s │ %-11s │ %-11s │\n" "$platform_dir" "❌ 失败" "N/A" "N/A"
        fi
    done
    
    echo "└─────────────────────────────┴──────────┴─────────────┴─────────────┘"
    echo
    
    # 最终结果
    if [ "$DRY_RUN" = "true" ]; then
        log_info "预览完成！共 ${total_count} 个平台配置"
        log_info "使用 --dry-run 以外的参数执行实际打包和提取"
    elif [ $success_count -eq $total_count ]; then
        log_success "所有 ${total_count} 个平台打包并提取成功！"
        echo
        log_info "文件已提取并压缩到目录: ${target_base_dir}/"
        log_info "目录结构:"
        if command -v tree >/dev/null 2>&1; then
            tree "$target_base_dir" 2>/dev/null || ls -la "$target_base_dir"
        else
            find "$target_base_dir" -type f -name "*.so.zip" | sort
        fi
    else
        log_error "打包和提取完成，但有 $((total_count - success_count)) 个平台失败"
        if [ ${#failed_platforms[@]} -gt 0 ]; then
            log_error "失败的平台: ${failed_platforms[*]}"
        fi
        exit 1
    fi
}

# 主函数
main() {
    echo "Flutter Engine libflutter.so 复制并压缩脚本 v${SCRIPT_VERSION}"
    echo "=================================================="
    
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
    
    # 检查并安装依赖
    check_and_install_dependencies
    
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
    log_info "  跳过依赖检查: $SKIP_DEPS_CHECK"
    log_info "  手动安装模式: $MANUAL_INSTALL"
    if [ -n "$FLUTTER_SDK_PATH" ]; then
        log_info "  Flutter SDK路径: $FLUTTER_SDK_PATH"
    fi
    echo
    
    # 设置错误处理
    trap cleanup_temp_project EXIT
    
    # 执行主要流程
    copy_libflutter_files "$FINAL_VERSION"
    
    # 清理所有临时目录
    cleanup_all_temp
    
    echo
    log_success "脚本执行完成！"
}

# 运行主函数
main "$@"
