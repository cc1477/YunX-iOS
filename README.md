# YunX-iOS

将 [CYQawa/YunX](https://github.com/CYQawa/YunX) Android 版移植到 iOS，采用
Kotlin Multiplatform（KMP）共享业务代码与 Compose Multiplatform（CMP）共享界面。
Stage 1–4 已落地工程脚手架、commonMain 数据层与 UI、iosMain actual 和 Swift 生命周期胶水。
Stage 5 完成构建文档；源码就位不代表 Mac 编译、签名、真机运行已验证。
JVM 编译验证由协调人在 Linux 上独立进行，本 README 不代报验证结果。

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

**首次构建须处理：** wrapper jar 因上游下载超时缺失，应重新生成整套 wrapper 并固定 Gradle 8.10.2；
共享 YunX scheme 的 BlueprintIdentifier 与实际 target ID 不一致，需要按指南修复引用。
真机签名更换 bundle ID 时，Xcode Debug/Release 设置与写死 ID 的 Info.plist 必须同步。
这些是静态检查发现，本文未修改工程配置或执行构建。

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
