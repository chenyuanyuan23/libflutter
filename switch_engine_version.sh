#!/bin/bash

# Flutter Engine 版本切换脚本
# 切换引擎到指定版本，并自动应用 patches_backup 目录中的补丁
#
# 用法:
#   ./switch_engine_version.sh <版本号>               # 切换版本 + 应用补丁 + gclient sync
#   ./switch_engine_version.sh <版本号> --no-sync      # 切换版本 + 应用补丁，跳过 gclient sync
#   ./switch_engine_version.sh <版本号> --sync-only     # 仅运行 gclient sync（已切换过版本时）
#   ./switch_engine_version.sh --list                   # 列出可用的稳定版本
#   ./switch_engine_version.sh --current                # 显示当前版本信息

set -e

# 脚本版本
SCRIPT_VERSION="1.0.0"

# 路径配置
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UNIFIED_REPO="${ROOT_DIR}/flutter_unified_repo"
ENGINE_SRC="${UNIFIED_REPO}/engine/src"
PATCHES_DIR="${SCRIPT_DIR}/patches_backup"
DEPOT_TOOLS="${ROOT_DIR}/depot_tools"

# 选项
VERSION=""
SKIP_SYNC=false
SYNC_ONLY=false
LIST_VERSIONS=false
SHOW_CURRENT=false
BRANCH_SUFFIX="image_crash"
SKIP_PATCHES=false

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_warning() { printf "${YELLOW}[WARNING]${NC} %s\n" "$1"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$1"; }
log_step()    { printf "${PURPLE}[STEP]${NC} %s\n" "$1"; }

show_help() {
    cat << EOF
Flutter Engine 版本切换脚本 v${SCRIPT_VERSION}
================================================

用法: $0 <版本号> [选项]

参数:
  版本号                    要切换的 Flutter 版本 (如: 3.38.9)

选项:
  --no-sync                 跳过 gclient sync
  --sync-only               仅运行 gclient sync（版本已切换时使用）
  --suffix SUFFIX           自定义分支后缀 (默认: ${BRANCH_SUFFIX})
  --list, -l                列出可用的稳定版本
  --current, -c             显示当前版本信息
  --help, -h                显示此帮助信息

示例:
  $0 3.38.9                 # 切换到 3.38.9 并应用补丁
  $0 3.38.9 --no-sync       # 切换但不运行 gclient sync
  $0 --list                 # 列出所有可用稳定版本
  $0 --current              # 查看当前版本

工作流程:
  1. 检查版本 tag 是否存在
  2. checkout 到目标版本
  3. 创建分支 <版本>-${BRANCH_SUFFIX}
  4. 按顺序应用 patches_backup/ 中的所有 .patch 文件
  5. 提交修改
  6. 运行 gclient sync 同步依赖

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-sync)
                SKIP_SYNC=true
                shift
                ;;
            --sync-only)
                SYNC_ONLY=true
                shift
                ;;
            --suffix)
                BRANCH_SUFFIX="$2"
                if [ -z "$BRANCH_SUFFIX" ]; then
                    log_error "分支后缀不能为空"
                    exit 1
                fi
                shift 2
                ;;
            --list|-l)
                LIST_VERSIONS=true
                shift
                ;;
            --current|-c)
                SHOW_CURRENT=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                if [ -z "$VERSION" ]; then
                    VERSION="$1"
                else
                    log_error "多余的参数: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# 检查环境
check_environment() {
    if [ ! -d "$UNIFIED_REPO" ]; then
        log_error "flutter_unified_repo 目录不存在: $UNIFIED_REPO"
        exit 1
    fi

    if [ ! -d "$PATCHES_DIR" ]; then
        log_error "patches_backup 目录不存在: $PATCHES_DIR"
        exit 1
    fi

    if [ ! -d "$DEPOT_TOOLS" ]; then
        log_warning "depot_tools 目录不存在: $DEPOT_TOOLS"
        log_warning "gclient sync 可能无法运行"
    fi
}

# 列出可用的稳定版本
list_versions() {
    log_info "可用的稳定版本 (不含 pre-release):"
    echo

    cd "$UNIFIED_REPO"

    # 获取所有稳定版本 tag（排除 pre-release）
    local versions
    versions=$(git tag -l "[0-9]*" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)

    # 获取当前分支
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")

    # 获取已有的自定义分支
    local custom_branches
    custom_branches=$(git branch | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-' | sed 's/-$//' || true)

    for v in $versions; do
        local marker=""
        # 检查是否有对应的自定义分支
        if echo "$custom_branches" | grep -q "^${v}$"; then
            marker=" ${GREEN}(已应用补丁)${NC}"
        fi
        # 检查是否是当前版本
        if [[ "$current_branch" == "${v}-"* ]]; then
            marker="${marker} ${CYAN}<-- 当前${NC}"
        fi
        printf "  %s${marker}\n" "$v"
    done

    echo
    log_info "共 $(echo "$versions" | wc -l | tr -d ' ') 个稳定版本"
}

# 显示当前版本信息
show_current() {
    cd "$UNIFIED_REPO"

    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "(detached HEAD)")

    local current_commit
    current_commit=$(git log --oneline -1)

    echo
    log_info "当前分支: ${current_branch}"
    log_info "最新提交: ${current_commit}"
    echo

    # 显示所有自定义分支
    log_info "已有的自定义分支:"
    git branch | grep -E '[0-9]+\.[0-9]+\.[0-9]+-' | while read -r branch; do
        local b=$(echo "$branch" | tr -d '* ')
        local commit=$(git log --oneline -1 "$b" 2>/dev/null || echo "")
        if [[ "$branch" == *"*"* ]]; then
            printf "  ${GREEN}* %s${NC}  %s\n" "$b" "$commit"
        else
            printf "    %s  %s\n" "$b" "$commit"
        fi
    done

    echo
    # 显示补丁文件
    log_info "可用补丁文件 (${PATCHES_DIR}):"
    if ls "$PATCHES_DIR"/*.patch &>/dev/null; then
        for patch in "$PATCHES_DIR"/*.patch; do
            local name=$(basename "$patch")
            local lines=$(wc -l < "$patch" | tr -d ' ')
            echo "    ${name} (${lines} 行)"
        done
    else
        echo "    (无补丁文件)"
    fi
}

# 切换版本
switch_version() {
    local version="$1"
    local branch_name="${version}-${BRANCH_SUFFIX}"

    cd "$UNIFIED_REPO"

    # 检查 tag 是否存在
    if ! git tag -l "$version" | grep -q "^${version}$"; then
        log_error "版本 tag '${version}' 不存在"
        log_info "使用 '$0 --list' 查看可用版本"
        log_info "或尝试先 fetch: cd ${UNIFIED_REPO} && git fetch origin --tags"
        exit 1
    fi

    # 检查分支是否已存在
    if git branch --list "$branch_name" | grep -q "$branch_name"; then
        log_warning "分支 '${branch_name}' 已存在"
        echo
        printf "  ${CYAN}1)${NC} 删除旧分支，重新创建并应用补丁\n"
        printf "  ${CYAN}2)${NC} 直接切换到已有分支（不重新应用补丁）\n"
        printf "  ${CYAN}3)${NC} 取消操作\n"
        echo
        read -p "请选择 [1/2/3]: " choice

        case "$choice" in
            1)
                log_info "删除旧分支: ${branch_name}"
                # 先切到 detached HEAD 以便删除分支
                git checkout "$version" 2>/dev/null || true
                git branch -D "$branch_name"
                ;;
            2)
                log_info "切换到已有分支: ${branch_name}"
                git checkout "$branch_name"
                log_success "已切换到 ${branch_name}"
                SKIP_PATCHES=true
                return 0
                ;;
            3)
                log_info "取消操作"
                exit 0
                ;;
            *)
                log_error "无效选择"
                exit 1
                ;;
        esac
    fi

    # checkout 到目标版本
    log_step "切换到版本 ${version}..."
    git checkout "$version" 2>/dev/null || {
        # 忽略 vpython3 等 hook 错误
        true
    }

    # 创建新分支
    log_step "创建分支 ${branch_name}..."
    git checkout -b "$branch_name" 2>/dev/null || {
        true
    }

    log_success "已创建并切换到分支: ${branch_name}"
}

# 应用补丁
apply_patches() {
    cd "$UNIFIED_REPO"

    # 查找所有 .patch 文件并排序
    local patches=()
    for patch in "$PATCHES_DIR"/*.patch; do
        [ -f "$patch" ] && patches+=("$patch")
    done

    if [ ${#patches[@]} -eq 0 ]; then
        log_warning "patches_backup 目录中没有找到 .patch 文件"
        return 0
    fi

    log_step "应用补丁文件 (共 ${#patches[@]} 个)..."
    echo

    local applied=0
    local failed=0

    for patch in "${patches[@]}"; do
        local name=$(basename "$patch")
        log_info "应用补丁: ${name}"

        # 先检查是否能干净应用
        if git apply --check "$patch" 2>/dev/null; then
            if git apply "$patch"; then
                log_success "  ${name} 应用成功"
                ((applied++))
            else
                log_error "  ${name} 应用失败"
                ((failed++))
            fi
        else
            # 尝试检查是否已经应用过
            if git apply --check --reverse "$patch" 2>/dev/null; then
                log_warning "  ${name} 已经应用过，跳过"
                ((applied++))
            else
                log_error "  ${name} 无法干净应用（可能有冲突）"
                log_info "  尝试使用 3-way merge..."
                if git apply --3way "$patch" 2>/dev/null; then
                    log_success "  ${name} 通过 3-way merge 应用成功"
                    ((applied++))
                else
                    log_error "  ${name} 应用失败，需要手动处理"
                    ((failed++))
                fi
            fi
        fi
    done

    echo
    if [ $failed -gt 0 ]; then
        log_error "${applied} 个补丁成功，${failed} 个补丁失败"
        log_warning "请手动检查并解决冲突"
        return 1
    fi

    log_success "所有 ${applied} 个补丁应用成功"

    # 提交修改
    log_step "提交补丁修改..."
    git add -A
    if git diff --cached --quiet; then
        log_info "没有需要提交的修改（补丁可能已经应用过）"
    else
        git commit -m "image_crash_fix

Applied patches:
$(for p in "${patches[@]}"; do echo "  - $(basename "$p")"; done)" 2>/dev/null || true
        log_success "补丁已提交"
    fi
}

# 运行 gclient sync
run_gclient_sync() {
    if [ ! -d "$DEPOT_TOOLS" ]; then
        log_error "depot_tools 不存在，无法运行 gclient sync"
        log_info "请手动运行: export PATH=${DEPOT_TOOLS}:\$PATH && cd ${ENGINE_SRC} && gclient sync"
        return 1
    fi

    export PATH="${DEPOT_TOOLS}:${PATH}"

    # gclient sync 需要在 .gclient 所在目录运行
    cd "$UNIFIED_REPO"

    log_step "运行 gclient sync (可能需要较长时间)..."
    log_info "工作目录: $(pwd)"
    echo

    # 保护 out/ 目录不被 -D 删除
    local out_dir="${ENGINE_SRC}/out"
    local out_backup="${ROOT_DIR}/.out_backup"
    if [ -d "$out_dir" ]; then
        log_info "保护编译产物: 暂存 out/ 目录..."
        mv "$out_dir" "$out_backup"
    fi

    local sync_exit_code=0
    gclient sync -D || sync_exit_code=$?

    # 恢复 out/ 目录
    if [ -d "$out_backup" ]; then
        # 如果 sync 又生成了新的 out/，合并保留
        if [ -d "$out_dir" ]; then
            cp -a "$out_backup"/* "$out_dir"/ 2>/dev/null || true
            rm -rf "$out_backup"
        else
            mv "$out_backup" "$out_dir"
        fi
        log_info "编译产物已恢复"
    fi

    if [ $sync_exit_code -eq 0 ]; then
        log_success "gclient sync 完成"
    else
        # gclient sync 有 WARNING 时也会返回非零，检查关键产物判断是否真的失败
        if [ -f "${ENGINE_SRC}/flutter/tools/gn" ]; then
            log_warning "gclient sync 有警告 (exit code: ${sync_exit_code})，但关键文件存在，继续执行"
        else
            log_error "gclient sync 失败 (exit code: ${sync_exit_code})"
            log_info "可以稍后手动运行:"
            log_info "  export PATH=${DEPOT_TOOLS}:\$PATH"
            log_info "  cd ${UNIFIED_REPO} && gclient sync"
            return 1
        fi
    fi
}

# 显示完成摘要
show_summary() {
    local version="$1"
    local branch_name="${version}-${BRANCH_SUFFIX}"

    cd "$UNIFIED_REPO"

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "版本切换完成！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "版本: ${version}"
    log_info "分支: ${branch_name}"
    log_info "最新提交: $(git log --oneline -1)"
    echo

    if [ "$SKIP_SYNC" = "true" ]; then
        log_warning "gclient sync 已跳过，编译前请先运行:"
        log_info "  export PATH=${DEPOT_TOOLS}:\$PATH"
        log_info "  cd ${UNIFIED_REPO} && gclient sync"
        echo
    fi

    log_info "下一步 - 编译引擎:"
    log_info "  cd ${SCRIPT_DIR} && bash build_all_android_engines.sh"
    echo
}

# 主函数
main() {
    echo "Flutter Engine 版本切换脚本 v${SCRIPT_VERSION}"
    echo "=================================================="
    echo

    parse_args "$@"
    check_environment

    # 列出版本
    if [ "$LIST_VERSIONS" = "true" ]; then
        list_versions
        exit 0
    fi

    # 显示当前信息
    if [ "$SHOW_CURRENT" = "true" ]; then
        show_current
        exit 0
    fi

    # 仅同步模式
    if [ "$SYNC_ONLY" = "true" ]; then
        if [ -z "$VERSION" ]; then
            log_info "仅运行 gclient sync..."
        fi
        run_gclient_sync
        exit 0
    fi

    # 检查版本号
    if [ -z "$VERSION" ]; then
        log_error "请指定版本号"
        echo
        show_help
        exit 1
    fi

    log_info "目标版本: ${VERSION}"
    log_info "分支后缀: ${BRANCH_SUFFIX}"
    log_info "补丁目录: ${PATCHES_DIR}"
    log_info "gclient sync: $([ "$SKIP_SYNC" = "true" ] && echo "跳过" || echo "启用")"
    echo

    # 1. 切换版本
    switch_version "$VERSION"
    echo

    # 2. 应用补丁
    if [ "$SKIP_PATCHES" = "false" ]; then
        apply_patches
    else
        log_info "已有分支，跳过补丁应用"
    fi
    echo

    # 3. gclient sync
    if [ "$SKIP_SYNC" = "false" ]; then
        run_gclient_sync
        echo
    fi

    # 4. 显示摘要
    show_summary "$VERSION"
}

main "$@"
