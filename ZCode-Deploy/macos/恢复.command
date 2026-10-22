#!/bin/bash
# ZCode - restore (macOS)
cd "$(dirname "$0")" || exit 1
echo "============================================"
echo "  ZCode - restore"
echo "============================================"
echo
bash ./deploy.sh restore "$@"
echo
read -r -p "按回车键关闭..." _
