**首次构建准备：`gradle-wrapper.jar` 未能下载，原因是 `raw.githubusercontent.com` 超时。**
Mac 首次构建前，请在项目根目录执行 `brew install gradle && gradle wrapper` 生成 wrapper。
项目的 wrapper 分发版本固定为 Gradle 8.10.2；生成 jar 前无法使用 `./gradlew`。

# 移植记录

## Stage 1

### 版本选择

采用现有 `gradle/libs.versions.toml` 中的固定版本：

| 组件 | 版本 | 选择说明 |
| --- | --- | --- |
| Kotlin | 2.1.0 | KMP、Compose compiler 与 serialization 插件共用版本 |
| Compose Multiplatform | 1.8.2 | runtime、foundation、material3 与 ui 由 Compose 插件管理 |
| material-icons-core | 1.7.3 | 图标库独立固定，不能跟随 CMP 插件版本拼成 1.8.2 |
| SQLDelight | 2.0.2 | Gradle 插件、runtime 与平台 driver 使用同一版本 |
| Ktor | 3.1.3 | common client 组件及 Darwin / CIO engine 统一版本 |
| Coroutines | 1.10.2 | 共用异步任务与协程 |
| kotlinx-serialization JSON | 1.8.1 | 共用 JSON 序列化 |
| kotlinx-datetime | 0.6.2 | 共用时间处理 |
| lifecycle-viewmodel | 2.9.2 | 多平台 ViewModel |
| Markdown renderer M3 | 0.35.0 | 共用 Markdown 界面 |
| Okio | 3.9.0 | 后续下载引擎的文件操作 |
| JUnit | 4.13.2 | JVM 测试 |
| Gradle | 8.10.2 | wrapper 分发版本 |

CMP 1.8 系列的 Material Icons 不再随 UI 组件同步发布，因此单独使用
`org.jetbrains.compose.material:material-icons-core:1.7.3`，不直接套用 CMP 1.8.2。
Kotlin 2.x 使用 `org.jetbrains.kotlin.plugin.compose`，serialization 同时启用编译插件。
这些是脚手架版本选择，本任务没有进行依赖解析或构建验证。

### Target 选择

只配置 `jvm("jvm")`、`iosArm64()` 与 `iosSimulatorArm64()`。
JVM 使用 JDK 17，作为共用代码的编译与测试入口；iOS 对应 arm64 真机和
Apple Silicon Mac 的 arm64 模拟器。无 Android target、Android Gradle 插件或
Android SDK 配置，也未配置 Intel 模拟器的 iosX64 target。
默认层级模板提供共享 `iosMain`；平台网络和数据库依赖分别放在 iosMain / jvmMain。

### Framework 导出策略

两个 iOS target 均生成名为 `shared` 的动态 framework（`isStatic = false`）。
Compose runtime / foundation / material3 / ui / icons、Coroutines、serialization JSON
以及 Ktor common 组件在 commonMain 声明为 `api`，并通过 framework 的 `export` 显式导出。
`transitiveExport = false`，限制导出范围；其余依赖使用 `implementation`，平台 engine
和数据库 driver 不导出为 Swift API。
Swift 通过 `import shared` 调用 `MainViewControllerKt.MainViewController()` 承载 Compose。

Xcode 工程只有一个 iOS Application target：名称和 productName 均为 YunX，
bundle ID 为 `com.yunx.app.ios`，部署目标 iOS 15.0，Swift 5，iPhone 竖屏。
“Build shared framework” 脚本 phase 位于 Sources 之前，调用：

```sh
"${SRCROOT}/scripts/build-shared.sh" "${CONFIGURATION}"
```

动态 framework 由 Frameworks phase 链接，再由 Embed Frameworks
（标准 `PBXCopyFilesBuildPhase`，目标目录为 Frameworks）复制，启用 CodeSignOnCopy
与 RemoveHeadersOnCopy。禁用 Xcode user script sandbox，让 Gradle 能使用项目目录与缓存。
签名采用 Automatic，开发者 Team 需在 Mac 上配置。

### xcconfig 切换设计

Debug / Release target configuration 分别通过 `baseConfigurationReference` 引用
`iosApp/Configuration/Debug.xcconfig` 和 `Release.xcconfig`。
`SRCROOT` 指向仓库内的 `iosApp/` 目录，无固定机器绝对路径。

| 配置 | SDK | shared/build/bin 下的目录 | Gradle link task |
| --- | --- | --- | --- |
| Debug | iphoneos | iosArm64/debugFramework | linkDebugFrameworkIosArm64 |
| Debug | iphonesimulator | iosSimulatorArm64/debugFramework | linkDebugFrameworkIosSimulatorArm64 |
| Release | iphoneos | iosArm64/releaseFramework | linkReleaseFrameworkIosArm64 |
| Release | iphonesimulator | iosSimulatorArm64/releaseFramework | linkReleaseFrameworkIosSimulatorArm64 |

xcconfig 定义 `KOTLIN_FRAMEWORK_BUILD_TYPE`、`KOTLIN_TARGET` 与 `SHARED_FRAMEWORK_PATH`，
默认选择真机，通过 `[sdk=iphonesimulator*]` 条件切换模拟器。
framework 文件引用为 `$(SHARED_FRAMEWORK_PATH)/shared.framework`，链接和嵌入使用同一引用；
`FRAMEWORK_SEARCH_PATHS` 使用该目录，运行时搜索路径包含 `@executable_path/Frameworks`。
脚本使用这些变量选择 Gradle link task，不重复调用其他嵌入签名任务。

### .upstream 只读约定

`.upstream/` 中的 Android 原版与桌面移植参考仅供阅读，不修改其源码、构建文件或文档。
移植实现写入本工程的 shared 与 iosApp，保留上游协议、模型与授权信息。
感谢 [CYQawa/YunX](https://github.com/CYQawa/YunX)，本工程遵循 AGPL-3.0，详见 LICENSE。

### Okio 引入决定

commonMain 使用 `implementation(libs.okio)`，固定版本 3.9.0。
后续下载引擎需要跨平台文件读写、流式写入和路径操作，因此预先引入 Okio，
避免共用业务依赖 JVM 专属 `java.io`。平台目录选择与权限处理留在平台适配层。
Stage 1 尚未实现下载引擎，Okio 不导出为 Swift API。

### 资源与后续阶段

Info.plist 使用 SwiftUI App 生命周期，`UILaunchStoryboardName` 留空，
仅声明 `fetch` 后台模式、中文通知说明与不使用非豁免加密。
Assets / AppIcon 只有合法元数据占位，无真实图片；Mac 上需补图标。
[BUILD-iOS.md](BUILD-iOS.md) 将在 Stage 5 编写。
本次补完仅写入指定文件，没有运行验证、构建或联网命令。
