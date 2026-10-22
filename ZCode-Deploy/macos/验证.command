#!/bin/bash
# ZCode - verify (macOS)
cd "$(dirname "$0")" || exit 1
echo "============================================"
echo "  ZCode - verify"
echo "============================================"
echo
bash ./deploy.sh verify "$@"
echo
read -r -p "按回车键关闭..." _
