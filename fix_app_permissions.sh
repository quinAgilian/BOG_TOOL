#!/bin/bash

# 修复应用权限的脚本
# 使用方法: ./fix_app_permissions.sh "/path/to/BOG Tool.app"

APP_PATH="$1"

if [ -z "$APP_PATH" ]; then
    echo "使用方法: $0 \"/path/to/BOG Tool.app\""
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "错误: 找不到应用: $APP_PATH"
    exit 1
fi

echo "正在修复应用权限..."

# 1. 移除隔离属性（如果存在）
echo "1. 移除隔离属性..."
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "   ✓ 隔离属性已移除"
else
    echo "   ℹ 没有隔离属性（正常）"
fi

# 2. 检查代码签名
echo "2. 检查代码签名..."
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep -E "(Authority|Signature|valid)" || echo "   ⚠ 应用可能未签名"

# 3. 验证签名
echo "3. 验证签名..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1
if [ $? -eq 0 ]; then
    echo "   ✓ 签名验证通过"
else
    echo "   ⚠ 签名验证失败，可能需要重新签名"
fi

# 4. 检查 Gatekeeper
echo "4. 检查 Gatekeeper 状态..."
spctl --assess --verbose "$APP_PATH" 2>&1 | head -5

echo ""
echo "完成！如果仍有问题，请尝试："
echo "1. 在 Xcode 中重新构建应用（Product > Clean Build Folder，然后 Product > Build）"
echo "2. 在 Xcode 中设置开发团队（Signing & Capabilities > Team）"
echo "3. 在系统设置 > 隐私与安全性 中允许应用运行"
