# 版本与发布说明

## 当前分支情况

- **develop**：日常开发分支，当前唯一分支。
- **main**：尚未创建，建议作为「可发布版本」的稳定分支。

## 推荐分支与发布流程

### 1. 分支约定

| 分支     | 用途           | 说明                     |
|----------|----------------|--------------------------|
| **main** | 可发布版本     | 仅合并自 develop，打 tag |
| **develop** | 开发主分支 | 功能开发、修 bug 均在此 |

### 2. 发布一个版本（Release）的步骤

1. **在 develop 上收尾**
   - 确认测试通过、无已知严重 bug。
   - 如需，在 develop 上提交「chore: 准备发布 v1.0.x」并 bump 版本号（见下）。

2. **合并到 main 并打 tag**
   ```bash
   git checkout main          # 若已有 main；若没有见「首次创建 main」
   git merge develop --no-ff -m "Release v1.0.1"
   git tag -a v1.0.1 -m "Release v1.0.1"
   git push origin main
   git push origin v1.0.1
   ```

3. **版本号约定**
   - **用户可见版本**（`MARKETING_VERSION` / `CFBundleShortVersionString`）：如 `1.0.0`、`1.0.1`、`1.1.0`。
     - 修 bug / 小改动：第三位 +1（1.0.0 → 1.0.1）。
     - 新功能、不兼容改动：视情况升第二位或第一位（1.0.1 → 1.1.0 或 2.0.0）。
   - **构建号**（`CURRENT_PROJECT_VERSION` / `CFBundleVersion`）：每次对外发布 +1（1, 2, 3…），便于区分同一 1.0.1 的多次构建。

4. **修改版本号的位置**
   - Xcode：Target → BOG_TOOL → General → **Version**（如 1.0.1）、**Build**（如 2）。
   - 或直接改工程与 Info.plist：
     - `BOG_TOOL.xcodeproj/project.pbxproj`：`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`
     - `BOG_TOOL/Info.plist`：`CFBundleShortVersionString`、`CFBundleVersion`

### 3. 首次创建 main 分支（可选）

若希望从当前 develop 建立「可发布」主线：

```bash
git checkout -b main develop    # 从 develop 创建 main
git push -u origin main         # 推送到远端
```

之后日常在 **develop** 开发，只在准备发布时把 develop 合并到 main 并打 tag。

### 4. 简化方案（不建 main）

若暂时不区分 main/develop，可以只在 develop 上打 tag 做发布标记：

```bash
git tag -a v1.0.1 -m "Release v1.0.1"
git push origin v1.0.1
```

每次发布前在 develop 上 bump 版本号并打对应 tag 即可。

---

**当前工程版本**：`1.0.0`（Build 1），见 `BOG_TOOL/Info.plist` 与 `BOG_TOOL.xcodeproj/project.pbxproj`。
