#!/bin/bash
# ZCode - install (macOS)
cd "$(dirname "$0")" || exit 1
echo "============================================"
echo "  ZCode - install"
echo "============================================"
echo
bash ./deploy.sh install "$@"
echo
read -r -p "按回车键关闭..." _
