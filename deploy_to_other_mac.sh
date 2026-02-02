#!/bin/bash
# 使用 Xcode Archive + Developer ID 签名（可选公证），输出到 Deploy，对方 Mac 可直接双击打开。
# 若另一台 Mac 通过 USB-C 目标磁盘模式挂载，可传入其卷路径直接拷贝过去。
#
# 用法：
#   ./deploy_to_other_mac.sh                    # 仅打包并签名，输出到 Deploy
#   NOTARIZE=1 ./deploy_to_other_mac.sh         # 同上，并提交公证（需先配置 notarytool）
#   ./deploy_to_other_mac.sh /Volumes/MacBook   # 拷贝到另一台 Mac 的卷

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
SCHEME="BOG_TOOL"
ARCHIVE_DIR="$SCRIPT_DIR/build"
ARCHIVE_PATH="$ARCHIVE_DIR/BOG_TOOL.xcarchive"
APP_NAME="BOG Tool.app"
DEPLOY_DIR="$SCRIPT_DIR/Deploy"
ENTITLEMENTS="$SCRIPT_DIR/BOG_TOOL/BOG_TOOL.entitlements"
DEST_VOLUME="$1"

# 自动检测 Developer ID Application 证书（可设置环境变量 DEVELOPER_ID_IDENTITY 指定）
DEV_ID="${DEVELOPER_ID_IDENTITY:-}"
if [[ -z "$DEV_ID" ]]; then
  DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
USE_DEV_ID=0
if [[ -n "$DEV_ID" ]]; then
  echo "使用签名身份：$DEV_ID"
  USE_DEV_ID=1
else
  echo "未找到「Developer ID Application」证书，将用 ad-hoc 签名打包（本机可双击打开；对方 Mac 需 xattr -cr 再右键打开）。"
  echo "若你有开发者 ID，请先在钥匙串中安装「Developer ID Application」证书后重试，对方即可直接打开。"
fi

echo ""
echo "=== 1. 使用 Archive 打包（Release，通用架构 arm64 + x86_64）==="
xcodebuild -scheme "$SCHEME" -configuration Release -archivePath "$ARCHIVE_PATH" clean archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "错误：未找到 Archive 内的 app：$APP_PATH"
  exit 1
fi

echo ""
echo "=== 2. 复制到 Deploy 并签名（Developer ID 或 ad-hoc）==="
mkdir -p "$DEPLOY_DIR"
rm -rf "$DEPLOY_DIR/$APP_NAME"
cp -R "$APP_PATH" "$DEPLOY_DIR/$APP_NAME"
if [[ "$USE_DEV_ID" == "1" ]]; then
  if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --deep --sign "$DEV_ID" --options runtime --entitlements "$ENTITLEMENTS" "$DEPLOY_DIR/$APP_NAME"
  else
    codesign --force --deep --sign "$DEV_ID" --options runtime "$DEPLOY_DIR/$APP_NAME"
  fi
else
  # 无 Developer ID 时：去签后改用 ad-hoc 重签，本机可双击打开；对方 Mac 仍需 xattr + 右键打开
  codesign --remove-signature "$DEPLOY_DIR/$APP_NAME"
  if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --deep -s - --options runtime --entitlements "$ENTITLEMENTS" "$DEPLOY_DIR/$APP_NAME"
  else
    codesign --force --deep -s - --options runtime "$DEPLOY_DIR/$APP_NAME"
  fi
fi

# 可选：公证（NOTARIZE=1 且已用 Developer ID 签名且已配置 notarytool 时执行）
if [[ "$NOTARIZE" == "1" && "$USE_DEV_ID" == "1" ]]; then
  echo ""
  echo "=== 3. 提交公证（需联网，可能需几分钟）==="
  ZIP_PATH="$DEPLOY_DIR/BOG_Tool.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$DEPLOY_DIR/$APP_NAME" "$ZIP_PATH"
  if xcrun notarytool submit "$ZIP_PATH" --keychain-profile "AC_PASSWORD" --wait 2>/dev/null; then
    xcrun stapler staple "$DEPLOY_DIR/$APP_NAME"
    echo "公证完成并已钉到 app。"
  else
    echo "公证未执行或失败。若未配置 notarytool，请先运行："
    echo "  xcrun notarytool store --apple-id 你的AppleID --team-id 你的TeamID --password 应用专用密码 --profile AC_PASSWORD"
    echo "然后重新执行： NOTARIZE=1 ./deploy_to_other_mac.sh"
  fi
  rm -f "$ZIP_PATH"
fi

echo ""
echo "完成。可部署的 app 位置："
echo "  $DEPLOY_DIR/$APP_NAME"
if [[ "$USE_DEV_ID" == "1" ]]; then
  echo "（已用 Developer ID 签名，对方 Mac 可直接双击打开；若已公证则无需任何额外操作。）"
else
  echo "（已用 ad-hoc 签名，本机可双击打开；对方 Mac 首次打开需：xattr -cr \"...BOG Tool.app\"，再右键 → 打开。）"
fi

# 若传入了另一台 Mac 的卷路径（通过 USB-C 目标磁盘模式挂载），直接拷贝到其「应用程序」
if [[ -n "$DEST_VOLUME" ]]; then
  DEST_APPS="${DEST_VOLUME%/}/Applications"
  if [[ ! -d "$DEST_APPS" ]]; then
    echo ""
    echo "错误：未找到目标「应用程序」文件夹：$DEST_APPS"
    echo "请确认另一台 Mac 已通过 USB-C 进入目标磁盘模式，并在「访达」里能看到其磁盘（/Volumes/xxx）。"
    echo "当前已挂载的卷："
    ls -1 /Volumes 2>/dev/null || true
    exit 1
  fi
  echo ""
  echo "=== 拷贝到另一台 Mac（$DEST_VOLUME）==="
  rm -rf "$DEST_APPS/$APP_NAME"
  cp -R "$DEPLOY_DIR/$APP_NAME" "$DEST_APPS/$APP_NAME"
  if [[ "$USE_DEV_ID" == "1" ]]; then
    echo "已复制到：$DEST_APPS/$APP_NAME（对方开机后可直接双击打开）"
  else
    echo "已复制到：$DEST_APPS/$APP_NAME（对方开机后需 xattr -cr 再右键打开）"
  fi
else
  echo ""
  echo "拷贝方式：AirDrop / USB-C 目标磁盘 等。"
  if [[ "$USE_DEV_ID" == "1" ]]; then
    echo "对方收到后可直接双击打开。若希望完全无提示可公证： NOTARIZE=1 ./deploy_to_other_mac.sh"
  else
    echo "对方 Mac 首次打开前：终端执行 xattr -cr \"/Applications/BOG Tool.app\"，再右键 BOG Tool.app →「打开」。"
  fi
fi
echo ""
