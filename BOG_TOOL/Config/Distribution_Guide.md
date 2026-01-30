# BOG Tool — 在其他 Mac 上运行（无开发者账号）

---

## 还是无法运行时必做：拿到具体报错

**在打不开的那台 Mac 上**打开「终端」，执行下面这一行（若 app 在「应用程序」里；在桌面则把路径改成 `~/Desktop/BOG\ Tool.app/Contents/MacOS/BOG\ Tool`）：

```bash
"/Applications/BOG Tool.app/Contents/MacOS/BOG Tool"
```

**把终端里出现的整段英文/中文报错复制下来**，发给开发者。根据报错才能判断是：
- **Bad CPU type in executable** → 架构不对，需用「通用」包（见下文）
- **dyld / 库找不到** → 系统版本或依赖问题
- **其他崩溃信息** → 可据此改代码或环境

同时，**在你用来编译的 Mac 上**请按下面「发 app 前的固定流程」重新打一次包再发过去。

---

## 发 app 前的固定流程（你这台 Mac）

按顺序做，减少对方「无法打开」：

1. **用 Release、通用架构打包**  
   Xcode 选 **Product → Scheme → Edit Scheme**，左侧选 **Run**，**Info** 里 **Build Configuration** 选 **Release**（或直接选 **Product → Build**，顶部目的地选 **Any Mac (Apple Silicon, Intel)**）。然后 **Product → Build**，在 **Products** 里找到 **BOG Tool.app** 拖到桌面（或项目目录）。  
   （项目已配置 Release 同时打 arm64 + x86_64，这样 Intel 和 M 系列 Mac 都能用。）

2. **去掉签名再拷贝**  
   在终端执行（路径改成你电脑上 BOG Tool.app 的位置）：
   ```bash
   codesign --remove-signature "/path/to/BOG Tool.app"
   ```
   只把**去掉签名后的**这个 **BOG Tool.app** 拷给对方（U 盘/网盘等）。

3. **对方操作**  
   对方先执行 `xattr -cr "/Applications/BOG Tool.app"`（路径按实际），再**右键 BOG Tool → 打开**。

---

## 问题原因

在别的 Mac 上“无法打开”、或在「隐私与安全性」里点了“仍要打开”仍无效，通常是因为：

- **隔离属性 (quarantine)** — 通过 U 盘/网盘拷贝过去时，系统会加上安全标记，触发 Gatekeeper。
- **未公证** — 没有开发者账号就无法公证，系统对“来历不明”的 app 会拦得更严。

所以需要**在对方 Mac 上做一次解除隔离**，再配合**右键打开**，一般就能用。

---

## 推荐做法：对方 Mac 上操作一次（无需开发者账号）

适用于：内测、只给少数几台机器用。**在要用 BOG Tool 的那台 Mac 上**按下面做。

### 步骤 1：拷贝 app

把 **BOG Tool.app** 拷到对方 Mac，例如放到「应用程序」或桌面。

### 步骤 2：去掉隔离属性

1. 打开 **终端**（Spotlight 搜“终端”或 应用程序 → 实用工具 → 终端）。
2. 根据 app 所在位置，执行**其中一条**（路径可改成你的实际位置）：

若在「应用程序」文件夹：

```bash
xattr -cr "/Applications/BOG Tool.app"
```

若在桌面：

```bash
xattr -cr ~/Desktop/BOG\ Tool.app
```

若在下载文件夹：

```bash
xattr -cr ~/Downloads/BOG\ Tool.app
```

### 步骤 3：打开 app

- **不要双击**，先 **右键点击 BOG Tool.app** → 选 **「打开」**。
- 若弹出“无法验证开发者”之类的对话框，再点 **「打开」** 确认一次。
- 之后一般就可以正常双击打开了。

### 若仍提示“已损坏”或打不开

可再试只去掉 quarantine 属性：

```bash
xattr -d com.apple.quarantine "/Applications/BOG Tool.app"
```

（把 `/Applications/BOG Tool.app` 换成你的实际路径）

---

## 若只显示「无法打开」、没有任何弹窗

有时系统不会弹出「打开」或「隐私与安全性」选项，只提示「应用程序 BOG Tool 无法打开」。常见原因和办法如下。

### 办法 1：先看具体报错（对方 Mac 上）

在**对方 Mac** 打开终端，执行（路径按实际改）：

```bash
"/Applications/BOG Tool.app/Contents/MacOS/BOG Tool"
```

或：

```bash
open "/Applications/BOG Tool.app"
```

终端里会显示真正的错误，例如：
- **「Bad CPU type」** → 架构不匹配（见办法 2）
- **崩溃信息** → 对方系统版本或环境问题
- **无输出但弹窗** → 可能是权限/签名问题（见办法 3）

### 办法 2：确认架构一致（你这台 Mac 上）

- 你的 Mac 是 **M 系列（Apple Silicon）**，对方是 **Intel**（或反过来），就要打「通用」包。
- 在 Xcode：顶部选 **Any Mac (Apple Silicon, Intel)**，再 **Product → Archive**，用导出的 app 拷给对方。

### 办法 3：去掉开发签名再拷贝（你这台 Mac 上）

用开发证书打的包，在对方 Mac 上没有你的证书，系统可能直接拒绝、只显示「无法打开」且不给「打开」选项。

**在你这台 Mac**，拷贝给对方之前，先去掉签名：

1. 找到要发出去的 **BOG Tool.app**（例如在桌面或项目目录）。
2. 打开终端，进入 app 所在目录，执行：

```bash
codesign --remove-signature "BOG Tool.app"
```

3. 把**去掉签名之后**的 **BOG Tool.app** 再拷给对方。
4. 对方按前面步骤：终端执行 `xattr -cr "/Applications/BOG Tool.app"`，然后**右键 → 打开**。

这样对方 Mac 不会再去校验「不存在的开发证书」，有机会正常打开。

---

## 给对方的简短说明（可复制转发）

你可以把下面这段直接发给对方，让对方在自己 Mac 上执行：

---

**第一次在这台 Mac 上打开 BOG Tool 前，请先做下面两步：**

1. 打开 **终端**（在「应用程序」→「实用工具」里，或用 Spotlight 搜索“终端”）。
2. 输入下面这行（如果 BOG Tool.app 在「应用程序」里的话），按回车：

```bash
xattr -cr "/Applications/BOG Tool.app"
```

3. 然后 **右键点击 BOG Tool**，选 **「打开」**；如有弹窗再点一次「打开」即可。之后就可以正常使用了。

**若仍然只显示「无法打开」、没有任何其他提示**：请对方在终端执行  
`"/Applications/BOG Tool.app/Contents/MacOS/BOG Tool"`（路径按实际改），把终端里出现的报错发给你；同时你在发 app 前可先去掉签名再拷（见上文「办法 3」）。

---

## 小结

| 你需要的           | 对方 Mac 要做的                          |
|--------------------|------------------------------------------|
| 无开发者账号       | 终端执行 `xattr -cr "…BOG Tool.app"`，再右键 → 打开 |

这样无需付费开发者账号，在对方机器上操作一次即可正常使用。

---

## 如果以后有开发者账号（可选）

若以后开通了 Apple Developer（约 $99/年），可以：

1. 用 **Developer ID Application** 证书签名；
2. 提交 Apple **公证**；
3. 公证通过后，其他 Mac 拿到 app 可直接双击打开，无需再在对方电脑上执行 `xattr` 或右键打开。

具体步骤可参考 Apple 官方文档：[Signing your apps for Gatekeeper](https://developer.apple.com/developer-id/)。
