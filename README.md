# 云析 YunX · iOS 版

[CYQawa/YunX](https://github.com/CYQawa/YunX)（Android，Kotlin + Jetpack Compose）的 iOS 移植版，用 SwiftUI 重写界面。

- **最低系统**：iOS 17（iPhone / iPad）
- **技术栈**：SwiftUI + Observation、URLSession、WKWebView、AVFoundation，无第三方依赖
- **协议**：GNU AGPL-3.0（与原项目一致，见 [LICENSE](LICENSE)）

## 已移植

| 模块 | 说明 |
|---|---|
| 链接识别 | 全部 10 个网盘 + 7 个视频平台的链接 / 提取码识别规则，与 Android 版逐条一致 |
| 夸克 / UC 网盘 | 分享 token → 分页列目录 → 免转存取直链；未登录走游客态（约 50MB 上限），登录后不限大小 |
| 123 云盘 | 分享匿名浏览；账号密码登录后签名取直链 |
| 蓝奏云 | 匿名解析单文件 / 文件夹分享，含 `acw_sc__v2` 人机校验与「验证并下载」 |
| 抖音 | SSR（ttwid + `_ROUTER_DATA`，探测最高清晰度）；失败时用无界面 WKWebView 兜底 |
| 哔哩哔哩 | 未登录单文件；登录后 DASH 高清，下载后用 AVFoundation 直通合轨成 mp4 |
| 快手 / 微博 / AcFun | 视频与图集；AcFun 为 HLS，按分片下载为 `.ts` |
| 下载 | 并发上限、暂停 / 断点续传（resumeData）、实时速度、完成后可预览 / 分享 / 存入相册 |
| 账号 | WKWebView 网页登录自动识别 Cookie（夸克、B 站），或手动粘贴 Cookie；凭证存钥匙串 |

**尚未移植**（链接能识别，解析时提示「即将支持」）：迅雷、百度、139、115、光鸭、蓝奏云优享、小红书、Pixiv；以及 Android 版的转存到网盘、个人云盘管理、Gopeed 引擎、应用内公告 / 更新。新增平台只需实现 `ShareResolver` 或 `VideoParser` 协议，并在 `ShareResolvers` / `VideoParseService.parsers` 注册。

## 界面

- 四个标签页：解析 / 账号 / 下载 / 设置
- 毛玻璃卡片 + 随主题色变化的柔光背景，6 套主题色，支持深色模式
- 系统 `PasteButton` 粘贴（不弹隐私提示）、剪贴板链接检测横幅、`yunx://resolve?url=…` 深链
- 分享浏览：面包屑目录、搜索、多选批量下载、在线播放、复制直链
- 视频结果：封面大图、作者信息、可展开正文、图集三列网格 + 双指缩放大图
- 下载目录在「文件」App › 我的 iPhone › 云析 中可见

## 构建

### 有 Mac

```bash
brew install xcodegen
xcodegen generate
open YunX.xcodeproj
```

在 Xcode 里选择自己的开发者账号（Signing & Capabilities），连接手机运行即可。

### 只有 Windows

把本目录推到一个 GitHub 仓库，`.github/workflows/build-ios.yml` 会在 GitHub 的 macOS 机器上编译，
在 Actions 页面下载 `YunX-unsigned-ipa`，再用 Sideloadly / AltStore（免费 Apple ID 即可，7 天重签）或 TrollStore 安装。

## 目录

```
YunX/
├── App/            入口、标签页、剪贴板检测、欢迎页
├── Core/
│   ├── Net/        HTTPClient（不共享系统 Cookie）、JSON 访问器
│   ├── Links/      分享链接 / 视频链接识别
│   ├── Drives/     ShareResolver 协议 + 夸克、蓝奏云
│   ├── Video/      VideoParser 协议 + 抖音、B站、快手、微博、AcFun
│   ├── Download/   FileFetcher（续传）、HLS、DASH 合轨、DownloadManager
│   └── Storage/    钥匙串账号、设置、解析历史
├── UI/             设计系统组件、远程图片、播放器
└── Features/       解析 / 账号 / 下载 / 设置 各页面
```

## 免责声明

云析永远免费开源，任何收费版本都是诈骗。本应用仅供学习交流，所解析内容的版权归原作者及平台所有，请遵守各平台用户协议。
