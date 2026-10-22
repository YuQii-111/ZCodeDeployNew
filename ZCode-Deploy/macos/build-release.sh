#!/bin/bash
# ============================================
# ZCode-Deploy (macOS) 发布打包脚本
#
# 用法: bash build-release.sh [版本号]
#
# 产物: macos/dist/ZCode-Deploy-mac-v<版本>.zip
#       macos/dist/ZCode-Deploy-mac-v<版本>.zip.sha256
#
# 打包内容是**白名单**：清单在下方 payload() 里，
# 机器本地产物（backups/、zcode-dir.txt、dist/ 等）不会进包。
# 打出的 zip 是自包含的：mac 用户解压即用（若执行位丢失见 README 说明）。
# ============================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
STAGE_ROOT="$DIST_DIR/_stage"

# ---- 版本号：默认从 deploy.sh 读取 ----
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(sed -n 's/^TOOL_VERSION="\(.*\)"$/\1/p' "$SCRIPT_DIR/deploy.sh" | head -1)"
    if [ -z "$VERSION" ]; then
        echo "[失败] 无法从 deploy.sh 读取版本号，请用参数指定: bash build-release.sh 2.1.0"
        exit 1
    fi
fi

RELEASE_NAME="ZCode-Deploy-mac-v$VERSION"
STAGE="$STAGE_ROOT/$RELEASE_NAME"
ZIP_PATH="$DIST_DIR/$RELEASE_NAME.zip"
SHA_PATH="$ZIP_PATH.sha256"

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 -r "$1" | awk '{print $1}'
    else
        echo ""
    fi
}

# BSD(macOS)/GNU(Linux、测试环境) stat 自适应
# 注意不能靠 "stat -f 失败则回退 stat -c"：GNU stat -f 是文件系统开关，不会失败
fsize() {
    if stat -c '%s' / >/dev/null 2>&1; then
        stat -c '%s' "$1" 2>/dev/null || echo '?'
    else
        stat -f '%z' "$1" 2>/dev/null || echo '?'
    fi
}

echo "=== ZCode-Deploy (macOS) 发布打包 ==="
echo "版本:   $VERSION"
echo "产物:   $ZIP_PATH"
echo

# ---- 发布白名单 ----
# 必需文件（缺失即中止）；文档文件（缺失仅警告跳过）
# 源路径解析：先本目录，再上级 —— 兼容两种布局：
#   A. 独立自包含目录（本仓库 macos/，人格.txt / verify-patch.cjs 就在旁边）
#   B. 嵌套布局（如 ZCode-Deploy/macos/，共享文件在上级）
PAYLOAD_REQ="deploy.sh zcode-patch.pl 部署.command 恢复.command 查看状态.command 验证.command build-release.sh verify-patch.cjs 人格.txt"
PAYLOAD_DOC="README.md LICENSE 修改记录.md CHANGELOG.md"

resolve_src() {
    if [ -f "$SCRIPT_DIR/$1" ]; then printf '%s\n' "$SCRIPT_DIR/$1"; return 0; fi
    if [ -f "$SCRIPT_DIR/../$1" ]; then printf '%s\n' "$SCRIPT_DIR/../$1"; return 0; fi
    return 1
}

echo "[1/5] 校验白名单文件..."
missing=0
for f in $PAYLOAD_REQ; do
    src="$(resolve_src "$f")" || { echo "  [缺失] $f"; missing=$((missing+1)); continue; }
    printf '  [OK] %s (%s bytes)\n' "$f" "$(fsize "$src")"
done
for f in $PAYLOAD_DOC; do
    src="$(resolve_src "$f")" || { echo "  [跳过] 文档缺失: $f"; continue; }
    printf '  [OK] %s (%s bytes)\n' "$f" "$(fsize "$src")"
done
if [ "$missing" -gt 0 ]; then
    echo
    echo "[失败] 缺少 $missing 个必需文件，已中止"
    exit 1
fi

echo "  预检脚本语法..."
fail=0
for f in deploy.sh build-release.sh 部署.command 恢复.command 查看状态.command 验证.command; do
    if ! bash -n "$SCRIPT_DIR/$f" 2>/dev/null; then
        echo "  [失败] bash 语法错误: $f"
        fail=1
    fi
done
if command -v perl >/dev/null 2>&1; then
    perl -c "$SCRIPT_DIR/zcode-patch.pl" >/dev/null 2>&1 || { echo "  [失败] perl 语法错误: zcode-patch.pl"; fail=1; }
else
    echo "  [跳过] 本机无 perl，未检查 zcode-patch.pl"
fi
if command -v node >/dev/null 2>&1; then
    vsrc="$(resolve_src verify-patch.cjs)" && node --check "$vsrc" 2>/dev/null || { echo "  [失败] node 语法错误: verify-patch.cjs"; fail=1; }
else
    echo "  [跳过] 本机无 node，未检查 verify-patch.cjs"
fi
[ "$fail" -ne 0 ] && { echo "[失败] 脚本语法预检未通过，已中止"; exit 1; }

echo "[2/5] 准备暂存目录..."
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE"

echo "[3/5] 复制文件并生成清单..."
PAYLOAD_LIST=""
for f in $PAYLOAD_REQ $PAYLOAD_DOC; do
    src="$(resolve_src "$f")" && PAYLOAD_LIST+="$f"$'\t'"$src"$'\n'
done
N_FILES="$(printf '%s' "$PAYLOAD_LIST" | grep -c .)"
while IFS=$'\t' read -r dst src; do
    [ -n "$dst" ] || continue
    cp "$src" "$STAGE/$dst"
done <<< "$PAYLOAD_LIST"
# 执行位（zip 解压或 git clone 后可能丢失，先在暂存里保证正确）
chmod +x "$STAGE/deploy.sh" "$STAGE/build-release.sh" "$STAGE/zcode-patch.pl" \
         "$STAGE/部署.command" "$STAGE/恢复.command" "$STAGE/查看状态.command" "$STAGE/验证.command"

MANIFEST="$STAGE/MANIFEST.txt"
{
    echo "# $RELEASE_NAME"
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "文件数:   $N_FILES"
    echo
    printf '%s  %8s  %s\n' "SHA256" "SIZE" "NAME"
    printf '%.0s-' {1..78}; echo
    total=0
    while IFS=$'\t' read -r dst src; do
        [ -n "$dst" ] || continue
        f="$STAGE/$dst"
        h="$(sha256_of "$f")"
        s="$(fsize "$f")"
        case "$s" in ''|'?') s=0;; esac
        total=$((total + s))
        printf '%s  %8s  %s\n' "${h:-?}" "$s" "$dst"
    done <<< "$PAYLOAD_LIST"
    printf '%.0s-' {1..78}; echo
    echo "总计: $total bytes"
} > "$MANIFEST"
echo "  已写入 MANIFEST.txt"

echo "[4/5] 打包 zip..."
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
if command -v ditto >/dev/null 2>&1; then
    # ditto: 保留执行位与 UTF-8 文件名，不带 __MACOSX 垃圾（macOS 首选）
    ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP_PATH"
elif command -v zip >/dev/null 2>&1; then
    # zip 兜底（Linux CI）
    (cd "$STAGE_ROOT" && zip -r -X -q "$ZIP_PATH" "$RELEASE_NAME" -x '*.DS_Store')
elif command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    # python zipfile 兜底（Windows 测试环境）：正斜杠条目名，mac 可直接解压；
    # 执行位不保留 —— 解压后按 README 执行 chmod +x
    PY_BIN="$(command -v python || command -v python3)"
    "$PY_BIN" - "$ZIP_PATH" "$STAGE_ROOT" "$RELEASE_NAME" <<'PYEOF'
import sys, os, zipfile
zpath, stage_root, folder = sys.argv[1], sys.argv[2], sys.argv[3]
src = os.path.join(stage_root, folder)
with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for base, dirs, files in os.walk(src):
        dirs.sort(); files.sort()
        for name in files:
            if name == '.DS_Store':
                continue
            full = os.path.join(base, name)
            rel = folder + '/' + os.path.relpath(full, src).replace(os.sep, '/')
            z.write(full, rel)
print('  (python zipfile 兜底打包)')
PYEOF
else
    echo "[失败] 无 ditto / zip / python，无法打包"
    exit 1
fi
printf '  [OK] %s (%s bytes)\n' "$(basename "$ZIP_PATH")" "$(fsize "$ZIP_PATH")"

echo "[5/5] 计算校验和..."
ZIP_HASH="$(sha256_of "$ZIP_PATH")"
printf '%s  %s\n' "${ZIP_HASH:-?}" "$RELEASE_NAME.zip" > "$SHA_PATH"
echo "  [OK] ${ZIP_HASH:-?}"

rm -rf "$STAGE_ROOT"

echo
echo "=== 打包完成 ==="
echo "  $ZIP_PATH"
echo "  $SHA_PATH"
