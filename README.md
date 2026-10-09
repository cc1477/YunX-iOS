# YunX-iOS

将 [CYQawa/YunX](https://github.com/CYQawa/YunX) Android 版移植到 iOS，采用
Kotlin Multiplatform（KMP）共享业务代码与 Compose Multiplatform（CMP）共享界面。
Stage 1 提供工程脚手架、Compose 占位页面与 SwiftUI 宿主，业务功能将在后续阶段移植。

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
└── BUILD-iOS.md                    # Stage 5 将编写的 Mac 构建指南
```

工程包含 JVM、iOS 真机 arm64 和 Apple Silicon 模拟器 arm64 target，不包含 Android target。
iOS Application 名称为 **YunX**，bundle ID 为 `com.yunx.app.ios`，部署目标为 iOS 15.0，
Swift 版本为 5。Debug / Release 通过 xcconfig 选择对应的 Kotlin framework；
Xcode 在 Swift 编译前调用 Gradle，然后链接、嵌入并签名动态 `shared.framework`。
AppIcon 目前仅有元数据占位，需在 Mac 的 Xcode 中补充真实图标。

首次构建前请按 [PORTING-NOTES.md](PORTING-NOTES.md) 生成缺失的 `gradle-wrapper.jar`。
详细 Mac 构建步骤将在 Stage 5 写入 [BUILD-iOS.md](BUILD-iOS.md)。

## 致谢与授权

感谢上游 [CYQawa/YunX](https://github.com/CYQawa/YunX) 的代码与设计。
本移植工程遵循 **AGPL-3.0**，保留上游版权及授权声明，详见 [LICENSE](LICENSE)。
`.upstream/` 仅用于只读参考，不直接修改上游文件。
