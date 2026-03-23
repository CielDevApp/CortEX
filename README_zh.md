# Cort:EX ver.02a

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

---

## 系统要求
- iOS 18.0+ / iPadOS 18.0+（iOS 26 / iPadOS 26 已测试）
- iPhone / iPad（支持iPad双页模式）

## 安装

### 从源码构建
1. 克隆：`git clone https://github.com/CielDevApp/CortEX.git`
2. 用 Xcode 16+ 打开 `EhViewer.xcodeproj`
3. 在 Signing & Capabilities 中选择你的Team
4. 将 Bundle Identifier 改为唯一值（如 `com.yourname.cortex`）
5. 连接设备，点击 Run

### 免电脑安装
1. 从 [Releases](https://github.com/CielDevApp/CortEX/releases) 下载IPA
2. 通过 AltStore、Sideloadly 或 TrollStore 安装

> 注意：免费Apple开发者账号有7天签名限制。建议使用AltStore自动续签。

## 技术栈
- Swift / SwiftUI
- 76个Swift文件 / 约20,000行代码
- Metal / CoreML / Vision / WebKit / ActivityKit / TipKit

## 许可证
本项目采用 GPL-3.0 许可证 - 详见 [LICENSE](LICENSE) 文件。

## 支持
在 [Patreon](https://www.patreon.com/c/Cielchan) 上支持开发。
