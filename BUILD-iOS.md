# YunX iOS 构建与运行指南（Mac）

返回 [README](README.md)；移植历史与未验证项见 [PORTING-NOTES](PORTING-NOTES.md)。

2026-10-10 的 0.1.1（8）已通过本地及 GitHub macOS 的 13 项共享测试、Debug arm64 真机 IPA 编译和模拟器启动检查。首次启动进入解析页，原生截图验证系统字号切换与深色模式。构建产物及验证范围见 [UI-ADAPTATION.md](UI-ADAPTATION.md) 与 [夸克登录及构建速度](QUARK-LOGIN-FIX.md)。IPA 需自行签名，真机运行与 Release 构建仍待验证。

## 先了解平台限制

> **后台下载不是前台多线程下载的延续。** 仅 HTTP(S)、非 m3u8、无请求头、无 provider 标识的普通直链可自动交给 NSURLSession 后台单连接任务，并从 byte 0 重新下载；原前台分片保留。需要 Cookie、Authorization、Referer、Range 请求头或网盘逻辑的任务，以及 HLS，会暂停并在回到前台时继续。系统调度、锁屏、冷启动和强制退出行为尚需真机验证；`fetch` 和防自动锁屏均不提供无限后台执行时间。
>
> **不支持 Gopeed 内核和磁力/BT 下载。** Gopeed 设置回退内置 Ktor 引擎；磁力链接会记录失败，不会实际下载。
>
> **登录使用 WKWebView。** Cookie 在导航完成后从 WKHTTPCookieStore 按允许域名提取，再由业务流程校验保存。桌面 Chrome UA 仅改变字符串，不能模拟 Chromium/client hints；SPA 无导航更新、跨域 SSO、验证码和迅雷专有验证均可能需要手动 Cookie/Token 或返回后重试。未实现 localStorage Token 自动提取，也未宣称所有网盘登录可用。

下载目录为应用沙盒 `Documents/Downloads`，不是 Android 公共存储。文件打开/日志分享当前使用 `openUrl(file://)`，原生分享面板、QuickLook 和文件选择流程仍待补齐；不能保证每种文件都可直接打开。设置页“获取最新 iOS 版本”打开 Cloudflare 分发页。通知没有 Android 常驻进度条，拒绝通知授权不影响下载。

## 环境要求

| 项目 | 要求与当前配置 |
| --- | --- |
| Mac | Apple Silicon（arm64）；当前无 `iosX64` target，Intel 模拟器不可用 |
| macOS | Xcode 16.0 的最低基线为 Sonoma 14.5；使用其他 Xcode 版本时按 Apple 支持矩阵匹配 macOS，不能认为所有 16+ 都支持 14.5 |
| Xcode | 完整 Xcode 16+，安装 iOS SDK 和所选模拟器 runtime，首次启动完成组件安装与许可接受；更高版本与当前 Kotlin/Native 的兼容性未验证 |
| JDK | 17；`shared/build.gradle.kts` 使用 `jvmToolchain(17)` |
| Gradle | 使用工程 wrapper，当前分发版本 8.10.2；无需系统 Gradle |
| CocoaPods | **不需要**：无 CocoaPods 插件、Podfile 或 pod 集成；直接链接动态 `shared.framework` |
| Apple 账号 | 模拟器可关闭签名；真机需 Apple Developer 账号及可用 Team/开发签名，个人测试可使用 Xcode Personal Team，分发权限另行配置 |
| 设备 | 工程部署目标 iOS 15.0，iPhone、竖屏和横屏，Swift 5；目标设备还需被所选 Xcode 支持 |

macOS/Xcode 对应关系见 [Apple 官方支持矩阵](https://developer.apple.com/xcode/system-requirements)。工程 CI 文件选择 `macos-15`，Debug 模拟器构建已实际通过。工程固定 Kotlin 2.1.0、CMP 1.8.2、SQLDelight 2.0.2、Ktor 3.1.3，版本来源为 `gradle/libs.versions.toml`。

## 首次准备

以下命令均在 Mac 执行。先在终端进入自己拷贝的项目根目录，即同时包含 `settings.gradle.kts`、`shared/` 和 `iosApp/` 的目录；Linux 工作区 `/home/hatch/workspace/yunx-ios/` 不是 Mac 上要求使用的绝对路径。

1. 安装并注册 macOS JDK 17。配置终端环境：

   ```sh
   export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
   export PATH="$JAVA_HOME/bin:$PATH"
   ```

   不要沿用 `.tools/` 中的 Linux JDK。Xcode 从图形界面启动时未必继承终端环境；脚本会在 `JAVA_HOME` 为空时调用上述 `java_home`，已设置但错误的值则不会自动纠正。

2. 完成 Xcode 首次启动，在 Xcode Settings → Locations 中选择完整 Xcode 的 Command Line Tools；下载所需 iOS 模拟器 runtime。[Kotlin 官方准备说明](https://kotlinlang.org/docs/apple-framework.html)要求安装 Xcode 工具并接受许可。

3. 工程已提交官方 Gradle 8.10.2 wrapper（jar 与启动脚本），并校验分发包 SHA-256。无需 Homebrew Gradle，先检查：

   ```sh
   ./gradlew --version
   ```

   首次运行会下载固定版本的 Gradle；日常构建一律使用 `./gradlew`。

## 编译 shared.framework

已核对 [shared/build.gradle.kts](shared/build.gradle.kts)：`iosArm64()`、`iosSimulatorArm64()` 均配置 `binaries.framework`，`baseName = "shared"`、`isStatic = false`。没有 `XCFramework` 实例或聚合注册，**当前不要使用 `:shared:assembleXCFramework`**。

按设备和配置选一个 task；这里列的是 KMP framework 配置对应的标准 link task，未运行 Gradle 枚举任务。

| 场景 | 完整 task 名 | 产物目录（相对工程根目录） |
| --- | --- | --- |
| 模拟器 Debug | `:shared:linkDebugFrameworkIosSimulatorArm64` | `shared/build/bin/iosSimulatorArm64/debugFramework/shared.framework` |
| 模拟器 Release | `:shared:linkReleaseFrameworkIosSimulatorArm64` | `shared/build/bin/iosSimulatorArm64/releaseFramework/shared.framework` |
| 真机 Debug | `:shared:linkDebugFrameworkIosArm64` | `shared/build/bin/iosArm64/debugFramework/shared.framework` |
| 真机 Release | `:shared:linkReleaseFrameworkIosArm64` | `shared/build/bin/iosArm64/releaseFramework/shared.framework` |

例如：

```sh
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64
./gradlew :shared:linkReleaseFrameworkIosArm64
```

[Kotlin 官方文档](https://kotlinlang.org/docs/apple-framework.html)说明 framework link task 与 `build/bin/<target>/debugFramework` 产物路径规则。Debug 模拟器 framework 已在 CI 生成并由 Xcode 链接、嵌入；其他配置仍为预期输出。首次构建还会下载依赖及 Kotlin/Native 工具链；不需要 Android SDK。

## Xcode 工程、scheme 和配置切换

项目根目录执行：

```sh
open iosApp/iosApp.xcodeproj
```

选择 **YunX** scheme 和 YunX target。共享 scheme 的三个 BuildableReference 已统一指向真实 target ID `A50000000000000000000001`。

Edit Scheme → Run → Info → Build Configuration 选择 Debug 或 Release；现有 scheme 的 Run/Test/Analyze 为 Debug，Profile/Archive 为 Release。切换运行目标选择模拟器或真机，由 SDK 条件自动选择 target，无需手工改绝对路径。

| 配置文件 | SDK | `KOTLIN_TARGET` | `KOTLIN_FRAMEWORK_BUILD_TYPE` | `SHARED_FRAMEWORK_PATH`（相对根目录） |
| --- | --- | --- | --- | --- |
| `iosApp/Configuration/Debug.xcconfig` | iphoneos | IosArm64 | Debug | `shared/build/bin/iosArm64/debugFramework` |
| 同上 | iphonesimulator | IosSimulatorArm64 | Debug | `shared/build/bin/iosSimulatorArm64/debugFramework` |
| `iosApp/Configuration/Release.xcconfig` | iphoneos | IosArm64 | Release | `shared/build/bin/iosArm64/releaseFramework` |
| 同上 | iphonesimulator | IosSimulatorArm64 | Release | `shared/build/bin/iosSimulatorArm64/releaseFramework` |

Xcode 中 `SRCROOT` 为工程根目录下的 `iosApp/`，所以配置用 `$(SRCROOT)/../shared/build/bin/...`；`[sdk=iphonesimulator*]` 覆盖默认真机值。Debug/Release target configuration 已通过 `baseConfigurationReference` 引用对应 xcconfig。链接与嵌入共同使用 `$(SHARED_FRAMEWORK_PATH)/shared.framework`；`FRAMEWORK_SEARCH_PATHS` 指向其父目录，运行时路径含 `@executable_path/Frameworks`。

Sources 前的 **Build shared framework** phase 调用 `iosApp/scripts/build-shared.sh`，该脚本：检查 SDK、拒绝 x86_64、按需找到 JDK 17、切回工程根目录，并拼接 `:shared:link${KOTLIN_FRAMEWORK_BUILD_TYPE}Framework${KOTLIN_TARGET}` 调用 wrapper。传入的 CONFIGURATION 参数不是脚本的选择依据，实际依据是 xcconfig 导出的两个变量。每次 Xcode 构建会执行脚本，是否重编译由 Gradle 判断；预编 framework 不会跳过该 phase。

Frameworks phase 负责链接，Embed Frameworks phase 负责复制并 CodeSignOnCopy。工程已设置 `ENABLE_USER_SCRIPT_SANDBOXING = NO`，保证脚本可访问 Gradle 缓存和工程输出；不要重复加入另一套嵌入/签名脚本。

## 真机签名与运行

1. Xcode Settings → Accounts 添加开发账号，在 YunX target → Signing & Capabilities 启用 Automatically manage signing，选择自己的 Team。
2. 将 `com.yunx.app.ios` 改成自己的唯一 bundle ID，修改 Debug/Release 的 `PRODUCT_BUNDLE_IDENTIFIER`。Info.plist 已使用 `$(PRODUCT_BUNDLE_IDENTIFIER)`，会跟随 target 设置。
3. `shared/src/iosMain/kotlin/com/yunx/app/platform/SecureStore.kt` 的 Keychain service 也是 `com.yunx.app.ios`，它是凭证命名空间，不是 provisioning bundle ID；如果改名须考虑旧凭证迁移/重新登录。后台 session ID `com.yunx.app.bg` 在 Kotlin `BackgroundDownloader.kt` 和 Swift `AppDelegate.swift` 中成对使用，若修改必须同步两处。
4. 连接并信任 iPhone，按设备系统要求启用 Developer Mode，确认设备 iOS ≥15.0 且 Xcode 支持该系统版本。在 scheme 目标中选择该 iPhone，Run（⌘R）。Debug 自动选择 `iosArm64/debugFramework`；想运行 Release 则在 Edit Scheme 中切换配置。
5. 首次运行依次检查初始化、数据库、登录与一个小文件下载。后台长文件、锁屏、通知拒绝授权、强制退出和冷启动恢复需单独验证，模拟器不能替代这些真机检查。

AppIcon 仅有元数据占位，正式归档/分发前需在 `iosApp/iosApp/Assets.xcassets/AppIcon.appiconset/` 补充真实图标；本文不声称已经具备发布条件。

## 模拟器构建与运行

共享 scheme 引用已修复，完成上述环境准备后，Xcode 中选一个已安装 runtime 的 arm64 iPhone 模拟器，Run 即可，不需要真机 Team。

命令行示例在工程根目录执行。先获取本机已有模拟器的 UDID；不写死不存在的设备型号或系统版本：

```sh
xcrun simctl list devices available
```

将下方占位文本换成刚列出的一个 iPhone 模拟器 UDID：

```sh
SIMULATOR_UDID='替换为本机模拟器UDID'
xcodebuild -project iosApp/iosApp.xcodeproj -scheme YunX \
  -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath iosApp/build CODE_SIGNING_ALLOWED=NO build
```

构建成功后再安装并启动，使用相同 UDID；如果模拟器已经 booted，跳过 boot 命令：

```sh
xcrun simctl boot "$SIMULATOR_UDID"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
open -a Simulator
xcrun simctl install "$SIMULATOR_UDID" iosApp/build/Build/Products/Debug-iphonesimulator/YunX.app
xcrun simctl launch "$SIMULATOR_UDID" com.yunx.app.ios
```

`iosApp/build/...` 是上述 `-derivedDataPath` 与配置指定的输出；CI 已实际生成 Debug 模拟器应用。若改了 bundle ID，launch 最后一个参数用自己的 ID；若改用 Release，构建配置改为 Release，安装路径改为 `Release-iphonesimulator/YunX.app`。仅需构建、不安装时也可使用工程 CI 相同的 generic destination：

```sh
xcodebuild -project iosApp/iosApp.xcodeproj -scheme YunX \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 下载 CI 模拟器应用

在通过的 Actions run 中下载 `YunX-simulator` artifact，解压外层下载包，再解压其中的 `YunX-simulator.zip`，获得 `YunX.app`。该包仅适用于 Apple Silicon arm64 模拟器，不含真机签名，不能直接安装到 iPhone。用上面的 `simctl install` 命令安装解压后的应用。压缩使用 `ditto` 保留 framework 内容；artifact 保留 7 天。

CI 使用一次性 iPhone 模拟器，检查启动后的应用进程并保存截图；失败时上传 stdout/stderr、系统日志及 LLDB 崩溃栈。启动检查没有操作欢迎页、登录或下载，不能代替功能测试。

## 常见问题与诊断

### framework 架构、路径或运行时不匹配

真机 arm64 和模拟器 arm64 虽然 CPU 架构相同，但平台不同，不能互换 framework。核对 SDK、Debug/Release、上表目录与对应 link task。出现 `No such module shared` 时先检查脚本是否成功生成当前配置的 framework、xcconfig 是否仍作为 Base Configuration，避免把旧 framework 拖成固定路径。

Intel/x86_64 模拟器会被脚本主动拒绝；当前工程没有可供其使用的 binary。出现启动时 `Library not loaded`，检查 Embed Frameworks 是否包含 `shared.framework`、CodeSignOnCopy 和 `@executable_path/Frameworks`。scheme 提示不可构建或 target 缺失时先修复 BlueprintIdentifier，不能通过重编 Kotlin 解决。

### Kotlin/Native 编译错误去哪看

在 Xcode Report Navigator（⌘9）展开 **Build shared framework** 的完整日志，查找首个 Kotlin 文件位置/`error:`，不要只看末尾的 `PhaseScriptExecution failed`。也可在终端单独运行对应 link task，例如：

```sh
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64 --stacktrace --info
```

若失败发生在 Swift 编译阶段，则展开 Swift Sources 日志，对照生成的 `shared.framework/Headers/shared.h` 检查 `MainViewControllerKt`、`IosLifecycleBridge.shared`、`BackgroundSessionBridge.shared` 和闭包映射。Native WebKit/Security/CoreFoundation/zlib API、SQLDelight 生成代码及 Swift framework 导入已通过 Debug 模拟器编译；这不等同于各功能运行验证。

### Compose 启动时退出

CMP 1.8.2 默认严格检查 Info.plist 的 `CADisableMinimumFrameDurationOnPhone` 必须为 true，缺少此项会抛出错误并终止应用。工程已补齐此配置。另修复原生日志 `NSLog` 的格式：Kotlin String 的 C 可变参数为 UTF-8 指针，必须用 `%s`，用 `%@` 会将字符数据当成 Objective-C 对象并触发 SIGSEGV。LLDB 已确认调用链为 `UpdateChecker.parseRelease → PlatformLog.emit → NSLog`。CI 的 `smoke-simulator.py` 保留 stdout/stderr、应用及相关系统日志、可用崩溃报告，失败诊断作为 Actions artifact 上传。

### wrapper / JDK / Xcode 工具找不到

wrapper jar 缺失、`GradleWrapperMain` / `-jar` 启动错误时重新生成整套 wrapper，见首次准备。`java_home -v 17` 找不到 JVM 时检查 macOS JDK 安装注册；脚本只在 JAVA_HOME 为空时自动查找。终端能构建但 Xcode 找不到 Java 时检查 GUI 的环境来源。SDK/许可错误时在 Xcode 完成首次设置并选择完整 Xcode 的 Command Line Tools。

### Gradle 依赖下载慢（可选镜像）

当前 `settings.gradle.kts` 使用 Plugin Portal、Google、Maven Central。可在**两个现有 repositories 块的开头**分别插入以下 Kotlin DSL，保留原仓库作为补充，不要复制新的同名顶层块：

```kotlin
// pluginManagement.repositories 开头
maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
maven { url = uri("https://maven.aliyun.com/repository/public") }

// dependencyResolutionManagement.repositories 开头
maven { url = uri("https://maven.aliyun.com/repository/public") }
```

镜像地址依据 [阿里云依赖下载说明](https://help.aliyun.com/en/document_detail/436767.html)。这是可选编辑示例，当前工程未添加，也未验证镜像覆盖率或速度；遇到缺失/过期制品要回查原仓库。这里的镜像仅处理插件/Maven 制品，不覆盖 wrapper 的 Gradle zip、Kotlin/Native 工具链或 Xcode runtime。wrapper 下载超时时可在现有 `gradle/wrapper/gradle-wrapper.properties` 进一步调高现有 `networkTimeout=60000`，仍保留 8.10.2 分发版本。

### 登录、后台任务与文件导出“构建成功却不能用”

这些属于运行验证，不能用编译成功替代。先按本文平台限制检查任务是否符合后台接管规则，登录 Cookie 是否在允许域且经过业务校验；网盘接口、链接有效期和验证码行为仍受服务端影响。文件打开仍是 `file://` opener，原生分享/选择未完成；请不要据此假定可以像 Android 一样导出任意文件或目录。

## 构建缓存与 Swift 导出

当前开启 `org.gradle.caching=true`，渲染截图作为测试输出参与缓存。真机与模拟器分别保存 Native 缓存，Xcode 版本和依赖配置参与缓存键。Swift 使用本模块的 UIKit／生命周期桥接，不再显式导出 Compose、Ktor 等完整依赖模块。实测与验证边界见 [夸克登录及构建速度](QUARK-LOGIN-FIX.md)。
