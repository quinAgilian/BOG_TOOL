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
   - **用户可见版本**（`CFBundleShortVersionString`）：如 `1.0.0`、`1.0.1`、`1.1.0`。
     - 修 bug / 小改动：第三位 +1（1.0.0 → 1.0.1）。
     - 新功能、不兼容改动：视情况升第二位或第一位（1.0.1 → 1.1.0 或 2.0.0）。
   - **构建号**（`CFBundleVersion`）：由构建脚本自动填入，为当前 Git 提交数（`git rev-list --count HEAD`），同一 commit 多次构建结果一致。

4. **自动版本管理（推荐）**
   - 每次构建前，Run Script 阶段会执行 `scripts/update_version.sh`，将版本写入 `BOG_TOOL/Info.plist`。
   - **只需维护一个文件**：仓库根目录的 **`VERSION`**（一行，如 `1.0.0`）。发布新版本时改这一处即可。
   - Build 号自动取当前仓库的 Git 提交数，无需手动改。
   - 若没有 `VERSION` 文件或不在 Git 仓库中构建，则回退为版本 `1.0.0`、Build `1`。
   - **构建后**：Run Script 会改写 `BOG_TOOL/Info.plist` 的版本与 Build 号，所以 `git status` 可能显示 Info.plist 已修改。这是预期行为，可忽略或执行 `git restore BOG_TOOL/Info.plist` 丢弃该修改，无需提交。
   - 如需手动改（不推荐）：可改 `BOG_TOOL/Info.plist` 与 `project.pbxproj` 中的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，但下次构建会被脚本再次覆盖 Info.plist。

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

### 5. 发布 1.0.2 并同步到 main（推荐步骤）

若已有 main，用「合并」把 develop 的改动同步到 main；若还没有 main，可先从 develop 建 main 再打 tag。

**步骤一：在 develop 上收尾并打版本号**

```bash
# 确保在 develop
git checkout develop
# 已把 VERSION 改为 1.0.2 后，提交
git add VERSION
git add -A
git commit -m "chore: 准备发布 v1.0.2"
git push origin develop
```

**步骤二：同步到 main 并打 tag**

- **情况 A：还没有 main 分支**（首次建 main，相当于把当前 develop 当作 1.0.2 发布）

```bash
git checkout -b main develop
git push -u origin main
git tag -a v1.0.2 -m "Release v1.0.2"
git push origin v1.0.2
```

- **情况 B：已有 main 分支**（把 develop 合并进 main，再打 tag）

```bash
git checkout main
git pull origin main
git merge develop --no-ff -m "Release v1.0.2"
git tag -a v1.0.2 -m "Release v1.0.2"
git push origin main
git push origin v1.0.2
```

之后继续在 **develop** 上开发，下次发布（如 1.0.3）再重复「步骤一 + 步骤二 情况 B」。

---

**当前工程版本**：由根目录 `VERSION` 文件决定（当前为 `1.0.2`）；Build 号由构建时 Git 提交数自动注入。
