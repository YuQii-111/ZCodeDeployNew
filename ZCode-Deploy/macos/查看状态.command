#!/bin/bash
# ZCode - status (macOS)
cd "$(dirname "$0")" || exit 1
echo "============================================"
echo "  ZCode - status"
echo "============================================"
echo
bash ./deploy.sh status "$@"
echo
read -r -p "按回车键关闭..." _
