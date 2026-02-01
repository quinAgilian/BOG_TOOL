# 如何找到 Signing & Capabilities 设置 - 详细步骤

## 📍 第一步：找到项目设置

### 方法 1：通过左侧导航栏（最常用）

1. **打开 Xcode**
2. **打开你的项目**（BOG_TOOL.xcodeproj）
3. 看**左侧导航栏**（Project Navigator）
4. 找到**最顶部**的蓝色图标，名字是 **BOG_TOOL**（这就是项目文件）
5. **单击**这个蓝色图标（不是双击，是单击）

### 方法 2：如果左侧导航栏被隐藏了

1. 菜单栏：**View > Navigators > Show Project Navigator**（或按 `Command + 1`）
2. 左侧导航栏会出现
3. 找到最顶部的蓝色 **BOG_TOOL** 图标
4. **单击**它

## 📍 第二步：选择 Target

当你单击了项目文件（蓝色图标）后，**中间区域**会显示项目设置：

```
┌─────────────────────────────────────────┐
│  BOG_TOOL                              │ ← 项目名称（顶部）
├─────────────────────────────────────────┤
│  PROJECT                                │
│    BOG_TOOL                             │
│                                         │
│  TARGETS                                │ ← 看这里！
│    BOG_TOOL                             │ ← 点击这个！
│                                         │
│  TEST TARGETS                           │
│    ...                                  │
└─────────────────────────────────────────┘
```

1. 在中间区域，找到 **TARGETS** 这个标题
2. 在 TARGETS 下面，找到 **BOG_TOOL**（只有一个）
3. **单击 BOG_TOOL**（不是项目文件，是 TARGETS 下面的）

## 📍 第三步：找到 Signing & Capabilities 标签

当你选择了 **BOG_TOOL** target 后，**顶部**会出现几个标签页：

```
┌─────────────────────────────────────────┐
│  [General] [Signing & Capabilities] ... │ ← 看顶部这些标签！
└─────────────────────────────────────────┘
```

### 不同版本的 Xcode 可能显示为：

- ✅ **Signing & Capabilities**（Xcode 11+）
- ✅ **Signing**（旧版本）
- ✅ **Build Settings**（如果没看到，先看这里，然后找 Signing）

### 如果还是找不到：

1. 看看顶部有没有这些标签：
   - General
   - **Signing & Capabilities** ← 这个！
   - Build Settings
   - Build Phases
   - Build Rules
   - Info

2. 如果看到 **Build Settings**：
   - 点击 **Build Settings**
   - 在搜索框输入 "signing"
   - 找到 **Code Signing Identity** 和 **Development Team**

## 📍 第四步：设置团队

找到 **Signing & Capabilities** 标签后，点击它，你会看到：

```
┌─────────────────────────────────────────┐
│  Signing                                │
│  ☑ Automatically manage signing        │ ← 确保这个勾选了
│                                         │
│  Team: [下拉菜单 ▼]                     │ ← 点击这里选择你的团队
│                                         │
│  Bundle Identifier: com.agiliantech...  │
│                                         │
│  Signing Certificate: ...               │
└─────────────────────────────────────────┘
```

### 操作步骤：

1. ✅ 确保 **Automatically manage signing** 已勾选
2. 点击 **Team** 旁边的下拉菜单
3. 选择你的名字（Personal Team）
   - 如果显示 "None" 或没有选项，说明还没登录 Apple ID
   - 回到第一步：Xcode > Settings > Accounts 登录

## 🔍 如果完全找不到这些选项

### 检查清单：

- [ ] 是否打开了正确的文件？
  - ✅ 应该打开 `.xcodeproj` 文件（蓝色图标）
  - ❌ 不是 `.swift` 文件或其他文件

- [ ] 是否单击了项目文件（蓝色图标）？
  - ✅ 左侧导航栏最顶部的蓝色图标
  - ❌ 不是文件夹或其他文件

- [ ] 是否选择了 TARGETS 下的 BOG_TOOL？
  - ✅ 中间区域 TARGETS 下面的 BOG_TOOL
  - ❌ 不是 PROJECT 下面的

- [ ] Xcode 版本是否太旧？
  - 如果 Xcode 版本 < 11，可能显示为 "Signing" 而不是 "Signing & Capabilities"
  - 建议更新到最新版本

## 🎯 替代方法：通过 Build Settings

如果实在找不到 Signing & Capabilities 标签：

1. 选择项目文件（蓝色图标）
2. 选择 **BOG_TOOL** target
3. 点击 **Build Settings** 标签
4. 在右上角的搜索框输入：`signing`
5. 找到以下设置：
   - **Code Signing Identity**
   - **Development Team** ← 在这里设置你的团队
   - **Code Signing Style** ← 应该是 "Automatic"

## 📸 视觉指引

### 正确的操作顺序：

```
1. 左侧导航栏
   └─ 📘 BOG_TOOL (蓝色图标) ← 单击这里
   
2. 中间区域
   └─ TARGETS
      └─ BOG_TOOL ← 单击这里
      
3. 顶部标签
   └─ [Signing & Capabilities] ← 单击这里
   
4. 设置区域
   └─ Team: [选择你的名字] ← 设置这里
```

## ❓ 常见问题

### Q: 我点击了项目文件，但中间区域是空的？
**A:** 确保你点击的是**蓝色图标**的项目文件，不是文件夹。如果还是空的，尝试关闭并重新打开项目。

### Q: 我看到了 TARGETS，但下面没有 BOG_TOOL？
**A:** 可能项目配置有问题。尝试：
1. 关闭 Xcode
2. 删除 `~/Library/Developer/Xcode/DerivedData` 中的项目缓存
3. 重新打开项目

### Q: 我看到了 Signing，但 Team 下拉菜单是空的？
**A:** 说明还没登录 Apple ID。先执行：
1. Xcode > Settings > Accounts
2. 添加你的 Apple ID
3. 然后回到项目设置，Team 下拉菜单就会有选项了

### Q: 我的 Xcode 界面看起来不一样？
**A:** 不同版本的 Xcode 界面可能略有不同，但基本位置是一样的：
- 左侧导航栏的项目文件
- 中间区域的 TARGETS
- 顶部的标签页

## 🆘 如果还是找不到

请告诉我：
1. 你的 Xcode 版本（菜单栏：Xcode > About Xcode）
2. 当你点击项目文件后，中间区域显示什么？
3. 顶部有哪些标签页？

我可以根据你的具体情况提供更精确的指导！
