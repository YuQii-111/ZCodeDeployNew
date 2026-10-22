#!/bin/bash
# ============================================
# ZCode 一键人格部署工具 (macOS 版)  v2.2.0-mac
# 移植自 Windows 版 deploy.ps1 v2.0
#
# v2.2.2: mac 打包白名单源路径自适应（本目录→上级），macos/ 可整体移植
# v2.2.1: 人格.txt / verify-patch.cjs 各自内置于本目录（取消根目录公共层，每包自包含）
# v2.2.0: 仓库重组为 windows/ + macos/ 双目录，按操作系统出包发布
# v2.1.1: 修复 .bak 刷新 cp 失败时误报 [OK]
# v2.1.0: 首个 macOS 版
#
# 用法: bash deploy.sh <install|restore|status|diag|verify|help> [选项]
#
# macOS 与 Windows 版的差异：
#   1. 目标位于 .app 包内（自动探测 Contents/Resources/glm/zcode.cjs
#      等三种布局）
#   2. 写入后自动 ad-hoc 重签名（codesign），否则 Apple Silicon 上
#      应用会被系统直接杀死 (Killed: 9)
#   3. 补丁引擎在 zcode-patch.pl（perl，macOS 预装；补丁正则用到
#      反向引用，bash/zsh 的 ERE 做不到）
#
# 环境变量: ZCODE_DIR  手动指定 ZCode.app 路径（探测失败时使用）
# ============================================
set -u

TOOL_VERSION="2.2.2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/人格.txt"
# 仓库布局兜底（人格.txt 在上级）；打出的 zip 中两者同层，优先命中第一个
[ -f "$PROMPT_FILE" ] || PROMPT_FILE="$SCRIPT_DIR/../人格.txt"
PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
BACKUP_DIR="$SCRIPT_DIR/backups"
DIR_CACHE="$SCRIPT_DIR/zcode-dir.txt"
PATCH_LIB="$SCRIPT_DIR/zcode-patch.pl"
VERIFY_CJS="$SCRIPT_DIR/verify-patch.cjs"
# 嵌套布局回退（verify-patch.cjs 在上级，与人格文件同语义）
[ -f "$VERIFY_CJS" ] || VERIFY_CJS="$SCRIPT_DIR/../verify-patch.cjs"
MARKER="ZP:PERSONA"

ACTION="status"
ALLOW_PARTIAL=0
NO_RESTART=0
TMP_CJS=""

# ---------- 颜色 ----------
if [ -t 1 ]; then
    C_INFO=$'\e[36m'; C_OK=$'\e[32m'; C_SKIP=$'\e[90m'
    C_WARN=$'\e[33m'; C_BAD=$'\e[31m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_INFO=""; C_OK=""; C_SKIP=""; C_WARN=""; C_BAD=""; C_DIM=""; C_RST=""
fi
Info()  { printf '%s\n' "${C_INFO}$1${C_RST}"; }
Good()  { printf '%s\n' "  ${C_OK}[OK]${C_RST} $1"; }
Skipd() { printf '%s\n' "  ${C_SKIP}[跳过]${C_RST} $1"; }
Warn2() { printf '%s\n' "  ${C_WARN}[警告]${C_RST} $1"; }
Bad()   { printf '%s\n' "  ${C_BAD}[失败]${C_RST} $1"; }
Note()  { printf '%s\n' "  ${C_DIM}$1${C_RST}"; }

cleanup() { [ -n "$TMP_CJS" ] && [ -f "$TMP_CJS" ] && rm -f "$TMP_CJS"; }
trap cleanup EXIT

# ---------- 参数 ----------
for arg in "$@"; do
    case "$arg" in
        install|restore|status|diag|verify|help) ACTION="$arg" ;;
        --allow-partial) ALLOW_PARTIAL=1 ;;
        --no-restart)    NO_RESTART=1 ;;
        -h|--help)       ACTION="help" ;;
        *)
            Bad "未知参数: $arg（可用: install restore status diag verify help --allow-partial --no-restart）"
            exit 1
            ;;
    esac
done

# ---------- 依赖 ----------
PERL_BIN="$(command -v perl || true)"
if [ -z "$PERL_BIN" ]; then
    Bad "未找到 perl（macOS 系统应自带；若被删除请: brew install perl）"
    exit 1
fi
if [ ! -f "$PATCH_LIB" ]; then
    Bad "缺少补丁引擎: $PATCH_LIB"
    exit 1
fi

find_node() {
    local p
    p="$(command -v node 2>/dev/null)" && [ -n "$p" ] && { echo "$p"; return 0; }
    for p in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}
NODE_BIN="$(find_node || true)"

# ---------- 文件信息（自动适配 BSD/GNU stat） ----------
if stat -c '%s' / >/dev/null 2>&1; then
    # GNU stat（Linux / 测试环境）
    fsize()  { stat -c '%s' "$1" 2>/dev/null || echo '?'; }
    fmtime() { stat -c '%y' "$1" 2>/dev/null || echo '?'; }
else
    # BSD stat（macOS）
    fsize()  { stat -f '%z' "$1" 2>/dev/null || echo '?'; }
    fmtime() { stat -f '%Sm' -t '%Y/%m/%d %H:%M:%S' "$1" 2>/dev/null || echo '?'; }
fi

# ---------- ZCode 安装目录检测 ----------
# 返回 0 并设置 ZCODE_ROOT / ZCODE_CJS
probe_root() {
    local root="$1" p
    [ -d "$root" ] || return 1
    for p in "Contents/Resources/glm/zcode.cjs" "resources/glm/zcode.cjs" "glm/zcode.cjs"; do
        if [ -f "$root/$p" ]; then
            ZCODE_ROOT="$root"
            ZCODE_CJS="$root/$p"
            return 0
        fi
    done
    return 1
}

find_zcode() {
    local app exe pid
    # 1) 环境变量
    if [ -n "${ZCODE_DIR:-}" ] && probe_root "$ZCODE_DIR"; then return 0; fi

    # 2) 运行中的进程路径 -> .app 根（大小写两种进程名都试）
    local pids
    pids="$(pgrep -x ZCode 2>/dev/null; pgrep -x zcode 2>/dev/null)"
    for pid in $pids; do
        exe="$(ps -o comm= -p "$pid" 2>/dev/null)"
        case "$exe" in
            */Contents/MacOS/*)
                app="${exe%/Contents/MacOS/*}"
                probe_root "$app" && return 0
                ;;
        esac
    done

    # 3) 缓存
    if [ -f "$DIR_CACHE" ]; then
        app="$(tr -d '[:space:]' < "$DIR_CACHE")"
        [ -n "$app" ] && probe_root "$app" && return 0
    fi

    # 4) 常规位置
    for app in "/Applications/ZCode.app" "/Applications/zcode.app" \
               "$HOME/Applications/ZCode.app" "$HOME/Applications/zcode.app"; do
        probe_root "$app" && return 0
    done

    return 1
}

if ! find_zcode; then
    Bad "未找到 ZCode 安装目录（已尝试: 运行进程 / 缓存 / ~/Applications / /Applications）"
    Note "手动指定示例:  export ZCODE_DIR=/Applications/ZCode.app && bash deploy.sh status"
    exit 1
fi
ZCODE_BACKUP="$ZCODE_CJS.bak"
printf '%s\n' "$ZCODE_ROOT" > "$DIR_CACHE" 2>/dev/null || true

Info "ZCode 目录:  $ZCODE_ROOT"
Info "目标文件:    $ZCODE_CJS"
Info "人格文件:    $PROMPT_FILE"
echo

# ---------- 备份 ----------
archive_current() {
    local file="$1" kind="$2" stamp dest f
    mkdir -p "$BACKUP_DIR"
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="$BACKUP_DIR/zcode.cjs.$kind-$stamp.bak"
    cp -p "$file" "$dest"
    # 保留最新 6 份（与 Windows 版一致）
    ls -t "$BACKUP_DIR"/*.bak 2>/dev/null | tail -n +7 | while IFS= read -r f; do
        rm -f "$f"
    done
    echo "$dest"
}

# ---------- 语法校验 ----------
check_js_syntax() {
    local file="$1" out
    if [ -z "$NODE_BIN" ]; then
        Warn2 "(未找到 node，跳过语法校验)"
        return 0
    fi
    out="$("$NODE_BIN" --check "$file" 2>&1)"
    if [ $? -ne 0 ]; then
        Bad "语法校验失败:"
        printf '%s\n' "$out"
        return 1
    fi
    return 0
}

# ---------- 重签名（macOS 特有） ----------
resign_app() {
    local root="$1"
    case "$root" in
        *.app) ;;
        *) Note "目标不在 .app 包内，跳过重签名"; return 0 ;;
    esac
    if ! command -v codesign >/dev/null 2>&1; then
        Warn2 "未找到 codesign，跳过重签名（应用可能无法启动）"
        return 0
    fi
    if codesign --force --deep --sign - "$root" >/dev/null 2>&1; then
        Good "已 ad-hoc 重签名 $root"
    else
        Warn2 "重签名失败（应用可能无法启动，可手动执行: codesign --force --deep --sign - '$root'）"
    fi
}

# ---------- 重启 ----------
stop_zcode() {
    local i
    osascript -e 'quit app "ZCode"' >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8; do
        pgrep -x ZCode >/dev/null 2>&1 || return 0
        sleep 1
    done
    pkill -x ZCode >/dev/null 2>&1
    sleep 2
}

restart_zcode() {
    if [ "$NO_RESTART" -eq 1 ]; then Note "已跳过 ZCode 重启 (--no-restart)"; return 0; fi
    stop_zcode
    if [ -d "$ZCODE_ROOT" ]; then
        if open -a "$ZCODE_ROOT" >/dev/null 2>&1; then
            sleep 3
            Good "ZCode 已启动 ($(pgrep -x ZCode 2>/dev/null | wc -l | tr -d ' ') 个进程)"
        else
            Warn2 "启动失败，请手动打开 $ZCODE_ROOT"
        fi
    else
        Warn2 "未找到 $ZCODE_ROOT，请手动启动 ZCode"
    fi
}

# ---------- 补丁显示（中文标签） ----------
patch_label() {
    case "$1" in
        1) echo "CLI Prefix 身份声明置空" ;;
        2) echo "customSystemPrompt 读人格文件" ;;
        3) echo "Agent Identity 读人格文件" ;;
        4) echo "日期提醒移除" ;;
        5) echo "Skills 列表移除" ;;
        6) echo "User Context 移除" ;;
        *) echo "补丁 #$1" ;;
    esac
}
report_label() {
    case "$1" in
        1) echo "CLI Prefix 身份声明" ;;
        2) echo "customSystemPrompt 读人格文件" ;;
        3) echo "Agent Identity 读人格文件" ;;
        4) echo "日期提醒已移除" ;;
        5) echo "Skills 列表已移除" ;;
        6) echo "User Context 已移除" ;;
        *) echo "校验 #$1" ;;
    esac
}

run_patch_report() {
    "$PERL_BIN" "$PATCH_LIB" report "$1" | while IFS=$'\t' read -r _ st idx; do
        if [ "$st" = "ok" ]; then Good "$(report_label "$idx")"
        else Warn2 "$(report_label "$idx")"; fi
    done
}

show_sections() {
    "$PERL_BIN" "$PATCH_LIB" sections "$1"
}

bundle_info() {
    local meta
    meta="$(dirname "$ZCODE_CJS")/.node-bundle-meta.json"
    [ -f "$meta" ] && tr -s '[:space:]' ' ' < "$meta"
}

# ============================================
# 动作
# ============================================
case "$ACTION" in

help)
    Info "ZCode-Deploy (macOS) v$TOOL_VERSION"
    echo
    Note "用法: bash deploy.sh <动作> [选项]"
    echo
    Note "动作:"
    Note "  install         部署（备份原版 -> 打补丁 -> 语法校验 -> 重签名 -> 重启 ZCode）"
    Note "  restore         还原原版（保留人格文件）"
    Note "  status          查看部署状态与补丁校验"
    Note "  diag            列出全部注入片段及其产物函数（排查用）"
    Note "  verify          diag + 功能级验证（需 node）"
    Note "  help            显示本帮助"
    echo
    Note "选项:"
    Note "  --allow-partial 有补丁未命中时也强行部署（默认中止，不写入）"
    Note "  --no-restart    部署/还原后不重启 ZCode"
    echo
    Note "人格文件: $PROMPT_FILE"
    Note "安装目录: 可用环境变量 ZCODE_DIR 手工指定（指向 ZCode.app 或等效根目录）"
    ;;

status)
    Info "=== ZCode 部署状态 (macOS) ==="
    Note "工具版本:   v$TOOL_VERSION"
    echo
    if [ ! -f "$ZCODE_CJS" ]; then Bad "目标文件不存在: $ZCODE_CJS"; exit 1; fi
    if grep -aq "$MARKER" "$ZCODE_CJS"; then patched=1; else patched=0; fi

    Note "文件大小:   $(fsize "$ZCODE_CJS") bytes"
    Note "修改时间:   $(fmtime "$ZCODE_CJS")"
    binfo="$(bundle_info)"
    [ -n "$binfo" ] && Note "bundle:     $binfo"
    if [ -f "$PROMPT_FILE" ]; then
        Note "人格文件:   $(fsize "$PROMPT_FILE") bytes"
    else
        Note "人格文件:   缺失"
    fi
    if [ -f "$ZCODE_BACKUP" ]; then
        Note "原版备份:   $(fsize "$ZCODE_BACKUP") bytes / $(fmtime "$ZCODE_BACKUP")"
    else
        Note "原版备份:   无"
    fi
    Note "语法校验:   ${NODE_BIN:-未找到 node}"
    echo
    if [ "$patched" -eq 1 ]; then
        printf '%s\n' "${C_WARN}模式: 自定义人格 (已部署)${C_RST}"
    else
        printf '%s\n' "${C_OK}模式: ZCode 原版 (未部署)${C_RST}"
    fi
    echo
    Info "--- 补丁校验 ---"
    run_patch_report "$ZCODE_CJS"
    if [ -f "$ZCODE_BACKUP" ] && [ "$patched" -eq 0 ]; then
        if [ "$(fsize "$ZCODE_BACKUP")" != "$(fsize "$ZCODE_CJS")" ]; then
            echo
            Warn2 "备份与当前版本大小不一致 —— 说明 ZCode 更新过。重跑 install 会自动刷新 .bak。"
        fi
    fi
    ;;

diag)
    Info "=== 注入片段定位 (诊断) ==="
    echo
    if grep -aq "$MARKER" "$ZCODE_CJS"; then dep="是"; else dep="否"; fi
    Note "文件: $ZCODE_CJS  ($(fsize "$ZCODE_CJS") bytes)"
    Note "已部署: $dep"
    echo
    show_sections "$ZCODE_CJS"
    ;;

verify)
    Info "=== 注入片段定位 (诊断) ==="
    echo
    if grep -aq "$MARKER" "$ZCODE_CJS"; then dep="是"; else dep="否"; fi
    Note "文件: $ZCODE_CJS  ($(fsize "$ZCODE_CJS") bytes)"
    Note "已部署: $dep"
    echo
    show_sections "$ZCODE_CJS"
    echo
    Info "--- 功能级验证 ---"
    echo
    if [ -z "$NODE_BIN" ]; then
        Warn2 "未找到 node，功能级验证跳过"
    elif [ -f "$VERIFY_CJS" ]; then
        "$NODE_BIN" "$VERIFY_CJS" "$ZCODE_CJS"
    else
        Warn2 "缺少 verify-patch.cjs: $VERIFY_CJS"
    fi
    ;;

install)
    Info "[1/6] 检查人格文件..."
    if [ ! -f "$PROMPT_FILE" ]; then
        Bad "未找到 $PROMPT_FILE"
        exit 1
    fi
    Good "$PROMPT_FILE ($(fsize "$PROMPT_FILE") bytes)"

    Info "[2/6] 读取并备份目标文件..."
    if grep -aq "$MARKER" "$ZCODE_CJS"; then already=1; else already=0; fi
    if [ "$already" -eq 1 ]; then
        arch="$(archive_current "$ZCODE_CJS" patched)"
        Note "已归档当前已破解版本 -> $arch"
    else
        arch="$(archive_current "$ZCODE_CJS" stock)"
        Note "已归档当前原版 -> $arch"
    fi
    if [ "$already" -eq 0 ]; then
        if [ -f "$ZCODE_BACKUP" ] && [ "$(fsize "$ZCODE_BACKUP")" = "$(fsize "$ZCODE_CJS")" ]; then
            Skipd "zcode.cjs.bak 已是最新原版"
        else
            if cp -p "$ZCODE_CJS" "$ZCODE_BACKUP" 2>&1; then
                Good "已刷新 zcode.cjs.bak (新版原版，restore 不再降级)"
            else
                Warn2 "zcode.cjs.bak 刷新失败（restore 将不可用，本次继续）"
            fi
        fi
    elif [ ! -f "$ZCODE_BACKUP" ]; then
        Warn2 "缺少原版备份 .bak，restore 将不可用"
    fi

    Info "[3/6] 应用补丁..."
    if [ ! -w "$(dirname "$ZCODE_CJS")" ]; then
        Bad "目标目录不可写: $(dirname "$ZCODE_CJS")"
        Note "修复示例:  sudo chown -R \"\$(whoami)\" '$ZCODE_ROOT'  然后重试"
        exit 1
    fi
    TMP_CJS="$SCRIPT_DIR/.patch-tmp-$$.cjs"
    PATCH_LOG="$SCRIPT_DIR/.patch-log-$$.txt"
    "$PERL_BIN" "$PATCH_LIB" patch "$ZCODE_CJS" "$PROMPT_FILE" "$TMP_CJS" > "$PATCH_LOG" 2>&1
    patch_rc=$?
    missing=0
    while IFS=$'\t' read -r _kw _pid pst pfn; do
        [ "${_kw:-}" = "PATCH" ] || continue
        [ -z "${_pid:-}" ] && continue
        tag=""
        [ -n "$pfn" ] && tag=" ($pfn)"
        lbl="$(patch_label "$_pid")"
        case "$pst" in
            ok)      Good "[$_pid] $lbl$tag" ;;
            skip)    Skipd "[$_pid] $lbl$tag" ;;
            missing) Bad "[$_pid] $lbl$tag — 未找到目标"; missing=$((missing+1)) ;;
        esac
    done < "$PATCH_LOG"
    if [ "$patch_rc" -ne 0 ] && [ "$patch_rc" -ne 2 ] && [ "$missing" -eq 0 ]; then
        # perl 自身出错（非补丁未命中）
        Bad "补丁引擎异常退出 (rc=$patch_rc):"
        cat "$PATCH_LOG"
        rm -f "$PATCH_LOG"
        exit 1
    fi
    rm -f "$PATCH_LOG"
    if [ "$patch_rc" -ne 0 ] && [ "$missing" -eq 0 ]; then
        # perl 自身出错（非补丁未命中）
        Bad "补丁引擎异常退出 (rc=$patch_rc):"
        printf '%s\n' "$patch_out"
        exit 1
    fi

    if [ "$missing" -gt 0 ] && [ "$ALLOW_PARTIAL" -eq 0 ]; then
        echo
        Bad "有 $missing 个补丁未命中，ZCode 版本可能又变了。未做任何修改。"
        Note "请把下面这段诊断结果发给维护者："
        echo
        show_sections "$ZCODE_CJS"
        echo
        Note "如确认可以接受不完整结果，可加 --allow-partial 强制部署。"
        exit 1
    fi

    Info "[4/6] 语法校验 (node --check)..."
    check_js_syntax "$TMP_CJS" || exit 1
    [ -n "$NODE_BIN" ] && Good "语法校验通过"

    Info "[5/6] 写入 zcode.cjs..."
    cp "$TMP_CJS" "$ZCODE_CJS"
    rm -f "$TMP_CJS"; TMP_CJS=""
    Good "已写入 ($(fsize "$ZCODE_CJS") bytes)"
    resign_app "$ZCODE_ROOT"

    echo
    Info "--- 写入后自检 ---"
    run_patch_report "$ZCODE_CJS"
    Note "人格文件路径(已写入 cjs): $PROMPT_FILE"

    Info "[6/6] 重启 ZCode..."
    restart_zcode

    echo
    printf '%s\n' "${C_OK}=== 部署完成 ===${C_RST}"
    Note "人格文件: $PROMPT_FILE   (改这个文件即可热换人格，开新对话生效)"
    Note "注意: 本文件夹被移动后需要重跑 install（路径已写入 zcode.cjs）"
    ;;

restore)
    Info "[1/4] 检查备份..."
    if [ ! -f "$ZCODE_BACKUP" ]; then
        Bad "备份不存在: $ZCODE_BACKUP"
        if [ -d "$BACKUP_DIR" ]; then
            Note "备份目录中可用档案:"
            ls -t "$BACKUP_DIR"/*.bak 2>/dev/null | head -10 | while IFS= read -r f; do
                Note "  $(basename "$f")  ($(fsize "$f") bytes, $(fmtime "$f"))"
            done
        fi
        exit 1
    fi
    Good "备份: $ZCODE_BACKUP ($(fsize "$ZCODE_BACKUP") bytes)"

    Info "[2/4] 校验备份并归档当前版本..."
    TMP_CJS="$SCRIPT_DIR/.restore-tmp-$$.cjs"
    cp "$ZCODE_BACKUP" "$TMP_CJS"
    if ! check_js_syntax "$TMP_CJS"; then
        Bad "备份文件语法校验失败，已中止还原"
        rm -f "$TMP_CJS"; TMP_CJS=""
        exit 1
    fi
    if grep -aq "$MARKER" "$ZCODE_CJS"; then
        arch="$(archive_current "$ZCODE_CJS" patched)"
        Note "已归档当前已破解版本 -> $arch"
    fi

    Info "[3/4] 还原代码..."
    if [ ! -w "$(dirname "$ZCODE_CJS")" ]; then
        Bad "目标目录不可写: $(dirname "$ZCODE_CJS")"
        Note "修复示例:  sudo chown -R \"\$(whoami)\" '$ZCODE_ROOT'  然后重试"
        rm -f "$TMP_CJS"; TMP_CJS=""
        exit 1
    fi
    if cp "$TMP_CJS" "$ZCODE_CJS" 2>&1; then
        Good "已还原为原版"
    else
        Bad "还原写入失败（目标不可写？）"
        rm -f "$TMP_CJS"; TMP_CJS=""
        exit 1
    fi
    rm -f "$TMP_CJS"; TMP_CJS=""
    resign_app "$ZCODE_ROOT"

    if [ -f "$PROMPT_FILE" ]; then Skipd "人格文件保留: $PROMPT_FILE"; fi

    Info "[4/4] 重启 ZCode..."
    restart_zcode

    echo
    printf '%s\n' "${C_OK}=== 恢复完成 ===${C_RST}"
    ;;
esac
