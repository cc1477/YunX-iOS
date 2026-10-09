# YunX-iOS

将 [CYQawa/YunX](https://github.com/CYQawa/YunX) Android 版移植到 iOS，采用
Kotlin Multiplatform（KMP）共享业务代码与 Compose Multiplatform（CMP）共享界面。
Stage 1–4 已落地工程脚手架、commonMain 数据层与 UI、iosMain actual 和 Swift 生命周期胶水。
Stage 5 完成构建文档。2026-10-09 已通过 JVM 编译与 3 项共用回归测试，
并在 macOS 15 / Xcode 16.4 CI 完成 Kotlin/Native、Swift、Debug arm64 模拟器构建与启动检查。
应用启动后持续运行至少 15 秒，截图已确认显示“欢迎使用云析”界面。
[通过的 CI](https://github.com/cc1477/YunX-iOS/actions/runs/37901341331) 提供
[模拟器应用和启动截图](https://github.com/cc1477/YunX-iOS/actions/runs/37901341331/artifacts/11603375521)，
产物保留至 2026-10-16；它仅供 Apple Silicon iOS 模拟器使用，不是可安装到真机的 IPA。
真机运行、Release 构建、签名、登录和下载功能尚未通过验证；未签名 Debug 真机包见下方。

## 未签名真机 IPA

[打开 LCSign 测试分发页](https://cc1477.github.io/YunX-iOS/)，可直接导入 LCSign 或手动下载未签名 IPA，无需登录 GitHub。页面显示包内版本、构建号、构建提交及 SHA256，导入后选择自己的证书签名安装。

当前 UI 适配测试包为 **0.1.0（2）**。本地 8 项共享回归测试通过，包含安全区、大字号与窄屏布局检查，生成 61 张 Compose JVM 渲染截图；验证范围见 [UI-ADAPTATION.md](UI-ADAPTATION.md)。

[设备包编译与分发部署](https://github.com/cc1477/YunX-iOS/actions/runs/37939714730)和[共享测试、模拟器构建及启动检查](https://github.com/cc1477/YunX-iOS/actions/runs/37939578245)均已通过。线上 IPA 已重新下载核对版本、构建号、包名及 SHA256；[本次模拟器启动截图产物](https://github.com/cc1477/YunX-iOS/actions/runs/37939578245/artifacts/11621454334)保留 7 天。真机签名、运行、登录与下载仍需设备验证。

这是 Debug 配置的 iPhone arm64 IPA，最低 iOS 15.0，bundle ID 为 `com.yunx.app.ios`。已核验 `Payload/YunX.app`、主程序与动态库的真机平台标记；不含代码签名或描述文件，需要自行签名后安装。真机运行、登录与下载尚未验证。首次 Release 构建因 Kotlin/Native 优化阶段的 Java heap space 失败，改用 Debug 后[构建和打包通过](https://github.com/cc1477/YunX-iOS/actions/runs/37919720624)。

需要更新包时，可在 Actions 的 **Unsigned iOS IPA** 工作流中选择 **Run workflow**。此工作流生成真机包并验证后自动部署 LCSign 测试页，与 **iOS build** 的模拟器包用途不同。GitHub Pages 发布源需保持为 GitHub Actions。

## 目录结构

```text
.
├── shared/                         # KMP + CMP 共用模块
│   └── src/
│       ├── commonMain/             # 共用界面、业务与 SQLDelight schema
│       ├── iosMain/                # iOS Compose 入口及平台适配
│       ├── jvmMain/                # JVM 平台依赖
│       ├── commonTest/             # 共用测试
│       └── jvmTest/                # JVM 测试
├── iosApp/
│   ├── iosApp.xcodeproj/           # YunX iOS Application target
│   ├── iosApp/                     # SwiftUI 入口、Info.plist 与资源
│   ├── Configuration/             # Debug / Release xcconfig
│   └── scripts/build-shared.sh     # Xcode 编译前生成 shared.framework
├── gradle/                         # 版本目录与 wrapper 配置
├── .upstream/                      # 只读上游参考
├── PORTING-NOTES.md                # 移植决策与首次构建准备
└── BUILD-iOS.md                    # Mac 构建、签名与运行指南
```

工程包含 JVM、iOS 真机 arm64 和 Apple Silicon 模拟器 arm64 target，不包含 Android target。
iOS Application 名称为 **YunX**，bundle ID 为 `com.yunx.app.ios`，部署目标为 iOS 15.0，
Swift 版本为 5。Debug / Release 通过 xcconfig 选择对应的 Kotlin framework；
Xcode 在 Swift 编译前调用 Gradle，然后链接、嵌入并签名动态 `shared.framework`。
AppIcon 目前仅有元数据占位，需在 Mac 的 Xcode 中补充真实图标。

## Mac 构建入口

按 [BUILD-iOS.md](BUILD-iOS.md) 完成 JDK 17、Xcode 16+、wrapper 准备，再构建和运行。
不需要 CocoaPods。当前未配置 XCFramework 聚合 task，使用指南列出的四个 framework link task。

工程已包含官方 Gradle 8.10.2 wrapper，并固定分发包 SHA-256；无需安装系统 Gradle。
共享 YunX scheme 已指向正确 target，Info.plist 的 bundle ID 跟随 Xcode 的
`PRODUCT_BUNDLE_IDENTIFIER`，真机签名时在 target 设置中修改即可。

## iOS 平台差异（必读）

- **后台下载有限制：**仅无请求头、无 provider 标识的普通 HTTP(S) 直链（非 m3u8）自动交给系统单连接下载，并从头开始；认证/网盘/HLS 等任务暂停后回前台继续。前台分片保留，系统调度和强制退出后恢复不保证，仍需真机验证。
- **Gopeed、磁力/BT 不支持：**使用内置 Ktor 下载引擎，Gopeed 设置回退，磁力任务记录失败。
- **WKWebView 登录仍需验证：**按允许域提取 Cookie 并经业务校验；Chrome UA 不等于 Chromium。跨域登录、SPA Cookie 更新、验证码与迅雷专有验证可能失败；localStorage Token 自动提取未实现。
- **文件与系统能力：**下载保存在沙盒 `Documents/Downloads`；原生文件分享/预览/选择流程待补，当前 `file://` 打开不保证成功。通知没有 Android 常驻进度条；剪贴板读取可能触发 iOS 提示。
- **资源与更新：**AppIcon、部分品牌图片和国际化资源待补；更新页展示上游发布信息，不提供 APK 安装，也不代表已有 iOS 分发渠道。

各阶段实现、历史取舍及待验证项见 [PORTING-NOTES.md](PORTING-NOTES.md)。

## 致谢与授权

感谢上游 [CYQawa/YunX](https://github.com/CYQawa/YunX) 的代码与设计。
本移植工程遵循 **AGPL-3.0**，保留上游版权及授权声明，详见 [LICENSE](LICENSE)。
`.upstream/` 仅用于只读参考，不直接修改上游文件。
