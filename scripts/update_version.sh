#!/bin/sh
# 在每次构建前将 VERSION 与 Build 号写入 Info.plist，避免手动改两处。
# - 用户可见版本：从仓库根目录的 VERSION 文件读取（一行，如 1.0.0）
# - Build 号：使用当前 Git 提交数（git rev-list --count HEAD），同一 commit 构建结果一致

set -e
SRCROOT="${SRCROOT:-$(dirname "$0")/..}"
PLIST="${SRCROOT}/BOG_TOOL/Info.plist"
VERSION_FILE="${SRCROOT}/VERSION"

if [ -f "$VERSION_FILE" ]; then
  VERSION=$(cat "$VERSION_FILE" | tr -d '\n\r ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$VERSION" ] && VERSION="1.0.0"
else
  VERSION="1.0.0"
fi

BUILD_NUM=$(git -C "$SRCROOT" rev-list --count HEAD 2>/dev/null || echo "1")

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$PLIST"

echo "BOG_TOOL: Version $VERSION (Build $BUILD_NUM)"
