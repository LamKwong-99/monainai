# iOS 越狱源 (APT Flat Repository)

基于 GitHub Pages 托管的 iOS 越狱源（支持 Sileo / Zebra / Cydia），支持 GitHub Actions 自动化编译 Tweak 源码与重建 APT 索引。

自带一套自适应深浅色模式的现代化 Web 首页，访问根目录即可一键添加到 Sileo/Zebra，告别 404。

---

## 源内插件

### TimeSeconds 2.1.8 — 状态栏时间显示秒数（黄金比例平衡版：最美观、最实用）
- **包标识符**：`com.ajun.timeseconds`
- **支持架构**：`arm64` + `arm64e`
- **目标系统**：iOS 16+
- **兼容环境**：RootHide / Dopamine roothide、常规 rootless（Dopamine / palera1n）
- **特性**：
  - 状态栏时间从 `9:41` 变成 `9:41:07`，每秒精准物理对齐刷新。
  - **保持 100% 系统原生字号**，与系统状态栏原生字体大小完全一致。
  - 数字等宽排版 + 负字距收敛（`TS_KERN_RATIO = 0.05`），秒数跳动时不抖动、不溢出。
  - 自动保留 12/24 小时制与 AM/PM 后缀。
  - 源码位于 `tweaks/TimeSeconds/`。

---

## 目录结构

| 路径 | 作用 |
|---|---|
| `index.html` | 网页端首页（支持一键添加源到 Sileo/Zebra） |
| `debs/` | 存放打包好的 `.deb` 文件（支持多版本历史降级） |
| `tweaks/` | 插件完整 Theos 源码目录 |
| `Packages` / `.gz` / `.bz2` | APT 包索引文件（由 `build_repo.py` 生成） |
| `Release` | 源名称、支持架构声明 |
| `CydiaIcon.png` | 源图标（512×512） |
| `build_repo.py` | 本地与 CI 自动化索引构建脚本（跨平台哈希一致） |
| `.github/workflows/` | GitHub Actions 自动化构建与发版流水线 |
| `.nojekyll` | 阻止 GitHub Pages 过滤下划线文件 |

---

## 部署到你的 GitHub Pages 步骤

### 1. 在 GitHub 上新建仓库
进入 [GitHub New Repository](https://github.com/new)，新建一个 **Public** 仓库（例如仓库名填 `monainai` 或 `repo`）。

### 2. 推送代码到 GitHub
在本地终端执行（将 `LamKwong-99` 和 `monainai` 替换为你的 GitHub 用户名与仓库名）：

```bash
git add -A
git commit -m "init: iOS jailbreak repository"
git branch -M main
git remote add origin https://github.com/LamKwong-99/monainai.git
git push -u origin main
```

### 3. 启用 GitHub Pages
1. 打开该仓库的 **Settings** -> **Pages**。
2. **Build and deployment** -> **Source** 选择 `Deploy from a branch`。
3. 分支选择 `main`，目录选择 `/ (root)`，点击 **Save**。
4. 等待 1~2 分钟，即可获得你的专属源地址：
   `https://LamKwong-99.github.io/monainai/`
