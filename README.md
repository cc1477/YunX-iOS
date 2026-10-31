# 云析 YunX · Flutter 版（`flutter` 分支）

[CYQawa/YunX](https://github.com/CYQawa/YunX)（Android）的 Flutter 移植版，与 `main` 分支的 SwiftUI 版功能对齐、并行维护。

- **框架**：Flutter（Material 3 + 自定义毛玻璃风格），状态管理 provider
- **原生部分**：`packages/yunx_media` —— iOS 端用 AVFoundation 直通合并 B 站 DASH 音视频轨
- **协议**：GNU AGPL-3.0（见 [LICENSE](LICENSE)）

## 已移植

| 模块 | 说明 |
|---|---|
| 链接识别 | 10 个网盘 + 7 个视频平台的链接 / 提取码规则，与 Android 版一致 |
| 夸克 / UC | 免转存取链；未登录游客态，登录后不限大小（UC 视频取原画） |
| 123 云盘 | 分享匿名浏览；账号密码登录后签名取直链 |
| 百度网盘 | 公共分享匿名浏览；登录后临时转存 → locatedownload 取 CDN 直链 → 立即删除转存 |
| 115 网盘 | 分享匿名浏览；登录后用 115 客户端 UA 取直链，自动拼接 CDN Cookie |
| 光鸭云盘 | 公开分享匿名解析下载 |
| 蓝奏云 | 匿名解析单文件 / 文件夹，含 `acw_sc__v2` 与「验证并下载」 |
| 视频 | 抖音（SSR + 无界面 WebView 兜底）、哔哩哔哩（DASH 合轨）、快手、微博、AcFun（HLS） |
| 下载 | 并发上限、Range 断点续传、HLS 分片、实时速度、打开 / 分享 / 存相册 |
| 账号 | WebView 网页登录自动识别 Cookie、账号密码登录、手动填 Cookie；凭证存钥匙串 |

## 构建

推送到 `flutter` 分支后，`.github/workflows/build-flutter-ios.yml` 会在 GitHub 的 macOS 机器上：

1. `flutter create --platforms=ios .` 生成 iOS 工程（仓库里只放 `lib/`、`assets/`、`packages/`）
2. 写入 Info.plist 权限（文件 App 可见、相册、ATS）
3. `flutter build ios --release --no-codesign`，打包未签名 IPA

在 Actions 页面下载 `YunX-Flutter-unsigned-ipa`，用 Sideloadly / AltStore 签名安装。

本地有 Mac 时：

```bash
flutter create --org com.yunx --project-name yunx --platforms=ios .
flutter pub get
flutter run
```
