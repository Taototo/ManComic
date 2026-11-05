# ManComic

[![flutter](https://img.shields.io/badge/flutter-3.47.4-blue)](https://flutter.dev/)
[![platform](https://img.shields.io/badge/platform-Android-3ddc84)](https://www.android.com/)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](https://github.com/Taototo/ManComic/blob/main/LICENSE)
[![version](https://img.shields.io/github/v/release/Taototo/ManComic)](https://github.com/Taototo/ManComic/releases)

一个支持本地与网络漫画源的 Android 漫画阅读器，基于开源项目 **Venera** 深度定制。

> 本仓库是个人维护的分支版本，与上游项目**没有隶属关系**，也不代表原作者的观点或立场。
> 上游功能问题请勿反馈到上游仓库。

---

## 一、项目来源

| 项目 | 信息 |
| --- | --- |
| 上游项目 | **Venera** |
| 上游地址 | https://github.com/venera-app/venera |
| 上游组织 | [venera-app](https://github.com/venera-app) |
| 上游状态 | **已归档 / 停止维护**（作者精力有限，欢迎 fork，见上游 README 顶部说明） |
| 上游许可证 | GPL-3.0 |
| 上游热度 | 约 11.3k stars、676 forks（截至 2026-11） |
| 上游技术栈 | Flutter + Dart，JavaScript 编写漫画源，flutter_qjs 作为 JS 引擎 |
| 本分支起点 | 基于上游 **1.6.3** 版本的代码 |
| 本分支仓库 | https://github.com/Taototo/ManComic |
| 本分支版本 | 1.4.10（本分支独立编号，与上游版本号无对应关系） |

**为什么会有这个分支**：上游已停止维护，但漫画源生态与 Android 端体验仍有大量可改进空间。本分支在其坚实的基础上做了平台精简、界面重做、阅读器增强，以及一系列围绕「追更、找源、统计」的功能补全。

### 与上游的兼容性说明

- 包名保持 `com.github.wgh136.venera` 不变，数据目录与上游一致（便于沿用既有配置与漫画源）。
- 但**签名证书已更换**，因此无法直接覆盖安装官方 Venera 版本，从官方版迁移需先卸载（会丢失应用内数据，请提前备份）。
- 本分支**仅支持 Android**：iOS / macOS / Linux / Windows / Debian 平台代码与打包配置已移除。

---

## 二、本分支的更新内容

### 1. 平台与工程

- 移除全部非 Android 平台工程与依赖（ios / macos / linux / windows / debian / fastlane 等），仓库大幅瘦身。
- 更换为自有签名证书；版本号体系为 `1.4.10+280`，`versionCode = N × 10`，保证每次升级可覆盖安装。
- 只产出**通用 APK**（不再分架构打包）。
- 补全 Rust 构建链（`librhttp.so` 三架构），修复因缺失 native 库导致「所有网络请求失败」的问题。
- 修复 `dio` 层对畸形 `Content-Type` 的解析容错，单响应上限 50MB；JS 引擎增加 URL 过滤与超大 HTML 截断容错，避免个别源拖死整页。

### 2. 界面与交互

- **液态玻璃视觉体系**：自研 `LiquidGlass` / `GlassSurface`（背景模糊 + 饱和度提升 + 镜面高光 + 渐变描边 + 双层投影），统一应用于顶栏、漂浮胶囊底栏、阅读器工具栏、长按菜单、设置弹层。
- **毛玻璃可调**：设置 → 外观中提供模糊度、不透明度两个滑块与实时预览。
- **浮动底栏**：底栏改为漂浮胶囊，切换时药丸滑动 + 横向拉伸回弹 + 图标放大动效。
- **导航精简**：底栏 4 项精简为 3 项（首页 / 推荐 / 收藏），分类并入推荐页，用分段胶囊在「推荐 / 分类」间切换；再次点击页签回到顶部。
- **5 套应用图标**可在设置内即时切换（基于 `activity-alias`，后台安全切换，重启生效）。
- **Lottie 翻书启动页**。
- **首页模块可自定义**：7 个模块（继续阅读、同步数据、历史、追更、漫画源、本地、图片收藏）可自由排序与开关。
- 首页新增**继续阅读卡片**，直达上次阅读的章节与页码。
- 图片收藏在首页改为**可长按上下滑动的卡片堆**，直接复用收藏页条目卡样式。
- 封面**长按弹出 Peek 预览**（封面、标题、标签、简介、直达详情）。
- 推荐页缩略图新增**最近更新时间角标**（今天 / 昨天 / N 天前）。
- 全局加载动画统一为五点动画；页面切换、顶栏标题均带过渡动画。

### 3. 阅读器

- **长按 HUD 快捷面板**：亮度、阅读模式、章节列表、收藏本页、设置、锁定；可切换长按行为（HUD / 放大图片）。
- **亮度调节**改为控制窗口亮度（绝对亮度，不干扰系统自动亮度），退出阅读页自动交还系统。
- **护眼暖色滤镜**，支持「仅夜间（20:00–07:00）」自动生效。
- **条漫自动裁边**：按强度（关 / 保守 / 标准 / 激进）裁掉上下纯色留白，不复制位图、不额外占内存。
- **翻章手感优化**：切换阈值 160 → 56，新增「甩动切章」（在内容尽头快速滑动即切章）。
- 页码胶囊与时钟在滚动时淡出、停止时淡入；末页增加底部留白，避免被页码与时钟压住。
- 翻页 / 双击 / 长按触觉反馈；工具栏收起使用自身高度位移，彻底解决「底栏露边」。

### 4. 收藏与整理

- **收藏隐私锁**：开启后进入收藏页为雾面遮罩，点按解锁时播放「雾消散」动画；进程重启自动重新上锁。
- **智能书架**：按标签规则自动聚合书籍，标签可视化编辑。
- **拼音 / 首字母搜索**：中文子串、全拼、首字母三种匹配。
- **名称首字母排序**（本地收藏），支持 A-Z / Z-A。
- 收藏页顶栏新增多选入口，长按封面改为直接「在其他漫画源搜索」。

### 5. 漫画源

- **多源绑定 + 自动故障转移**：为作品绑定备用源，主源失效时自动跳转并按**章节序号对齐**阅读进度。
- **跨源同名搜索**：并发 3 路搜索全部已启用源，按标题归一化打分排序，结果可直接绑定为备用源。
- **漫画源体检**：并发探测每个源的搜索可用性，标注「可用 / 无结果 / 失败 / 不支持搜索」与耗时，便于清理失效源。
- **聚合搜索按作品合并**：跨源结果按标题聚类，一个作品只需选一次源。
- 内置**漫画源编写帮助页**，不再跳转外部链接。
- 不再内置任何漫画源列表，默认不预填源地址，由用户自行添加。

### 6. 数据与统计

- **年度阅读报告**：总时长、阅读天数、最长连续、作品数、源分布、月度柱状图、深夜阅读占比，可分享文本。
- **周报 + 7×24 热力图**，含与上周的环比。
- **阅读成就系统**：14 个成就徽章（时长、连读、天数、作品数、夜猫子、图库等），解锁即时提示。
- **追更通知**：WorkManager 每 6 小时后台检查（带联网约束）+ 本地通知，前台默认不打扰。
- 日志页支持一键分享（超长日志自动改为分享文件）。

---

## 三、原有功能（继承自上游）

- 阅读本地漫画（压缩包 / 文件夹，支持 7z、zip 等）
- 使用 JavaScript 编写自定义漫画源
- 从网络源在线阅读、搜索、排行榜
- 收藏管理、下载管理、阅读历史
- 章节评论、标签、评分等（源支持时）
- 登录、评论、评分等交互（源支持时）
- WebDAV / 云同步配置

---

## 四、下载

在 [Releases](https://github.com/Taototo/ManComic/releases) 页面下载最新的 `ManComic-<版本号>.apk`（通用包，适配全部 ABI）。

> 从官方 Venera 迁移：因签名不同，需先卸载官方版再安装本版本。

---

## 五、从源码构建

1. 克隆本仓库
2. 安装 Flutter（见 [flutter.dev](https://flutter.dev/docs/get-started/install)），版本 3.47.4
3. 安装 Rust（见 [rustup.rs](https://rustup.rs/)），用于编译 `rhttp` 的 native 库
4. Android 构建还需：Android SDK、NDK、JDK 17、Visual Studio Build Tools（Windows 下编译 Rust 依赖）
5. 配置签名：在 `android/` 下放置 `key.properties` 与 keystore（本仓库不包含签名文件）
6. 构建：

```bash
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

> 首次构建会在 `~/.gradle` 与 `target/` 产生大量缓存，建议预留 5GB 以上空间。

### 自动发版

推送 `v<版本号>` 形式的 tag（如 `git tag v1.4.2 && git push origin v1.4.2`）会触发 `.github/workflows/release.yml`：

1. 校验 `pubspec.yaml`、`android/app/build.gradle`、`lib/foundation/consts.dart` 三处版本号与 tag 完全一致，不一致直接失败（避免发出「版本对了但包不对」的安装包）
2. 构建通用 APK，`aapt` 校验包内 versionCode，自动创建 Release 并把 APK 挂为资产

首次使用需在仓库 Settings → Secrets 中配置：

| Secret | 内容 |
| --- | --- |
| `KEYSTORE_BASE64` | keystore 文件的 base64（`base64 -w0 ManComi.jks`） |
| `KEYSTORE_PASSWORD` | keystore 口令 |
| `KEY_PASSWORD` | key 口令 |
| `KEY_ALIAS` | key 别名 |

Release 发布后，已安装用户点「检查更新」即可直接下载安装。

---

## 六、编写漫画源

本项目**不内置、也不分发任何漫画源列表**。所有漫画源均需由用户自行编写或添加，以规避第三方内容带来的版权与合规风险。

- 编写教程：[doc/comic_source.md](doc/comic_source.md)
- JS API：[doc/js_api.md](doc/js_api.md)
- 无头模式：[doc/headless_doc.md](doc/headless_doc.md)
- 漫画导入：[doc/import_comic.md](doc/import_comic.md)

在应用内「设置 → 漫画源」中可手动填写你自己的源列表地址，或按上述教程编写并加载单个源。

---

## 七、致谢

- **[Venera](https://github.com/venera-app/venera)** —— 本项目的全部基础，感谢上游作者与贡献者。若无 Venera，本项目无从谈起。
- **[EhTagTranslation](https://github.com/EhTagTranslation/Database)** —— 漫画标签的中文翻译来源。
- **[flutter_qjs](https://github.com/wgh136/flutter_qjs)**、**[rhttp](https://github.com/TakWolf/rhttp)** 等所有上游依赖的作者。
- 图标设计参考了 Finch、Neko Atsume 一类的扁平可爱风格。

---

## 八、许可证

本项目沿用上游的 **GPL-3.0** 许可证，详见 [LICENSE](LICENSE)。

依据 GPL-3.0：
- 你可以自由使用、修改、分发本项目；
- 分发修改后的版本时，必须同样以 GPL-3.0 开源，并保留原作者的版权声明；
- 本软件不提供任何担保。

**免责声明**：本项目仅作为漫画阅读工具，不提供、不存储、不分发任何漫画内容。所有内容均来自用户自行添加的第三方漫画源，使用者需自行承担相应的合规责任。请支持正版。
