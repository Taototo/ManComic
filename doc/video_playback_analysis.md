# ManComi 接入「视频播放」可行性分析

> 分析对象：`E:\viio\viiopop\analysis_wksp`（apktool 反编译产物，源 APK `wksp.apk` 81MB）
> 分析目标项目：`E:\viio\venera\venera-ManComi`（Venera 系漫画阅读器，140 个 Dart 文件）
> 本文只做分析，未改动任何代码。

---

## 0. 摘要

**结论：可以整合，而且 ManComi 侧改造成本比预想低。** 关键原因是 Venera 的章节数据链路只有一层接口
`loadEp(comicId, epId) -> { images: [...] }`，把返回结构向后兼容地扩成 `{ images, media }` 后，
"视频章节"就能复用已有的漫画详情页、章节列表、历史、收藏、评论，只在"打开章节"这一步分流到播放页。

真正的工作量不在"能不能播"，而在四件事：

1. **播放内核选型**（不能用目标 App 的实现：本 APK 里没有 libvlc 原生库，且 targetSdk 36 要求 16KB 页对齐）；
2. **m3u8 + 防盗链**：必须有本地 HTTP 代理重写播放列表，否则 Referer/UA 校验直接 403；
3. **播放器 UI 层**（手势、倍速、选集、续播、画中画）—— 这部分反而可以直接照搬它的设计思路；
4. **数据模型与进度记忆**（现有 History 存的是页码，视频要存秒）。

目标 App 的"配置驱动多源 + 解析接口 + 登录/VIP/广告/积分"属于它的业务壳，**不应搬**（技术上有价值，合规上有风险）。

---

## 1. 目标 App 是什么

| 项 | 值 |
| --- | --- |
| 版本 | 1.6.2 / 1.6.3（`versionCode` 100062） |
| 包名 | `com.tencent.tmgp.cn.jj.chess2.hd.sh`（伪装成腾讯天天象棋的壳名，典型马甲包） |
| 技术栈 | Flutter（`libflutter.so` + AOT `libapp.so` 13MB），Dart 包名为 `niuniu_video` |
| 体积 | 81MB，两套 ABI（arm64-v8a / armeabi-v7a），32 个 `.so` |
| 定位 | "悟空视频"，聚合影视 App：多源影视 + 弹幕 + 下载 + 投屏 + 短剧 + 会员体系 |

它的 Dart 代码做了 AOT 编译（`libapp.so`），但类名、文件路径、方法名、字符串常量都保留着，
可以直接从字符串表还原出**完整模块结构和功能清单**——这也是本次分析的主要依据。

---

## 2. 它的播放体系是怎么做的

### 2.1 分层结构

```
配置层 (assets/default_config.json 下发 src1..src12 / parser / ad / 会员)
   │
数据层 (data/api: api_client + 12 个 interceptor：解密、域名替换、加密签名、过期、关站)
   │
解析层 (player/parse: parser_factory + 7 个 parser)      ← 把"页面/接口数据"变成可播 URL
   │
代理层 (server/local_proxy_server.dart)                  ← 关键：给播放器补 headers、重写 m3u8
   │
内核层 (widgets/niuniu_player.dart: NiuniuPlayerController)
   │
UI 层  (widgets/player/* ≈ 24 个文件: 手势/控件/进度条/错误态/迷你窗/DLNA)
   │
周边   (pip_player_page · danmaku_manager · downloader · database)
```

### 2.2 数据源：配置驱动的 12 个"源"

`default_config.json` 里 `src1`～`src12` 是两族完全不同的源：

- **A 族（src1 / src2 / src7）：加密 API 源**
  字段：`tokenUrl / listUrl / detailUrl / headers(key,version,app_id,channel_code…) / playerHeaders /
  iv / key / salt / replaceDomain / replaceEncryptDomain / verificationUrl`
  走 DESede 加解密 + 初始化 token + 域名动态替换，配 `auth_session_manager`、`get_domains_decrypt_interceptor`
  等拦截器。这是"签了合作"的正版/半正版接口，**对 ManComi 没意义**。
- **B 族（src3~6、8~12）：苹果 CMS（maccms）风格 m3u8 源**
  字段极简：`eUrl / sUrl / yUrl / mMp4 / hSubstr / qSubstr`
  即"详情接口 + 播放接口 + 解析接口 + 兜底 mp4 + 清晰度截取规则"。
  **这一族才是有技术参考价值的部分**：说明这类 App 的播放清单最终都是 **m3u8（HLS）**。

另外配置里有 `parser`（43 条）—— 第三方"解析接口"（`jx.php?url=%s` 这类），
用于把爱奇艺/腾讯等页面地址转成直链，属灰色地带，同样不建议引入。

### 2.3 解析层：7 个 Parser

`parser_factory` + `normal / niuniu / hema / ningmeng / src2 / xiaocao / special`。
职责统一：输入 `(源类型, 剧集数据, headers)`，输出 `VideoPlayerResource`（url + headers + 清晰度列表）。
ManComi 若要做"视频源"，这层等价于"把 JS 源返回的页面 URL 变成 m3u8 直链"，**但它属于源作者的逻辑，不该写在 App 里**。

### 2.4 代理层：整个方案里最值钱的一段

字符串里能确证这些实现：

- 本地起 HTTP 服务，路径 `/proxy/video`、`/proxy/video.`、`/proxy/health`；
- `_processM3U8Content`、`_parseM3U8Lines`、`_proxyHlsMediaUrl`、`_proxyTsUrl`、`_logModifiedM3U8ProxySummary`
  → **取到 m3u8 后把里面的分片地址全部改写成自己代理地址，再喂给播放器**；
- `_proxyHlsMediaUrl` 说明对多级 m3u8（master → media）也做了递归处理；
- 另有 `/proxy/health` 做健康检查（播放失败时判断代理是否还活着）；
- `LocalDlnaProxyServer` 是投屏用的第二个代理。

**为什么必须这么做：** ExoPlayer / VLC 都只能对"入口 URL"加 headers，m3u8 里相对路径分片、
key 地址、跨域分片很容易丢 Referer 或返回 302 → 403。本地代理是这类"防盗链影视源"的唯一稳妥解法。

**ManComi 现状：没有 `HttpServer`**（全仓库 grep 无结果），图片是每张单独带 headers 用 dio 取。
→ 接视频必须新增一个本地代理模块，这是最硬的一块新增代码。

### 2.5 播放内核

Dart 层两套都编进去了：

- `VlcPlayerController.network` / `_buildVlcPlayerView` / `VlcPlayerOptions` / `HardwareAccelerationSwitch`
  （`--network-caching=1000`、`--http-reconnect`、`--no-drop-late-frames` 等参数可见）；
- `video_player`（`dev.flutter.pigeon.video_player_android.*`、`flutter.io/videoPlayer/videoEvents`）。

但**本 APK 的 `lib/` 里没有任何 `libvlc*.so`**，`GeneratedPluginRegistrant` 里也没注册 VLC 插件。
→ 该发布包中 VLC 路径实际不可用（大概率是历史遗留代码 / 特定渠道裁剪），**真正生效的是 ExoPlayer(Media3)**，
另外 `libttmplayer_lite.so`（字节播放器）是给激励视频广告用的。

**这个发现很重要**：不要假设"照着它用 VLC 就行"，内核必须按 ManComi 自己的约束重新选型。

### 2.6 播放页能力清单（可作为 ManComi 的功能参考表）

| 分类 | 能力 | 实现线索 |
| --- | --- | --- |
| 内核 | 硬解/软解切换、缓冲策略、网络失败重试 | `hardware_acceleration_switch`、`player_buffering_hint`、`player_network_fail_widget` |
| 手势 | 左右滑进度、上下滑亮度/音量、双击、长按倍速 | `player_gesture_detector`、`brightness_controller`、`volume_controller`、`long_press_speed_controller` |
| 控件 | 竖屏/横屏两套顶栏底栏、锁屏、迷你窗、电池图标 | `vertical_*` / `horizontal_*` / `default_*` controls |
| 播放 | 倍速、自动连播、片头片尾跳过（按视频记忆）、定时关闭 | `speed_sheet`、`skip_intro_slider`、`video_skip_setting` 表、`auto_exit_manager` |
| 选集 | 选集面板、竖屏上下滑切集、换源、清晰度 | `switch_episode_*`、`canVerticalEpisodeSwipe`、`switch_resources_*` |
| 弹幕 | 滚动/顶部/底部、颜色、透明度、字号、速度、开关、举报/删除/点赞 | `canvas_danmaku` + `danmaku_manager` + `danmu_controller` |
| 系统 | 画中画、投屏、下载、保持常亮、横竖屏锁定 | `fl_pip`（MainActivity 继承 `FlPiPActivity`，manifest `supportsPictureInPicture=true`）、`dlna_dart`、`flutter_downloader` |
| 数据 | 播放历史（秒级续播）、下载记录、离线播放 | `video_net_history`、`downloader/*`（m3u8 分片/多段/断点） |

### 2.7 不该搬的部分

登录/注册/找回密码、VIP 与会员模块、积分与卡密兑换、穿山甲/优量汇/百度/BeiZi 四家广告、友盟统计、
马甲包切图标、加密 API 源与 43 条解析接口、反截屏/青少年模式等。这些是它的商业化外壳，
与"播放"无关，且带明显合规风险。

---

## 3. ManComi 现状评估

### 3.1 现有数据链路（一条直线，只有一个"出口"）

```
ComicSource(JS)  ── loadInfo ──▶ ComicDetails{ chapters: Map<chapterId, name> }
                                        │
                              用户点章节 │
                                        ▼
                         loadEp(cid, ep) -> { images: List<String> }
                                        │
                                        ▼
                                   Reader（6 种阅读模式：图集/连续 × 左右/右左/上下）
```

关键代码位置：

- `lib/foundation/comic_source/parser.dart:786` `_parseLoadComicPagesFunc()` —— **唯一返回 `List<String>` 的地方**
- `lib/pages/reader/images.dart:72` —— 章节图片装载入口（本地已下载分支 + 网络分支）
- `lib/pages/reader/reading.dart` 系列 —— 6 种渲染模式
- `lib/foundation/history.dart` —— `History{ ep, page }`，`page` 是 1-based 页码

### 3.2 可以直接复用的资产

| 资产 | 位置 | 对视频的价值 |
| --- | --- | --- |
| `getImageLoadingConfig` 钩子 | `comic_source.dart:156` | 已经把"每个 URL 的 headers/method/data"做成可插拔配置，**播放请求的 Referer/UA 可直接沿用这套约定** |
| `AppDio` + 拦截器 | `network/app_dio.dart` | 拉 m3u8、拉分片、带 cookie |
| `History` / `HistoryManager` | `foundation/history.dart` | 续播的位置存储（需要扩字段） |
| 原生通道 | `MainActivity.kt` | 已有 `setScreenOn`（常亮）、`venera/volume` EventChannel（音量键）、`startContractForResult`（可扩 PiP） |
| WebView 页 | `pages/webview.dart` | 已能取 cookie / UA，可扩"WebView 嗅探 m3u8" |
| UI 组件库 | `components/*` | `custom_slider`（进度条）、`menu`、`pop_up_widget`、`button`、`loading` 全部能直接用 |
| 加载态框架 | `LoadingState` + `Res` | 播放页的数据加载可直接套 |
| 国际化 | `utils/translations.dart` | 播放器文案接入 |

### 3.3 能力缺口

| 能力 | ManComi 现状 | 缺口 |
| --- | --- | --- |
| 播放内核 | 无 | 新增依赖 + 平台配置 |
| 本地 HTTP 代理 | 无（无 `HttpServer`） | 新增模块（m3u8 重写 + 分片透传） |
| 章节媒体类型 | 只有图片 | 数据模型扩展（向后兼容） |
| 播放进度 | 只存页码 | 存秒 + 时长 |
| 画中画 | 无（`FlutterFragmentActivity`，未声明 PiP） | 改 manifest + Activity + 依赖 |
| 弹幕 | 无 | 需自建或第三方弹幕源，**建议后置** |
| 下载 | 只有图片/CBZ/EPUB/PDF | HLS 分片下载（后置） |

---

## 4. 三种整合粒度

### 方案 A：最小可用（推荐先做这一档）

思路：**不新增"视频"这个概念，让视频章节伪装成一个"只有 1 个元素的图片章节"**，在打开章节时按 URL 分流。

改动点（共 6 处，均为小改）：

1. `parser.dart` `_parseLoadComicPagesFunc()`：返回结构从 `List<String>` 扩成 `Res<ChapterContent>`，
   `ChapterContent{ List<String> images, MediaInfo? media }`；JS 侧仍可只返回 `images`（完全向后兼容）。
2. 新增 `lib/foundation/media_info.dart`：`url / type(mp4|hls) / headers / duration / qualities / subtitles`。
3. `pages/reader/images.dart:72` 装载后判断：若 `media != null` 或唯一 URL 后缀为 `.mp4/.m3u8`，
   直接 `App.to(VideoPlayerPage(...))` 并 `pop` 当前阅读器骨架。
4. 新增 `lib/pages/video/video_player_page.dart` + `lib/network/media_proxy.dart`（本地代理）。
5. `History` 增 `durationMs / positionMs`（SQLite 迁移一条 `ALTER TABLE`），或复用 `page` 存秒 + 类型标记。
6. 详情页章节列表加一个小角标（▶），让用户知道这章是视频。

优点：不动 JS 契约、不动详情页/收藏/评论/历史、现有源无感。
缺点：无清晰度/多集元数据、无弹幕、无画中画。

### 方案 B：源能力扩展（推荐第二档）

- JS API 增加 `media` 字段：`loadEp` 可返回 `{ media: { url, headers, duration, qualities: [...] } }`；
- `doc/comic_source.md` 补文档，源作者可选择声明；
- 详情页对"视频漫/漫剧"显示播放按钮而非"开始阅读"；
- 加入清晰度切换、续播、自动下一集（复用 `chapters`）。

这一档做完，ManComi 就已经能承载"漫剧/动态漫/有声漫"这类内容形态，而不用变成影视 App。

### 方案 C：完整影视化

多源聚合、换源、解析接口、弹幕后端、离线下载、投屏、短剧竖滑 —— 相当于重做一个 wksp。
不建议，且合规风险最高。

---

## 5. 关键技术决策

### 5.1 播放内核三选一

| | `video_player`（ExoPlayer/Media3） | `media_kit`（libmpv） | `flutter_vlc_player`（libvlc） |
| --- | --- | --- | --- |
| 体积增量/ABI | 最小（约 +2~4MB） | 中（约 +15~20MB） | 大（约 +25~40MB） |
| HLS/m3u8 | 原生支持 | 支持 | 支持 |
| 自定义 headers | 支持（`httpHeaders:`，作用于清单和分片） | 支持（更强） | 支持但配置分散 |
| 软解兜底 | 无（靠系统解码器） | 强（ffmpeg） | 强 |
| 16KB 页对齐（targetSdk 36 必需） | ✅ | ✅ | ⚠️ libvlc 3.x 不满足，需 vlc4 |
| 画中画 | 需自己做（原生） | 需自己做 | 需自己做 |
| 桌面端 | 无 | 有 | 有 |

**建议：`video_player` 起步**（ManComi 是 Android only、minSdk 24、targetSdk 36）。
遇到软解需求（老设备 H.265、非常规封装）再切 `media_kit`。
**不要选 `flutter_vlc_player`**：libvlc 3.x 的 16KB 页对齐问题在 targetSdk 36 上会直接崩，且体积最大。

### 5.2 m3u8 与防盗链（必做）

ManComi 现在没有本地服务器，必须新增。参考目标 App 的做法：

```
播放器请求 http://127.0.0.1:<port>/proxy/video?u=<url>&sig=<hmac>
  ├─ 若 m3u8：下载 → 解析所有 URI（含 #EXT-X-KEY、#EXT-X-MAP、多级 master）
  │            → 全部改写成 /proxy/video?u=<绝对地址> → 返回改写后的清单
  └─ 若分片：按源配置注入 Referer/UA/Cookie → 流式透传（透传 Range，支持拖动）
```

要点：
- 端口随机 + 本机 `127.0.0.1` 绑定 + 一个内存密钥签名，避免被外部 App 当免费代理；
- 必须支持 `Range` 透传，否则拖进度条会整段重下；
- `#EXT-X-KEY`（AES-128）的 key URL 也要走代理，否则解密请求丢 Referer；
- 若源站允许直连（headers 无要求），可跳过代理直连，减少一层开销。

### 5.3 进度记忆

`History.page` 是 1-based 页码，直接塞秒数会在"继续阅读"里显示成 "第 1432 页"。
建议：`History` 加 `bool isVideo` + `int positionMs`，或独立 `media_history` 表；
UI 层按类型分别渲染 "继续观看 12:34" / "第 12 页"。

### 5.4 画中画

`MainActivity` 现继承 `FlutterFragmentActivity`，加 PiP 需要：
manifest 声明 `android:supportsPictureInPicture="true"` + `configChanges` 补 `screenSize|smallestScreenSize|screenLayout|orientation`，
再实现 `onUserLeaveHint` → `enterPictureInPictureMode`，或用 `fl_pip`（目标 App 就是 `FlPiPActivity`）。
注意 `FlutterFragmentActivity` 与 `fl_pip` 的 `FlPiPActivity` 有继承冲突，二者只能选一个作为基类——
这是接入时最容易踩的坑。**建议先不做 PiP，作为独立迭代。**

### 5.5 弹幕

`canvas_danmaku` 是公开 pub 包，渲染侧没有门槛；门槛在**弹幕数据从哪来**。
ManComi 没有弹幕后端，可选：
- 仅本地弹幕（自己发、自己看，存本地）；
- 接第三方开放弹幕库（如弹弹play 的开放接口）；
- 后置，等有内容生态再说。

---

## 6. 风险清单

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 版权/合规 | 高。目标 App 是盗版影视聚合并伪装包名，直接搬它的源/解析接口会连带风险 | 只搬技术骨架，源由 ManComi 自己的 JS 源定义；不内置任何影视 API 域名 |
| 16KB 页对齐 | 高。targetSdk 36 + NDK 28，不满足的 `.so` 在 Android 15+ 直接崩 | 选 `video_player`（无自带 .so）或验证过的 `media_kit` |
| 包体积 | 中。三个 ABI + universal APK | 播放器走 minimal 方案；必要时对视频功能做 ABI 裁剪 |
| 现有 APK 签名/渠道 | 中。加依赖后需回归全部图标别名、存储权限、Saf 流程 | 分阶段合入，每阶段出包回归 |
| `FlutterFragmentActivity` 冲突 | 中。PiP/本地播放器插件常要求特定基类 | PiP 单独迭代，先确认插件基类要求 |
| 阅读器状态机复杂 | 中。Reader 有 814 行 + 6 种模式 + 手势/滚动状态 | 视频走独立路由，**不复用 Reader**，只在入口分流 |
| 代理端口与网络策略 | 低。Android 9+ 明文回环默认允许，但需确认 `networkSecurityConfig` | 绑定 127.0.0.1 + 白名单 |

---

## 7. 建议路线（不排期，只排顺序）

**第 1 步 · 打通链路（验证性）**
本地代理 + `video_player` + 一个硬编码 m3u8 的播放页，跑通"能播、能拖、能全屏"。

**第 2 步 · 接入数据链路（方案 A）**
`ChapterContent` 模型 → `_parseLoadComicPagesFunc` 扩展 → 阅读器入口分流 → 章节 ▶ 角标。
此时"用现有 JS 源返回一个 m3u8"就能在 ManComic 里播。

**第 3 步 · 播放体验**
续播（History 扩字段）、倍速、手势（复用已有 `venera/volume` 通道 + `screen_brightness`）、
横竖屏、保持常亮（已有 `setScreenOn`）、错误态与重试、选集/自动下一集。

**第 4 步 · 可选增强**
画中画、字幕、HLS 离线下载、弹幕。

---

## 7.5 关于"直接复用它的视频接口"（专项结论）

**技术上能，产品上不能，法律上不该。** 三条理由按重要性排序：

**① 它本来就是为"防复用"设计的。**
- 12 个源里 5 个是加密 API 源（`iv/key/salt` + DESede + `tokenUrl` 初始化）；
- header 固定签名（`app_id / version / channel_code / package_name`），代码里有 `_signPrefix` 签名函数；
- `verificationUrl` + `verificationCheckUrl(do_v2)` 是设备/请求校验，`replaceDomain` + `replaceEncryptDomain` 是动态域名；
- 配置入口本身还有一层：`assets/na.czl` 是异或加密的二进制配置，`xg.php` 有 3 个云端备份地址（阿里 OSS / 腾讯 COS / 自建 IP:端口）。
- 这套东西的维护成本是"每次它换域名、换密钥、加校验，你就得再逆向一次"，而它换壳换域名是常态（马甲包 + 蓝奏云分发）。

**② 命脉不在你手里。** 即使复刻成功，也是"今天能播、明天全黑"，且没有任何 SLA、没有协商空间。一个阅读器的核心体验依赖一条随时会断的灰色链路，这是产品级不可接受。

**③ 合规风险全部落在 ManComi 身上。** 那是盗版影视聚合接口，对接它等于把 ManComi 变成盗版内容的分发端。应用商店下架、律师函、广告与支付账户被封，都是现实成本。**所以这一层我不会做。**

**但"内容"和"播放能力"是两件事：**

| 你的片源 | 播放能力还有没有必要做 | 说明 |
| --- | --- | --- |
| 就想接 wksp 的片源 | ❌ 没必要 | 结论同上，就此打住是对的 |
| 自有/授权内容（漫剧、动态漫、作者上传） | ✅ 值得做 | 播放层可直接复用，源用 ManComi 自己的 JS 源声明 |
| 本地/网盘视频（WebDAV、本地文件） | ✅ 值得做，且最省事 | 零合规风险，不需要解析层，只要播放页 |
| 第三方平台内容（B站/YouTube/Vimeo 等） | ⚠️ 有限 | 走官方嵌入/API，不能扒流 |

---

## 8. 需要你确认的几件事

1. **内容形态**：是"漫剧/动态漫"（一章一个视频，依附于漫画详情页），还是想要独立的"视频/短剧"Tab？
   前者用方案 A 就够，后者要动主页面导航与数据层。
2. **源从哪来**：ManComi 自己的 JS 源里已有可返回 m3u8 的源，还是需要新增一类"视频源"？
3. **合规边界**：是否接受"不内置任何第三方影视接口，只提供播放能力"？
4. **优先级**：先要"能播"，还是先要"播得好看"（手势/弹幕/PiP）？
