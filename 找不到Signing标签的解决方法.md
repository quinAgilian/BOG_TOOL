# 找不到 Signing & Capabilities 标签？看这里！

## 🎯 最简单的查找方法

### 方法 1：按顺序操作（推荐）

```
步骤 1: 在 Xcode 左侧找到蓝色图标
        ┌─────────────┐
        │ 📘 BOG_TOOL │ ← 单击这里（蓝色图标）
        ├─────────────┤
        │ 📁 BOG_TOOL │
        │ 📁 Views    │
        │ ...         │
        └─────────────┘

步骤 2: 中间区域会显示设置
        ┌─────────────────────────────┐
        │ PROJECT                      │
        │   BOG_TOOL                   │
        │                              │
        │ TARGETS                      │ ← 看这里
        │   BOG_TOOL                   │ ← 单击这里！
        │                              │
        └─────────────────────────────┘

步骤 3: 顶部出现标签页
        ┌─────────────────────────────┐
        │ [General] [Signing & ...]   │ ← 点击这个标签
        └─────────────────────────────┘
```

### 方法 2：使用快捷键

1. 按 `Command + 1` 显示左侧导航栏
2. 按 `Command + 0` 显示右侧面板（如果需要）
3. 在左侧找到蓝色图标，单击它
4. 在中间区域找到 TARGETS > BOG_TOOL，单击它
5. 看顶部标签，找到 "Signing & Capabilities"

### 方法 3：通过菜单

1. 菜单栏：**View > Navigators > Show Project Navigator** (`Command + 1`)
2. 在左侧导航栏找到项目文件（蓝色图标）
3. 单击它
4. 菜单栏：**View > Inspectors > Show File Inspector**（如果需要）

## 🔍 详细位置说明

### 左侧导航栏（Project Navigator）

如果你看不到左侧导航栏：
- 菜单栏：**View > Navigators > Show Project Navigator**
- 或按快捷键：`Command + 1`

在左侧导航栏中：
- **最顶部** = 项目文件（蓝色图标，名字是 BOG_TOOL）
- **下面** = 项目文件夹和文件

### 中间区域（Editor Area）

当你单击项目文件后，中间区域会显示：
- **PROJECT** 部分（项目级别设置）
- **TARGETS** 部分（应用级别设置）← **你需要这个！**
- **TEST TARGETS** 部分（测试相关）

### 顶部标签页（Tab Bar）

选择 TARGETS 下的 BOG_TOOL 后，顶部会出现：
- **General** - 基本信息
- **Signing & Capabilities** ← **这个！**
- **Build Settings** - 构建设置
- **Build Phases** - 构建阶段
- **Build Rules** - 构建规则
- **Info** - 信息

## 📸 如果界面看起来不一样

### Xcode 版本差异：

**Xcode 11+**：
- 标签显示为：**Signing & Capabilities**

**Xcode 10 及更早**：
- 标签显示为：**Signing**
- 或者只在 **Build Settings** 中

**如果只有 Build Settings**：
1. 点击 **Build Settings** 标签
2. 在右上角搜索框输入：`signing`
3. 找到 **Code Signing Identity** 和 **Development Team**
4. 在 **Development Team** 中选择你的团队

## ✅ 检查清单

在开始之前，确认：

- [ ] Xcode 已打开
- [ ] 项目已打开（BOG_TOOL.xcodeproj）
- [ ] 左侧导航栏可见（如果看不到，按 `Command + 1`）
- [ ] 能看到项目文件（蓝色图标）
- [ ] 已单击项目文件（中间区域有内容显示）
- [ ] 能看到 TARGETS 部分
- [ ] 已单击 TARGETS 下的 BOG_TOOL

## 🆘 如果还是找不到

### 可能的原因：

1. **Xcode 版本太旧**
   - 检查：菜单栏 > Xcode > About Xcode
   - 建议：更新到最新版本

2. **项目文件损坏**
   - 尝试：关闭 Xcode，重新打开项目

3. **界面布局被改变**
   - 尝试：菜单栏 > View > Standard Editor > Show Standard Editor
   - 或：菜单栏 > Window > Reset Editor Layout

4. **在看错误的地方**
   - 确保：点击的是**项目文件**（蓝色图标），不是文件夹
   - 确保：选择的是 **TARGETS** 下的，不是 PROJECT 下的

## 💡 替代方案：直接告诉我你的情况

如果你还是找不到，请告诉我：

1. **你的 Xcode 版本**：
   - 菜单栏：Xcode > About Xcode
   - 告诉我版本号

2. **当你点击项目文件后，中间区域显示什么？**
   - 有没有看到 TARGETS？
   - 有没有看到 BOG_TOOL？

3. **顶部有哪些标签？**
   - 列出所有标签名称

4. **截图**（如果有的话）

我可以根据你的具体情况提供更精确的指导！

## 🎯 快速测试

试试这个：
1. 在 Xcode 中按 `Command + B` 构建项目
2. 如果构建成功，说明项目配置正常
3. 如果构建失败，错误信息会告诉你需要设置什么
4. 通常错误信息会包含 "Signing" 或 "Team" 相关的内容
