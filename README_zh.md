# Cort:EX ver.02a f5

> ## ⚠️ Security Fix — Immediate Update Required
>
> v0.2a to v0.2a-f6 contained hardcoded debug credentials.
> The affected credentials have been revoked.
> Please update to this version immediately.
> If you built from source or used previous binaries, there is no further action required from your side.

**E-Hentai / EXhentai / nhentai 统一浏览器 for iOS / iPadOS**

[English](README.md) | [中文](README_zh.md) | [日本語](README_ja.md)

---

## 演示

https://github.com/CielDevApp/CortEX/raw/main/assets/demo.mp4

> *内容已模糊处理*

---

## 功能

### 多站点整合
- **E-Hentai / EXhentai** — 根据登录状态自动切换。未登录也可浏览E-Hentai
- **nhentai** — 完整API集成、Cloudflare自动绕过（WKWebView cf_clearance）、WebP支持
- **四层删除作品恢复** — nhentai（应用内搜索）→ nyahentai.one → hitomi.la → 标题复制

### 阅读器
- **4种模式** — 垂直滚动 / 水平翻页 / iPad双页展开 / 捏合缩放
- **iPad双页** — 自动横屏检测、双页合成渲染（零间隙）、宽图独立显示
- **从右到左 / 从左到右** — 支持边缘点击翻页
- **双击缩放** — 支持Live Text（文字选择）

### 图像处理（3引擎）
- **CIFilter** — 色调曲线、锐化、降噪
- **Metal Compute Shader** — GPU直接管线
- **CoreML Real-ESRGAN** — Neural Engine 4倍超分辨率（分块处理）
- **4级画质** — 低画质 → 低画质+超分 → 标准 → 标准+滤镜
- **HDR增强** — 暗部细节恢复 + 自然饱和度 + 对比度

### 下载
- **双向下载（极限钳形攻势）** — 前向+后向同时下载
- **二次扫描** — 失败页面自动重试（指数退避）
- **Live Activity** — 锁屏 + 灵动岛进度显示
- **阅读/下载分离** — 关闭时提示"是否下载剩余页面？"

### 收藏
- **双缓存** — E-Hentai / nhentai 独立缓存（磁盘持久化）
- **nhentai同步** — WKWebView SPA渲染 → JavaScript ID提取 → API解析
- **搜索 / 排序** — 添加日期（最新/最旧）/ 标题

### nhentai详情页
- 标题 / 封面 / 信息（语言、页数、社团、画师、同人原作）
- **标签点击搜索** — 一键搜索 artist:名称、group:名称 等
- 缩略图网格 → 点击跳转到指定页面
- 滤镜管线（降噪 / 增强 / HDR）

### 安全
- **Face ID / Touch ID** — 启动和恢复时认证
- **4位PIN码** — 生物识别失败后备
- **应用切换模糊** — 任务切换器中隐藏内容
- **Keychain加密** — Cookie和凭证安全存储

### 备份
- **PHOENIX MODE** — E-Hentai + nhentai 统一JSON收藏备份
- **极限安全锁** — 必须先备份才能启用EXTREME MODE
- **.cortex导出** — 画廊ZIP包

### 性能
- **ECO模式** — NPU/GPU禁用、30Hz、iOS低电量模式联动
- **EXTREME MODE** — 全部限制器解除（20并行、零延迟）
- **CDN回退** — i/i1/i2/i3自动切换 + 扩展名回退（webp→jpg→png）

### 翻译
- **Vision OCR** → Apple Translation API → 图像烧录
- 5种语言（日/英/中/韩/自动）

### AI（iOS 26+）
- **Foundation Models** — 自动分类、标签推荐

### UI/UX
- **TipKit（11条提示）** — 所有功能的操作提示，可在设置中重新显示
- **8种语言** — 日 / 英 / 简中 / 繁中 / 韩 / 德 / 法 / 西
- **动态标签** — 根据登录状态自动切换 E-Hentai ↔ EXhentai
- **基准测试** — CIFilter vs Metal 速度测试 + 设备型号显示
- **锁屏壁纸** — 收藏的画廊封面自动显示为锁屏背景
- **标签栏自动隐藏** — 向下滚动时隐藏标签栏，增加显示空间

---

## 系统要求
- iOS 18.0+ / iPadOS 18.0+（iOS 26 / iPadOS 26 已测试）
- macOS 14.0+（Mac Catalyst，Apple Silicon / Intel 均可）
- iPhone / iPad（支持iPad双页模式）/ Mac

## 安装

### iOS / iPadOS — 从源码构建
1. 克隆：`git clone https://github.com/CielDevApp/CortEX.git`
2. 用 Xcode 16+ 打开 `EhViewer.xcodeproj`
3. 在 Signing & Capabilities 中选择你的Team
4. 将 Bundle Identifier 改为唯一值（如 `com.yourname.cortex`）
5. 连接设备，点击 Run

### iOS / iPadOS — 免电脑安装
1. 从 [Releases](https://github.com/CielDevApp/CortEX/releases/latest) 下载 `EhViewer-<version>.ipa`
2. 通过 AltStore、Sideloadly 或 TrollStore 安装
   - AltStore / Sideloadly 导入时会用你自己的 Personal Team 重新签名，因此分发 IPA 的签名会被剥离（只要是最新版 IPA 即可）
   - TrollStore 无需重新签名，直接使用

> 注意：免费Apple开发者账号侧载签名有7天限制。建议使用AltStore自动续签。

### Mac（Catalyst版） — 下载预编译 .app
1. 从 [Releases](https://github.com/CielDevApp/CortEX/releases/latest) 下载 `EhViewer-macOS-<version>.zip`（Developer ID 签名 + Apple 公证）
2. 解压后将 `EhViewer.app` 拖入 `/Applications`
3. 双击启动 — 无需 `xattr` 绕过，Gatekeeper 直接通过

### Mac（Catalyst版） — 从源码构建
1. 克隆：`git clone https://github.com/CielDevApp/CortEX.git`
2. 用 Xcode 16+ 打开 `EhViewer.xcodeproj`
3. Scheme = `EhViewer`，Destination = `My Mac (Mac Catalyst)`
4. 在 Signing & Capabilities 中选择你的Team，并修改 Bundle Identifier
5. Product → Run 启动，或 Product → Archive 导出 `.app` 后拖入 `/Applications`
   - 命令行：`xcodebuild -project EhViewer.xcodeproj -scheme EhViewer -destination 'platform=macOS,variant=Mac Catalyst' build`
6. Mac 版顶部配备独立 7 标签栏（画廊 / 收藏 / 抽卡 / 已保存 / 历史 / 角色管理 / 设置），无论窗口宽度始终横向排列

## 技术栈
- Swift / SwiftUI
- 76个Swift文件 / 约20,000行代码
- Metal / CoreML / Vision / WebKit / ActivityKit / TipKit

## 更新日志

### ver.02a f6 (2026-04-23)
- **Mac Catalyst 完全支持** — 支持 macOS 14+（Apple Silicon / Intel）的通用构建。Developer ID 签名 + Apple 公证的 `.app` 通过 GitHub Releases 分发，拖入 `/Applications` 双击即可启动。顶部标签栏用自定义 HStack 重写（绕开 Catalyst TabView 的 overflow menu），全 7 标签始终横排 + 整格命中区 + 方向键翻页
- **EXTREME MODE → SAFETY MODE 重设计** — 以 BAN 抗性为核心重新组织结构。BAN 检测 6 路径完全封堵、50 页 / 60 秒 自动 cooldown、并行度保持不降速的 class-change。transport 层整合 509 gif URL 模式检测、Cloudflare `cf-mitigated` 头检测、HTML fallback 检测、home.php 误重定向检测
- **动画 WebP 阅读器强化** — 统一手动播放模式（▶ 图标点击触发转换），HDR 校正合并到现有图像设置，长按菜单直接切换模式。检测统一使用 VP8X magic，原始字节从内存转移到磁盘 URL 路径以降低内存压力
- **动画 WebP 卡顿修复** — 修复 LocalReader / GalleryReader 自动播放导致的内存爆炸与 UI 卡死。AVPlayer 仅当前页升级、缓存升级移至 init、PlayerContainerView 不再吞掉滚动手势、缓存复活时的重建循环彻底解决
- **nhentai 登录恢复 (Mac Catalyst)** — 用文件回退方式 (`~/Documents/EhViewer/creds/`) 绕开 Keychain `-34018 errSecMissingEntitlement`，同时修复 Cloudflare 通过路径，Catalyst 下也能持久认证
- **iPad 标签栏跟随** — 改用 GeometryReader + PreferenceKey 观测路径，iPad 上向下滚动时的标签栏自动隐藏也能稳定工作
- **已下载封面本地复用扩展** — 不仅在详情页，现在在历史 / 抽卡 / 设置页也优先使用本地封面图像，减少 CDN 往返
- **发布自动化** — 新增 `scripts/release-mac.sh`（Archive → Developer ID 签名 → notarize → staple → zip）和 `scripts/release-ios.sh`（Archive → Development IPA 导出），一个 tag 参数同时生成 Mac zip + iOS IPA

### ver.02a f5 (2026-04-20)
- **自研 ZIP streaming writer** — 替换 Apple 的 NSFileCoordinator.forUploading（大作品 59 秒主线程阻塞 + Code=512 失败），改为流式 stored+ZIP64 writer。6 倍速 + 实时进度条 + 3GB+ 作品也能正常导出
- **僵尸下载根除** — 删除 / 取消后 URL 解析 / stream 消费 / 二次重试循环仍在运行的问题修复。清理时的元数据复活也已防止
- **滚动位置一致性** — LocalReaderView 页码与显示页不一致的问题根除。LazyVStack `.onAppear` 的 last-wins 竞态 + `.scrollPosition` / `scrollTo` API 冲突导致「1/47 却在显示第 13 页」类错位
- **已保存作品预览** — 长按显示全页缩略图网格，点击跳转该页阅读。竖长固定单元格统一布局，动画 WebP 以紫框 + ▶ 图标标识
- **0B 缓存误识别防护** — `isFullyConverted` 增加尺寸检查（≥10KB），避免 race condition 导致的 0B 缓存 mp4 引发 AVPlayer "item failed" 连锁
- **DL 重试策略** — Cloudflare `cf-mitigated: challenge` 头检测、509 gif URL 模式检测、SpeedTracker 基于字节进度的看门狗、别镜像重试中 UI 阶段
- **并行下载** — URL 解析完成即释放 semaphore，支持多作品并行下载
- **临时文件自动清理** — 共享表单完成时（AirDrop / Save to Files / 取消）即删除 `.cortex`，与启动时残骸清理协同

### ver.02a f3 (2026-04-12)
- **GPU精灵图管线** — 精灵图解码、裁剪、缩放通过Metal CIContext单通道GPU渲染
- **专用图像处理队列** — 所有精灵图处理移至独立DispatchQueue，消除协作线程池饥饿
- **磁盘缓存废除** — 移除精灵图和裁剪缩略图的JPEG重编码（仅内存缓存，可重新获取）
- **启动预取优化** — 缩略图预取从全部收藏（2400+）缩减至可见的30项

### ver.02a f2 (2026-04-07)
- **收藏切换可靠性** — 429错误页面重试+退避、禁用按钮检测、Cookie去重修复
- **Cookie管理改进** — 改为保留服务器设置属性（HttpOnly, Secure）的补充注入方式
- **速率限制加固** — `fetch()` 新增429重试（3秒/6秒指数退避，最多3次）

### ver.02a f1 (2026-04-05)
- **nhentai API v2迁移** — 从v1全面迁移至v2 API，通过WKWebView绕过Cloudflare TLS指纹检测
- **nhentai收藏切换** — 通过SPA `#favorite` 按钮点击实现服务端添加/移除（SvelteKit hydration轮询）
- **收藏同步优化** — 跳过已缓存画廊大幅减少API调用，429重试+指数退避
- **v2认证支持** — `isLoggedIn()` 现在也识别 `access_token`（v2），不再仅依赖旧版 `sessionid`
- **缩略图 / 封面 v2** — 使用v2 API的 `thumbnailPath` 和 `path`，CDN回退（i/i1/i2/i3）
- **已删除作品恢复** — 打开阅读器前通过 `fetchGallery` 获取完整详情
- **nhentai详情页** — 标签点击搜索、缩略图网格、下载、滤镜管线
- **锁屏壁纸** — 收藏封面自动显示为模糊锁屏背景
- **标签栏自动隐藏** — 向下滚动时隐藏标签栏，增加显示空间

### ver.02a（首次发布）
- E-Hentai / EXhentai / nhentai 统一浏览器
- 4模式阅读器（支持iPad双页展开）
- 3引擎图像处理（CIFilter / Metal / CoreML Real-ESRGAN）
- 双向下载 + Live Activity
- Face ID / Touch ID / PIN安全
- PHOENIX MODE备份、ECO / EXTREME性能模式
- Vision OCR翻译、TipKit提示、8语言本地化

## 许可证
本项目采用 GPL-3.0 许可证 - 详见 [LICENSE](LICENSE) 文件。

## 支持
在 [Patreon](https://www.patreon.com/c/Cielchan) 上支持开发。
