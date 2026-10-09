**构建链路修复（2026-10-09）：** 最新 CI 在 Homebrew Gradle 9.7.1 配置 Kotlin 插件时失败（`DefaultArtifactPublicationSet` 缺失），尚未执行 iOS 编译。现提交 Gradle 8.10.2 官方 wrapper jar 和脚本，校验分发包 SHA-256，CI 直接运行 wrapper；Info.plist bundle ID 改为引用 Xcode 设置。下方各阶段记录保留历史状态。

本轮继续修复编译阻塞：SQL 文件版权说明改为 SQL 行注释（保留授权全文），schema 显式导入 Kotlin Boolean/Int，并为下载任务字段接入 Int/Long 适配器；Ktor 请求类型与 PATCH 构建替换残留 OkHttp 调用；修正中文口令字符编码、更新说明列表操作、README 相对链接、下载目录常量、凭证丢失提示，以及 JVM actual 重复声明。另修复 JVM 文件 facade 与主题 setter 名称冲突。新增共用解析回归测试，实际发现 Ktor 不归一化点路径，现补齐 literal dot segment 归一化并保留转义路径、查询与 fragment。CI 在 Xcode 前执行共用测试。

本轮验证：Linux / Temurin JDK 17.0.20.1 / Gradle 8.10.2 执行 `./gradlew :shared:compileKotlinJvm :shared:jvmTest --no-daemon --console=plain`，结果 `BUILD SUCCESSFUL`；共 3 项回归测试，失败 0、跳过 0。另通过 shell 语法、Info.plist、scheme 引用与 diff 空白检查。iOS target 在 Linux 被禁用，未验证 Kotlin/Native、Swift 或真机运行。GitHub 上传被自动审批阻止（目标与发布授权未确认），这些结果来自本地工作区，远端 CI 尚未运行修复版本。

**Stage 5 当前状态说明（2026-10-09）：** Stage 1、2a、2b、3、4 五个章节均已存在，下面保留各阶段的历史记录，不能把旧 TODO 全部视为当前状态。Mac 构建/签名/运行步骤见 [BUILD-iOS.md](BUILD-iOS.md)，功能边界见 [README.md](README.md)。Stage 5 仅检查文本和源码、修改三份文档，没有运行构建、编译、Gradle、Xcode 或测试。

**JVM 编译验证由协调人在 Linux 上独立进行。** 当前文件中已存在 `shared/src/jvmMain/kotlin/com/yunx/app/platform/BackgroundDownloader.kt` 和 `ClipboardMonitor.kt`，因此 Stage 4 “缺这两个 actual”的描述是当时状态；本文只确认文件存在，不据此虚构编译通过结果。Linux JVM 验证也不能替代 Kotlin/Native、Swift、签名或真机行为验证。

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
[BUILD-iOS.md](BUILD-iOS.md) 已在 Stage 5 定稿；此节保留 Stage 1 当时的实现范围。
本次补完仅写入指定文件，没有运行验证、构建或联网命令。

## Stage 2a

本阶段仅新增 network/update/announcement/util、必要 platform expect/actual 和本记录；未修改 `.upstream/`、UI、db、download、repository、依赖或 Gradle 配置。没有运行构建、编译、Gradle 或测试。

### 数量与清单

上游实际是 network 顶层 **40** 个 Kotlin 文件，另有 model **2** 个；加 update 1、announcement 3、util 8，共 **54** 个移植文件。目标此前不存在，本阶段共新增 **79** 个 Kotlin 文件（54 移植 + 5 network 支持 + 18 platform + 2 ArchiveProbe actual），追加改写本文档 1 个；已有业务 Kotlin 文件改写 0 个。

以下表中移植文件路径相对 `shared/src/commonMain/kotlin/com/yunx/app/`；每个文件都保留原包名/声明名称和 AGPL 文件头。纯模型及 common 可用的常量/纯解析代码直接保留。

| 文件 | 改动点 |
| --- | --- |
| `data/announcement/AnnouncementApi.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；PlatformLog 替代 Log；UTF-8 formEncode 保持 Java 编码结果；Default 替代 IO |
| `data/announcement/AnnouncementReadStore.kt` | 去掉 Context；有序已读 ID、最多 500、StateFlow 保留；LocalSettings 文件及 JsonArray 持久化，PlatformLock 串行化。 |
| `data/announcement/AnnouncementTime.kt` | datetime Instant/本地时区；保留相对时间；兼容 UTC Z、冒号和无冒号偏移。严格解析不再接受 SimpleDateFormat 的宽松溢出日期。 |
| `data/network/BaiduApi.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；UTF-8 formEncode 保持 Java 编码结果；Default 替代 IO |
| `data/network/BaiduApiException.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/BaiduConstants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/C139Api.kt` | Ktor/JSON/Base64/URL 编码；MD5 用 Okio，签名本地日期用 datetime；AES-CBC、安全 IV、gzip 通过平台接口。 |
| `data/network/C139Constants.kt` | Base64 解码转 kotlin.io.encoding，UTF-8 转 decodeToString；Cookie/授权字段保持。 |
| `data/network/DiagnosticNetworkInterceptor.kt` | createClientPlugin + Send hook；只在非 2xx/异常时记 body，UTF-8 上限 1536 字节，URL 脱敏；错误响应 save 后返还可重读 call，成功响应不为日志读 body。 |
| `data/network/GitHubApi.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；UTF-8 formEncode 保持 Java 编码结果；Default 替代 IO |
| `data/network/GitHubCommitDateCache.kt` | 复用 ResponseCache，容量 512、TTL/按前缀失效保持；取消继续传播。 |
| `data/network/GitHubLinkParser.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/GitHubModels.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/GitHubResponseCache.kt` | PlatformLock 保护缓存和 in-flight；CompletableDeferred 合并请求，成功/失败 TTL 10/1 分钟，容量 256；失效版本号阻止过期请求重新写缓存，字节容量按 UTF-8 计算。 |
| `data/network/GitHubTokenStore.kt` | 删除 Context/Android Keystore 依赖；同名 getToken/setToken/hasToken 改为无 Context，PlatformLock 保护会话 Token，禁止落盘明文；安全持久化待安全存储阶段。 |
| `data/network/GuangYaApi.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；UTF-8 formEncode 保持 Java 编码结果；Default 替代 IO |
| `data/network/GuangYaConstants.kt` | ThreadLocalRandom → kotlin.random.Random，设备值格式保持。 |
| `data/network/HttpClients.kt` | Ktor 客户端、Darwin/CIO expect engine、超时/重试/Logging/JSON/HttpCookies；代理切换关闭缓存及重定向 clone 并重建；保留空闲连接回收入口（common 无对应能力，空操作）。 |
| `data/network/ILanzouApi.kt` | Ktor 挂起请求、headers/JSON、不跟随重定向及 URL resolve；AES-ECB 通过平台 aesCrypt，原签名和访问校验重试保留。 |
| `data/network/ILanzouConstants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/LanzouApi.kt` | Ktor 挂起请求、FormDataContent、HeadersBuilder、URL 解析；隔离登录 HttpCookies storage，JS challenge cookie 用 domain storage；保留 HEAD/Range/不跟随重定向；会话 client finally 关闭。 |
| `data/network/LanzouConstants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/Pan115Api.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；UTF-8 formEncode 保持 Java 编码结果；Default 替代 IO |
| `data/network/Pan115Constants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/Pan115Crypto.kt` | XOR 密钥表/分块/填充保持；BigInteger 模幂 → common 固定宽度公钥运算，ByteArrayOutputStream → Okio Buffer；安全 key 用平台随机源，Base64/UTF-8 common 化。 |
| `data/network/Pan123Api.kt` | Ktor/JSON/Base64；CRC32 IEEE common 实现，UTC 偏移签名日期用 datetime；随机数用 Random；不可变 JsonArray 累加保留返回值。 |
| `data/network/Pan123Constants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/Pan123DeviceId.kt` | 移除 Context；LocalSettings 原子 JSON 文件持久化，PlatformLock 保证生成/读取；value() 自动安装设备 ID。 |
| `data/network/Pan123LoginSupport.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/QuarkApi.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；UTF-8 formEncode 保持 Java 编码结果；Default 替代 IO |
| `data/network/QuarkApiException.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/QuarkCdn.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/QuarkConstants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/ShareLinkParser.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/StarSeaApi.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；PlatformLog 替代 Log；Default 替代 IO |
| `data/network/StarSeaConstants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/UCApi.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；UTF-8 formEncode 保持 Java 编码结果；Default 替代 IO |
| `data/network/UCConstants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/XunleiApi.kt` | OkHttp → Ktor HttpClient/HttpRequestBuilder，挂起 get/post/响应 bodyAsText；headers 和协议字段保持；JsonObject/JsonArray 与统一容错扩展，条件字段使用 copy-on-write builder；UTF-8 formEncode 保持 Java 编码结果；Default 替代 IO |
| `data/network/XunleiConstants.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/XunleiDeviceFingerprint.kt` | 移除 Context/SharedPreferences；LocalSettings 持久化三项设备值，PlatformLock，MD5/SHA1 用 Okio；访问值时自动初始化。 |
| `data/network/XunleiKouling.kt` | UTF-8 formEncode 保持 Java 编码结果 |
| `data/network/XunleiWebCredential.kt` | 保留凭据字段/脚本/常量；JSONTokener → Json.parseToJsonElement；URL 信任判断用 Ktor Url；WebSettings 操作改为 desktopClientHints() 数据，WKWebView 装配留 Stage 4。 |
| `data/network/model/ShareExpire.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/network/model/ShareModels.kt` | 纯数据模型/异常/常量/解析函数保持上游实现，无平台依赖。 |
| `data/update/UpdateChecker.kt` | Ktor/JSON/PlatformLog/Default；currentVersion() 改为宿主注入 installedVersion（默认 0.0.0），不依赖 Android packageManager；Release 解析/版本比较保持。 |
| `util/AppLinks.kt` | QQ/GitHub 常量保持；openQQGroup() 去 Context，委托 expect openUrl。 |
| `util/ArchiveProbe.kt` | expect object fast()/deep()；iOS/JVM actual 空列表占位并 TODO，APK/Dex 扫描不跨平台搬运。 |
| `util/DiagnosticLog.kt` | Default 协程 + 2000 有界 Channel；300 行/秒、单文件 2MB/5 份/总 10MB；日志和屏障 flush；Okio 私有文件、ZIP 导出；无 Context/prefs/db 引用。 |
| `util/LogExporter.kt` | 删除 Android logcat/MediaStore/FileProvider；导出应用日志 txt/ZIP 到 cache/download；Path 替 File；share 委托 openUrl，真正 share sheet 留 Stage 4。 |
| `util/LogRedactor.kt` | java.net.URI → Ktor Url；保留仅 scheme/host/非默认 port，绝对 URL 和敏感赋值脱敏；相对 URL 不会被 Ktor 默认 localhost 误记。 |
| `util/PermissionState.kt` | util object 保留无 Context 状态入口，平台 Permission enum + suspend requestPermission；实际权限暂返回 true，设置跳转委托平台，Stage 4 接入。 |
| `util/StorageDirs.kt` | File/Environment → Okio Path 与 expect appDownloadDir，默认下载路径由平台沙盒决定。 |
| `util/TextCipher.kt` | Android Base64 → common Base64 支持，字节 → decodeToString；密文和 XOR key 保持。 |

新增支持文件和平台文件（相对工程根）：

| 文件 | 实现 |
| --- | --- |
| `shared/src/commonMain/kotlin/com/yunx/app/data/network/DomainCookiesStorage.kt` | 按 domain 管理 AcceptAllCookiesStorage，Mutex 串行；按域删除不丢其它会话；close 不清共享 cookie。 |
| `shared/src/commonMain/kotlin/com/yunx/app/data/network/JsonSupport.kt` | kotlinx JSON 容错读字段、不可变构建/条件编辑、单引号规范化与 trailing comma 支持。 |
| `shared/src/commonMain/kotlin/com/yunx/app/data/network/KtorRequests.kt` | 原生 Ktor request builder 映射、get/post/head 分发；表单/URL/UTF-8/Base64 支持；UUID 辅助由安全随机源生成。 |
| `shared/src/commonMain/kotlin/com/yunx/app/data/network/LocalSettings.kt` | 非敏感 JSON 配置文件，Okio 临时文件 + atomicMove；Token 不使用此存储。 |
| `shared/src/commonMain/kotlin/com/yunx/app/data/network/ProtocolCrypto.kt` | Okio MD5/SHA1、CRC32、签名时间和 115 RSA 65537 公钥固定宽度计算。 |
| `shared/src/commonMain/kotlin/com/yunx/app/platform/AppDirs.kt` | common 三个目录 expect；iOS Application Support/Cache/Documents Downloads；JVM ~/.yunx-ios/data/cache/downloads。 |
| `shared/src/commonMain/kotlin/com/yunx/app/platform/OpenUrl.kt` | common expect；iOS 主队列 UIKit openURL；JVM Desktop.browse。 |
| `shared/src/commonMain/kotlin/com/yunx/app/platform/PermissionState.kt` | common Permission enum 与 expect suspend requestPermission；actual true/TODO。 |
| `shared/src/commonMain/kotlin/com/yunx/app/platform/PlatformHttpEngine.kt` | common expect factory；iOS Darwin；JVM CIO。 |
| `shared/src/commonMain/kotlin/com/yunx/app/platform/PlatformLog.kt` | common expect；iOS NSLog 固定格式字符串；JVM println/异常堆栈。 |
| `shared/src/commonMain/kotlin/com/yunx/app/platform/PlatformSupport.kt` | PlatformLock、secureRandomBytes、aesCrypt、gunzip；iOS NSRecursiveLock/Security/CoreCrypto/zlib，JVM ReentrantLock/SecureRandom/JCE/GZIPInputStream。 |
| `shared/src/iosMain/kotlin/com/yunx/app/platform/AppDirs.kt` | common 三个目录 expect；iOS Application Support/Cache/Documents Downloads；JVM ~/.yunx-ios/data/cache/downloads。 |
| `shared/src/iosMain/kotlin/com/yunx/app/platform/OpenUrl.kt` | common expect；iOS 主队列 UIKit openURL；JVM Desktop.browse。 |
| `shared/src/iosMain/kotlin/com/yunx/app/platform/PermissionState.kt` | common Permission enum 与 expect suspend requestPermission；actual true/TODO。 |
| `shared/src/iosMain/kotlin/com/yunx/app/platform/PlatformHttpEngine.kt` | common expect factory；iOS Darwin；JVM CIO。 |
| `shared/src/iosMain/kotlin/com/yunx/app/platform/PlatformLog.kt` | common expect；iOS NSLog 固定格式字符串；JVM println/异常堆栈。 |
| `shared/src/iosMain/kotlin/com/yunx/app/platform/PlatformSupport.kt` | PlatformLock、secureRandomBytes、aesCrypt、gunzip；iOS NSRecursiveLock/Security/CoreCrypto/zlib，JVM ReentrantLock/SecureRandom/JCE/GZIPInputStream。 |
| `shared/src/iosMain/kotlin/com/yunx/app/util/ArchiveProbe.kt` | APK/Dex 检测的 actual 占位：fast/deep 返回空列表。 |
| `shared/src/jvmMain/kotlin/com/yunx/app/platform/AppDirs.kt` | common 三个目录 expect；iOS Application Support/Cache/Documents Downloads；JVM ~/.yunx-ios/data/cache/downloads。 |
| `shared/src/jvmMain/kotlin/com/yunx/app/platform/OpenUrl.kt` | common expect；iOS 主队列 UIKit openURL；JVM Desktop.browse。 |
| `shared/src/jvmMain/kotlin/com/yunx/app/platform/PermissionState.kt` | common Permission enum 与 expect suspend requestPermission；actual true/TODO。 |
| `shared/src/jvmMain/kotlin/com/yunx/app/platform/PlatformHttpEngine.kt` | common expect factory；iOS Darwin；JVM CIO。 |
| `shared/src/jvmMain/kotlin/com/yunx/app/platform/PlatformLog.kt` | common expect；iOS NSLog 固定格式字符串；JVM println/异常堆栈。 |
| `shared/src/jvmMain/kotlin/com/yunx/app/platform/PlatformSupport.kt` | PlatformLock、secureRandomBytes、aesCrypt、gunzip；iOS NSRecursiveLock/Security/CoreCrypto/zlib，JVM ReentrantLock/SecureRandom/JCE/GZIPInputStream。 |
| `shared/src/jvmMain/kotlin/com/yunx/app/util/ArchiveProbe.kt` | APK/Dex 检测的 actual 占位：fast/deep 返回空列表。 |

### Ktor 映射决策

- Request.Builder → 原生 HttpRequestBuilder；fluent 扩展只设置 Ktor URL、headers、method、setBody；执行统一分发到 client.get/post/head。不存在 OkHttp 类型或仿制 OkHttp 客户端。
- 原 FormBody 使用 ParametersBuilder + FormDataContent，并设置 application/x-www-form-urlencoded；已由上游 formEncode 拼好的原始表单用 Ktor TextContent 保留原字节（避免解码/重编码改变签名）。JSON/加密字符串也用 TextContent；本次上游没有 MultipartBody 使用点，不人为新增业务上传实现。Range 的 bytes=a-b 字符串保持。
- expect engine factory 分别返回 Darwin/CIO；HttpTimeout 为 connect 15s / socket 60s / 整请求 90s。Ktor 无 common 独立 writeTimeout；90s 总超时是合理默认，与上游无限总时长不同。
- HttpRequestRetry 最多 1 次；GET 的 5xx，以及 GET/HEAD 的非取消异常可重试；POST 不自动重放，防止登录/文件修改重复提交。上游 retryOnConnectionFailure 会对更多方法尝试恢复。
- 安装 Ktor Logging，但默认 NONE；诊断开关由自定义 Send plugin 控制，避免 Logging 自动泄漏 URL/头/body。成功只记元数据；非 2xx/异常才允许 body，UTF-8 摘要上限 1536 字节，URL 经 LogRedactor。表单/多段请求异常不序列化 body。
- 诊断读取非 2xx 响应前调用 Ktor call.save()，返回保留响应体的 call，防止日志抢占业务解析；代价是诊断模式下错误响应会完整缓存在内存，再截断日志。正常 2xx 不为诊断读取 body。
- HttpCookies 安装 domain storage，每域内部是 AcceptAllCookiesStorage；蓝奏登录隔离 storage，挑战 cookie 也使用同类 storage。clearCookiesForDomain/domain 保留清域入口；domain 删除同时删除其子域存储，父域 cookie 保持父域归属。
- 不跟随重定向通过 source.config clone，并按 source 缓存；保留注入 clientProvider，代理切换关闭 clone 和原缓存，下次获取重建。切换时在途请求可能取消，上游只置空缓存而不关闭既有客户端。
- JSONObject/JSONArray 使用真正 JsonObject/JsonArray，不保留 org.json 包或包装类型。容错扩展保持空字符串/0/false、数组安全索引与容器字符串形式；所有写入保留不可变返回值。单引号 key/value 和末尾逗号作兼容处理；JSONTokener 的任意非标准语法不保证全部模拟。
- Base64 用 kotlin.io.encoding，解码去空白并补 padding，JWT 用 UrlSafe；Kotlin 2.1 不调用 2.2 才提供的 withPadding。手写 UTF-8 formEncode 保持空格 +、星号 *、波浪号 %7E 的 Java 规则。
- MD5/SHA1 使用已有 Okio；CRC32/RSA 公钥计算使用 common Kotlin；AES-ECB/CBC 与安全随机、gzip 放 platform actual。没有添加依赖或更改版本。

### 已知差异与待后续处理

1. **未验证编译/运行**：遵守本阶段禁止构建、编译、Gradle 的约束；Ktor API、Native CoreCrypto/zlib/UIKit 的签名、各平台网络/代理/加密互通与签名向量，留独立验证阶段。
2. **GitHub Token 暂不跨重启保存**：本阶段不移植 security/repository，采用会话内存实现，严禁明文落盘；后续安全存储阶段需接 iOS Keychain/JVM 安全凭据存储。无 Android 密文或 SharedPreferences 数据迁移。
3. **权限/完整性/分享**：权限 actual true，ArchiveProbe 空列表（按任务要求占位）；原设置入口改 app-settings:，JVM 未必有 handler；WKWebView UA/client hints、真实权限、native share sheet 和 QQ scheme 可用性由 Stage 4 接入。
4. **下载客户端差异**：common engine 配置没有复制 OkHttp 的强制 HTTP/1.1、64 队列、8 空闲连接/1 分钟池参数；Darwin/CIO 各自管理连接。evictIdleConnections() 保留但为空操作，下载阶段需验证并发、流式读取和内存。当前 provider API 请求采用 Ktor 常规缓冲响应，未来分片业务应使用 prepareGet/流式响应，不应经 executeRequest 读取大文件。
5. **日志**：应用自有文件替代 Android logcat，启动时调用 install/setEnabled，诊断默认关闭，不读取尚未移植 SettingsRepository；flush/export 为 suspend；队列满或超限直接丢，未复制上游周期性的丢弃数量报告；ZIP 用 stored entries 不压缩，保留标准 ZIP/CRC32。诊断错误响应 save 的内存差异见上节。
6. **平台路径/签名**：业务 API 去掉 Android Context；StorageDirs/日志导出返回 Okio Path；宿主注入 UpdateChecker.installedVersion，默认 0.0.0；openUrl iOS 返回的是本地接受请求，系统是否成功打开异步决定。iOS 使用私有沙盒，不访问 Android 公共目录。
7. **解析/并发**：datetime 时间解析严格拒绝溢出日期；JSON null 取默认值（不返回文字 null），与任务要求一致；单引号/逗号兼容仍需真实响应验证。GitHub 缓存使用锁/flight 原子登记，按 UTF-8 字节计大小（上游实际按字符长度）；取消在缓存层传播。小配置文件使用同步 Okio + 原子替换，UI 后续应从合适调度上下文调用。

### 文本自查（不是编译验证）

- 54/54 上游目标文件存在；AGPL 注释 54/54 保留；包名与源文件一致；新增 Kotlin 总数 79。
- 任务原样命令 `grep -rn "^import android\|^import okhttp3\|^import org.json\|^import java.net" shared/src/commonMain` **有 4 条既存命中**：Stage 1 的 `App.kt:3–6`，均为 `androidx.compose.*`。`^import android` 会同时匹配 `androidx`，这不表示 Android framework 依赖；依照禁止触碰 UI 的约束，保留 App.kt 未修改。
- 准确包界限命令 `rg -n '^import (android\.|okhttp3\.|org\.json\.|java\.|javax\.|dalvik\.)' shared/src/commonMain` **0 条命中**；本阶段目录的原样 grep 也为 0 条。
- `Dispatchers.IO`、OkHttp Request.Builder/CookieJar、org.json JSON 类型和 Android Context 在本阶段业务代码中均已移除；没有 java.* 或 javax.* 的 fully qualified 运行时代码。
- 尚无 Git 仓库（git status 返回 not a git repository）；未做 commit。脚本只写本阶段目标路径和本文档，源目录只读。

接口参考（只查文档/源码，未解析依赖或执行构建）：[Ktor 自定义 plugin](https://ktor.io/docs/client-custom-plugins.html)、[Ktor 3.1.3 call.save 源码](https://github.com/ktorio/ktor/blob/3.1.3/ktor-client/ktor-client-core/common/src/io/ktor/client/call/SavedCall.kt)、[Ktor 3.1.3 ProxyConfig](https://github.com/ktorio/ktor/blob/3.1.3/ktor-client/ktor-client-core/common/src/io/ktor/client/engine/ProxyConfig.kt)、[Ktor 3.1.3 retry](https://github.com/ktorio/ktor/blob/3.1.3/ktor-client/ktor-client-core/common/src/io/ktor/client/plugins/HttpRequestRetry.kt)、[Kotlin withPadding 起始版本](https://kotlinlang.org/api/core/kotlin-stdlib/kotlin.io.encoding/-base64/with-padding.html)。


## Stage 2b — 数据层存储、备份、下载与仓库移植

本阶段仅写源码与做文本对照；没有执行构建、编译、Gradle 或运行测试。Stage 2a 的 PlatformLog / PlatformHttpEngine / AppDirs / OpenUrl / PermissionState expect 均确认存在。上游只读，AGPL-3.0 文件头保留；未修改 network、util、ui 或上游源码。工程当前没有 Git 元数据。

### 实现与决策

- **SQLDelight**：12 张表（10 个账号表、download_task、bookmark）、全部 62 个 DAO 方法已翻译；Entity/DAO 包名与公开方法保持。AppDatabase 为普通单例包装类，提供 getInstance()/get()、raw DAO 及 SecureAccountDaos 包装入口。仓库继续注入 DAO 接口，默认账号 DAO 来自 SQLDelight 数据库，测试/调用方仍可显式注入；业务公开函数签名保留。
- **query 命名冲突**：所有查询集中 YunXDb.sq，而账号 DAO 均有 observeAccount/getAccount/upsert/clear 等同名方法；同一文件不能重复 SQLDelight 标签，因此采用 `<Dao类名>_<原方法名>`，原 DAO 方法名完全保留。下方有逐方法映射。此为对“同一 .sq 且所有 query 方法名原样”的合理消歧。
- **迁移**：9.sqm–18.sqm 逐条保留 Room 9→19 的 ALTER/CREATE 与默认值；最新 schema version 为 19。DbSchema 对未知开发版 1–8 沿用破坏性重建，其余版本保留原数据。查询显式列出字段，避免老库 ALTER ADD COLUMN 后物理列顺序不同导致 mapper 错位。整数映射为 Kotlin Int、homePinned 映射 Boolean。insert 与 last_insert_rowid 在同一 SQLDelight 事务内；Flow 使用 Query.Listener、conflate 与 Default 调度。
- **驱动**：iOS NativeSqliteDriver(DbSchema, "yunx.db")，DbSchema 委托 YunXDb.Schema 并补早期开发库策略；JVM JdbcSqliteDriver 选择文件 `~/.yunx-ios/yunx.db`，以 PRAGMA user_version 与事务创建/迁移，拒绝较新版本。未选择 IN_MEMORY。Room 密钥不可能从 Android Keystore 导出；旧 Android 密文不能直接作为跨设备登录迁移，使用口令备份恢复。
- **SecureStore**：common expect saveSecret/loadSecret/deleteSecret。iOS 为 kSecClassGenericPassword，固定 service + 每个 key 的 account，SecItemUpdate/Add/CopyMatching/Delete；AfterFirstUnlockThisDeviceOnly。只有 errSecItemNotFound 返回 null，其他错误视为暂不可访问，不删凭证。CF 对象在每次操作结束释放。
- **JVM 文件密钥与 PBKDF2 简化**：`~/.yunx-ios/secret.key` 首次由 common 安全随机生成 32 字节，临时文件原子替换，支持 POSIX 时目录 0700、文件 0600；其他 secret 用键名 SHA-256 文件名。上游只读快照没有桌面 FileCredentialCipher，采用固定域盐 YUNX_DESKTOP_V1 + 10000 次 PBKDF2-HMAC-SHA256 从随机文件 secret 派生 AES-256 key，common cipher 缓存派生结果；iOS 直接使用 Keychain 的 32 字节密钥。该简化不增加用户口令、不依赖机器名，文件本身没有口令加密，安全性依赖本机用户文件权限。
- **凭证加密**：保留 `yunx:v1:<Base64 IV>:<Base64 ciphertext+tag>`、12 字节随机 IV、128 位 GCM tag、purpose AAD、旧明文读后重加密。GCM 的 CTR/GHASH 在 common 实现，AES 块复用 Stage 2a 的 aesCrypt ECB（取第一个无填充的数据块）；PBKDF2-HMAC-SHA256 用 okio。没有 common javax.crypto/java/security 依赖。暂时失钥不删数据，永久失效/坏密文逐记录自愈，并保留 credential_key_lost 偏好标记；损坏的密钥长度只重建该密钥，不批量清表。AndroidKeystoreCredentialCipher 为兼容类型别名。
- **GitHub 持久化范围冲突**：任务要求 GitHubTokenStore 自愈，同时明确禁止修改 network；现有 Stage 2a `data/network/GitHubTokenStore.kt` 是会话内存实现，无法在不改它的情况下透明改成持久化。按“不动 network”推进：新增 security/GitHubCredentialStorage，保留 github_token_encrypted 键与 github_token AAD、解密失败清密文/暂时失钥保留；AuthBackupManager 导出读取持久化或当前会话 token，导入同时写安全存储与既有会话入口。现有 GitHubApi 的读取入口仍须后续阶段接到该安全存储，这一点未冒称完成。
- **SettingsStore**：Stage 2a 未提供，新增完整 String/Boolean/Int/Long/Float/remove expect/actual；iOS NSUserDefaults.standardUserDefaults，JVM Preferences.userRoot().node("yunx")。SettingsRepository 所有键名、默认值、钳位范围、按平台线程数、常量保留；仅移除 Android Context 与 edit/apply。
- **备份**：保留所有 10 平台字段（包括 authType）与顶层 GitHub token、备份 app/version、导入计数/旧字段兼容。AuthCrypto 保留 YUNX_AUTH_V2 + salt(16) + IV(12) + ciphertext+tag，210000 次 PBKDF2；V1 10000 次仍可解密，导出口令最少 8 位。JSON 使用 kotlinx.serialization，私有小型 builder 仅限备份目录。文件经 AppDirs + okio 写沙盒下载目录，.yunx/.json 扩展名保留，时间戳用毫秒。新增 readBackup(path) 供文件选择器接入。
- **okio**：选直接使用 FileSystem.SYSTEM/Path/BufferedSink，未新增 PlatformFile。libs.versions.toml 已有 okio=3.9.0 与 commonMain implementation(libs.okio)，本阶段确认并复用，没有重复依赖或修改版本文件。
- **下载**：Ktor prepareGet/execute/bodyAsChannel 流式 64KiB 缓冲；任务取消传播至请求 Job。保留 Range/Content-Range 严格核验、200 忽略 Range 后单流回退、HTML 错页拒绝、精确大小校验、分片磁盘续传、暂停保留/删除清理、任务和分片重试、按平台线程设置、全局限速、任务并发闸门、进度 500ms 落库、分片与可选整文件 SHA-256、完成回调、备用 URL、调试快照及慢连接抢占。
- **下载调度取舍**：KMP 没有便携 JVM 堆上限/线程池统计，以全局 32 个在飞分片作保守默认，单文件最多 8 个 Range worker；用户偏好仍保留 1–512，持久化分片计划不随恢复时设置变化。当前实现使用稳定静态 Range 分区，没有移植上游 JVM elastic allocator 的动态末尾再分片；保留定期慢连接抢占与手动抢占。不可用的 heap/pool 调试值为 -1。CoroutineDispatcher 使用 Default，去掉 JVM 自建线程池/原子类/ConcurrentHashMap，跨协程状态由 PlatformLock/Mutex/Semaphore 保护。Ktor 的超时/重试沿用 Stage 2a 配置，尚未做性能验证。
- **HLS**：HTTPS-only、显式最多 5 次重定向、跨 origin 去 Cookie/Authorization/Referer 等敏感头；独立空 cookie jar 避免继承全局 cookie。保持 1MiB playlist、20000 segment、512MiB 单 segment、100GiB 总量上限，支持 master 首个 variant 与 EXT-X-MAP；加密和 BYTERANGE 明确失败，失败/取消删除临时文件。
- **文件保存**：SAF/tree Uri/MediaStore 替换为沙盒路径，拒绝 content: 旧目录并提示重新选择；sanitize + canonicalize 拒绝遍历/符号链接越界，重名加序号。同目录临时文件写完校验后 atomicMove，分片仅在保存成功后删除；不删除尚需恢复的 part 文件。
- **Gopeed/磁力**：没有移植 data/gopeed，也不 spawn 子进程；engine==gopeed 记录警告回退 builtin。历史 engineTaskId 继续任务时清空并转 builtin。磁力任务入队即 STATUS_FAILED，错误为“iOS 版暂不支持磁力/BT 下载”。MagnetLink 的识别/名称/hash 逻辑保留，唯一平台替换是 JDK URLDecoder → Ktor percent 解码（+ 仍为字面 +）。
- **下载服务与通知**：DownloadService 替换 DownloadServiceController；引用计数阻止休眠，iOS 主队列设置 UIApplication.idleTimerDisabled，JVM 空实现。Notifier expect + JVM 空实现 + iOS TODO(Stage 4) 空壳。不将此描述为 iOS 后台下载能力；应用进入后台仍可能被系统挂起。
- **仓库退出登录**：Android CookieManager/WebStorage 替换 clearLoginWebData expect，iOS 主队列 WKWebsiteDataStore 清理；JVM 无嵌入式 WebView，空实现。保留业务 DAO clear 与 API 方法；Stage 2a Ktor cookies 的平台域清理进一步见待办。
- **崩溃**：CrashActivity 丢弃（Android UI），common CrashHandler + installCrashHandler expect；JVM 幂等默认异常钩子写 appDataDir/crash 的脱敏日志并委托前任 handler；iOS NSSetUncaughtExceptionHandler 仅安装占位。NSException 钩子不等于 Kotlin/Native 全部崩溃捕获。
- **签名适配**：21 个 repository 的公开业务方法签名逐项保持；注入 DAO 默认值仅便于 Stage 3 装配。Android Context 参数在本阶段存储/备份/下载接口删除；JVM File/OutputStream/AtomicBoolean/MessageDigest 参数分别替换 Path/BufferedSink/ChunkPreemption/增量摘要回调。Stage 3 调用处应按此装配，未触碰 UI。

### 静态对照结果（非编译/运行验证）

- 上游 db 26、prefs 1、security 1、backup 2、download 11、repository 21、crash 2；所有应移植文件均存在，DownloadService 改名，CrashActivity 按要求丢弃。
- 12/12 表与全部列来自 Entity；62/62 原 DAO 方法有对应 SQL query；公开 repository 方法与偏好键列表逐项对照通过。
- `rg -n '^import (android\.|okhttp3\b|org\.json\b|java\.)' shared/src/commonMain`：0 命中。androidx.compose 是合法 CMP 依赖，不属于 android.。
- AGPL 文件头保留。没有运行 Gradle、构建、编译、SQLDelight 代码生成或测试；本阶段结论不代表可编译。

### 未解决与后续接线

1. 遵守禁止构建，SQLDelight 生成类型、Native Security/CoreFoundation/WKWebKit/异常 hook 的 cinterop 签名，以及 Ktor/okio 调用须在独立验证阶段检查；AES-GCM/PBKDF2 Android↔iOS↔JVM 互通需用固定向量和备份文件验证。
2. **GitHubApi 持久化入口未接**：network 禁改导致原 GitHubTokenStore 会话实现仍在。安全 storage 与备份路径已实现，后续明确允许改该入口时委托到 GitHubCredentialStorage；也需把 UI token 保存入口切换到安全存储。
3. Stage 4 实现 iOS UserNotifications；NSException hook 当前为空壳；后台下载仍不是 NSURLSession background transfer，idle timer 只阻止前台休眠。
4. 当前静态分区下载替代 JVM 动态 elastic allocator，需后续设备性能验证；iOS security/GCM/PBKDF2 有 CPU 开销，调用处应保持后台调度。历史 Android key 不可迁移，使用 .yunx 认证备份。
5. iOS 登录 WebView 清理已接 WKWebsiteDataStore，但没有修改 Stage 2a 网络 cookie 组件；各平台 logout 的 Ktor 域 cookie 清理与 UI 登录态装配应在后续集成明确完成。
6. 下载的完成云端清理回调只在内存，重启后无法恢复任意 lambda（上游也有此限制）；backup 文件选择/分享和目录权限由 Stage 3/4 接入。

### DAO → SQL query 清单

```text
BaiduAccountDao.observeAccount → BaiduAccountDao_observeAccount
BaiduAccountDao.upsert → BaiduAccountDao_upsert
BaiduAccountDao.getAccount → BaiduAccountDao_getAccount
BaiduAccountDao.clear → BaiduAccountDao_clear
BookmarkDao.observeAll → BookmarkDao_observeAll
BookmarkDao.observeHomePinned → BookmarkDao_observeHomePinned
BookmarkDao.observeCategories → BookmarkDao_observeCategories
BookmarkDao.insert → BookmarkDao_insert
BookmarkDao.updateCategory → BookmarkDao_updateCategory
BookmarkDao.updateHomePinned → BookmarkDao_updateHomePinned
BookmarkDao.updateHomeLabel → BookmarkDao_updateHomeLabel
BookmarkDao.delete → BookmarkDao_delete
C139AccountDao.observeAccount → C139AccountDao_observeAccount
C139AccountDao.upsert → C139AccountDao_upsert
C139AccountDao.getAccount → C139AccountDao_getAccount
C139AccountDao.clear → C139AccountDao_clear
DownloadTaskDao.observeAll → DownloadTaskDao_observeAll
DownloadTaskDao.insert → DownloadTaskDao_insert
DownloadTaskDao.get → DownloadTaskDao_get
DownloadTaskDao.updateProgress → DownloadTaskDao_updateProgress
DownloadTaskDao.updatePlan → DownloadTaskDao_updatePlan
DownloadTaskDao.updateRequestHeaders → DownloadTaskDao_updateRequestHeaders
DownloadTaskDao.markInterruptedAsPaused → DownloadTaskDao_markInterruptedAsPaused
DownloadTaskDao.updateStatus → DownloadTaskDao_updateStatus
DownloadTaskDao.updateError → DownloadTaskDao_updateError
DownloadTaskDao.complete → DownloadTaskDao_complete
DownloadTaskDao.delete → DownloadTaskDao_delete
DownloadTaskDao.updateEngineTaskId → DownloadTaskDao_updateEngineTaskId
DownloadTaskDao.updateFileName → DownloadTaskDao_updateFileName
DownloadTaskDao.listSyncableEngineTasks → DownloadTaskDao_listSyncableEngineTasks
GuangYaAccountDao.observeAccount → GuangYaAccountDao_observeAccount
GuangYaAccountDao.upsert → GuangYaAccountDao_upsert
GuangYaAccountDao.getAccount → GuangYaAccountDao_getAccount
GuangYaAccountDao.clear → GuangYaAccountDao_clear
ILanzouAccountDao.observeAccount → ILanzouAccountDao_observeAccount
ILanzouAccountDao.upsert → ILanzouAccountDao_upsert
ILanzouAccountDao.getAccount → ILanzouAccountDao_getAccount
ILanzouAccountDao.clear → ILanzouAccountDao_clear
LanzouAccountDao.observeAccount → LanzouAccountDao_observeAccount
LanzouAccountDao.upsert → LanzouAccountDao_upsert
LanzouAccountDao.getAccount → LanzouAccountDao_getAccount
LanzouAccountDao.clear → LanzouAccountDao_clear
Pan115AccountDao.observeAccount → Pan115AccountDao_observeAccount
Pan115AccountDao.upsert → Pan115AccountDao_upsert
Pan115AccountDao.getAccount → Pan115AccountDao_getAccount
Pan115AccountDao.clear → Pan115AccountDao_clear
Pan123AccountDao.observeAccount → Pan123AccountDao_observeAccount
Pan123AccountDao.upsert → Pan123AccountDao_upsert
Pan123AccountDao.getAccount → Pan123AccountDao_getAccount
Pan123AccountDao.clear → Pan123AccountDao_clear
QuarkAccountDao.observeAccount → QuarkAccountDao_observeAccount
QuarkAccountDao.upsert → QuarkAccountDao_upsert
QuarkAccountDao.getAccount → QuarkAccountDao_getAccount
QuarkAccountDao.clear → QuarkAccountDao_clear
UCAccountDao.observeAccount → UCAccountDao_observeAccount
UCAccountDao.upsert → UCAccountDao_upsert
UCAccountDao.getAccount → UCAccountDao_getAccount
UCAccountDao.clear → UCAccountDao_clear
XunleiAccountDao.observeAccount → XunleiAccountDao_observeAccount
XunleiAccountDao.upsert → XunleiAccountDao_upsert
XunleiAccountDao.getAccount → XunleiAccountDao_getAccount
XunleiAccountDao.clear → XunleiAccountDao_clear
```

### 本阶段文件清单

以下均为本阶段新增/移植源码；PORTING-NOTES.md 为追加更新，依赖配置已有 okio 因而未修改。

```text
shared/src/commonMain/kotlin/com/yunx/app/crash/CrashHandler.kt
shared/src/commonMain/kotlin/com/yunx/app/data/backup/AuthBackupManager.kt
shared/src/commonMain/kotlin/com/yunx/app/data/backup/AuthCrypto.kt
shared/src/commonMain/kotlin/com/yunx/app/data/backup/BackupJson.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/AppDatabase.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/BaiduAccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/BaiduAccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/BookmarkDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/BookmarkEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/C139AccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/C139AccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/DbSchema.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/DownloadTaskDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/DownloadTaskEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/GuangYaAccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/GuangYaAccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/ILanzouAccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/ILanzouAccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/LanzouAccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/LanzouAccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/Pan115AccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/Pan115AccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/Pan123AccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/Pan123AccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/QuarkAccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/QuarkAccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/SecureAccountDaos.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/SqlDaos.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/UCAccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/UCAccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/XunleiAccountDao.kt
shared/src/commonMain/kotlin/com/yunx/app/data/db/XunleiAccountEntity.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/ChunkDownloader.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/DownloadDebugLog.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/DownloadManager.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/DownloadPathPolicy.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/DownloadPlatform.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/DownloadSaver.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/DownloadServiceController.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/HlsDownloader.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/HlsRequestPolicy.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/HttpRangePolicy.kt
shared/src/commonMain/kotlin/com/yunx/app/data/download/MagnetLink.kt
shared/src/commonMain/kotlin/com/yunx/app/data/prefs/SettingsRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/BaiduAccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/BaiduResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/C139AccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/C139ResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/GuangYaAccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/GuangYaResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/ILanzouAccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/ILanzouResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/LanzouAccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/LanzouResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/Pan115AccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/Pan115ResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/Pan123AccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/Pan123ResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/QuarkAccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/QuarkResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/ShareResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/UCAccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/UCResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/XunleiAccountRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/repository/XunleiResolveRepository.kt
shared/src/commonMain/kotlin/com/yunx/app/data/security/CredentialCipher.kt
shared/src/commonMain/kotlin/com/yunx/app/data/security/GitHubCredentialStorage.kt
shared/src/commonMain/kotlin/com/yunx/app/data/security/PortableCrypto.kt
shared/src/commonMain/kotlin/com/yunx/app/platform/Notifier.kt
shared/src/commonMain/kotlin/com/yunx/app/platform/SecureStore.kt
shared/src/commonMain/kotlin/com/yunx/app/platform/SettingsStore.kt
shared/src/commonMain/sqldelight/com/yunx/app/data/db/10.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/11.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/12.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/13.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/14.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/15.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/16.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/17.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/18.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/9.sqm
shared/src/commonMain/sqldelight/com/yunx/app/data/db/YunXDb.sq
shared/src/iosMain/kotlin/com/yunx/app/crash/CrashHandler.kt
shared/src/iosMain/kotlin/com/yunx/app/data/db/DbDriver.kt
shared/src/iosMain/kotlin/com/yunx/app/platform/SecureStore.kt
shared/src/iosMain/kotlin/com/yunx/app/platform/SettingsStore.kt
shared/src/jvmMain/kotlin/com/yunx/app/crash/CrashHandler.kt
shared/src/jvmMain/kotlin/com/yunx/app/data/db/DbDriver.kt
shared/src/jvmMain/kotlin/com/yunx/app/platform/SecureStore.kt
shared/src/jvmMain/kotlin/com/yunx/app/platform/SettingsStore.kt
PORTING-NOTES.md (append only)
```


## Stage 3 — UI 层移植（ViewModel + Compose → commonMain）

### 范围与入口

上游 `.upstream/yunx-orig/app/src/main/kotlin/com/yunx/app/ui/` 实际为 **109 个 Kotlin 文件**：viewmodel 26、screens 46、components 8、items 2、resolve 3、navigation 1、theme 5、login 16、根目录 2（MainScreen、SnackbarController）。全部有 commonMain 对应文件，原始 AGPL-3.0-or-later 文件头逐文件保留。没有独立 ui/clipboard 目录；剪贴板代码原来分布于 ResolveScreen、AccountSheet、BookmarkScreen、下载页与分享面板。

公共 `@Composable fun App()` 已替换 Stage 1 占位界面，接入主题与 MainScreen。保留解析输入、分享文件列表/目录导航/转存、下载管理、网盘账户与各平台云盘、设置、关于六大界面。现有 Swift `ContentView.swift` 的 `UIViewControllerRepresentable` → `MainViewController()` → `App()` 链路符合约定，无须修改 Swift。

Android 的 YunXApp/Application、MainActivity 与 LaunchGate/ContentProvider 入口合并到 App.kt 的单次初始化：安装凭证恢复、设备标识、诊断/下载日志，恢复代理，清理下载半成品，然后建立仓库和 ViewModel。Android 包扫描、反射防注入、Activity Intent 分发和 Gopeed .so 初始化没有带入 commonMain。直接打开下载 Tab 的 MainScreen 参数保留，原生通知点击接入留到平台阶段。

新增 4 个公共 UI 文件（CookieLoginScreen、CookieLoginWebView、PlatformImage、UiSupport）与 6 个 UI actual 文件。另增加 common/ios/jvm UiPlatform 桥接，并把现有 iOS 通知权限 actual 从占位 true 改为 UNUserNotificationCenter 实际申请。为上游大量 outlined/扩展图标补充 `material-icons-extended:1.7.3` 的 commonMain implementation；这是 shared/build.gradle.kts 唯一修改，未运行 Gradle。

### 组件及平台替换对照表

| 上游组件 / API | Stage 3 实现 | 说明 |
| --- | --- | --- |
| Android ViewModelProvider.Factory 的 Class<T> / .java | KClass<T> + CreationExtras | 26 个文件就位；使用 androidx.lifecycle.ViewModel / viewModelScope，实际源中未发现 AndroidViewModel 或 SavedStateHandle |
| Android viewModel Compose helper | 公共 viewModel(factory) + ViewModelStore | remember 保持实例；退出整个主界面组合时 store.clear() 取消 ViewModel 协程；不额外引入 lifecycle-viewmodel-compose |
| MaterialExpressiveTheme / MotionScheme | MaterialTheme + 公共 spring/tween 规格 | 保留深浅色、字体、现有配色与列表组形状 |
| MediumFlexibleTopAppBar | MediumTopAppBar | 标题/动作与折叠行为保留 |
| ShortNavigationBar / Item | NavigationBar / NavigationBarItem | 四个主 Tab 与横向 NavigationRail 保留；尺寸采用标准组件 |
| LoadingIndicator | CircularProgressIndicator | YunXLoading 调用接口不变 |
| LinearWavyProgressIndicator | LinearProgressIndicator | 确定/不确定进度保留，波浪与 waving 参数不再影响绘制 |
| HorizontalFloatingToolbar | Surface + Row + IconButton | 多选批量操作保留 |
| ButtonGroup / ToggleButton | Row + FilterChip | 提取码有/无切换保留 |
| Expressive 扩展 Shapes | 标准 Shapes 五档 | 保留列表组圆角；新增 Expressive 圆角档不带入 |
| Android 动态壁纸取色 / Hct、TonalSpot | 应用配色 / 自定义 primary | iOS 默认回退应用蓝色；自定义种子色仅替换 primary，完整色调算法待补 |
| WebView / WebViewClient / CookieManager | expect CookieLoginWebView | iOS WKWebView；JVM 手动输入 Cookie 并可打开外部浏览器 |
| AndroidView / WebView 生命周期 | Compose UIKitView + DisposableEffect | Swift 外层仍使用 UIViewControllerRepresentable；销毁时 stopLoading 并移除 navigationDelegate |
| WebViewJs / DiagnosticWebViewClient | 公共 Cookie 序列化 / 仅记录导航 host | 不移植 Android JS 对象或输出凭证日志 |
| 自研 Bitmap 网络图片（上游没有 Coil import） | expect PlatformImage + loadRemoteBitmap | iOS AsyncImage：URLSession + UIImage 校验 + Compose bitmap；JVM 显示文字占位，Markdown 图片返回 null |
| Bitmap 图片缓存 / Collections | PlatformLock + 有界公共缓存 | 4 并发，32 张/32 MiB 像素缓存；iOS 单响应 8 MiB、像素 800 万上限；SVG 图片支持待补 |
| java.util.Date / SimpleDateFormat / Calendar | kotlinx.datetime | 账户更新时间、文件修改时间、123 分享到期时间与冷却计时 |
| java.net.URI / URLEncoder | Ktor Url / encodeURLPathPart | 保留源站 Referer、可信域校验与 GitHub 路径编码 |
| Android Log | PlatformLog | 保留原有诊断级别 |
| Toast | expect showToast | iOS 经全局 Snackbar 显示；JVM println，不叠加 UIAlertController |
| Intent / Uri / Markdown 默认打开链接 | expect openUrl + LocalUriHandler | GitHub 关于/公告/README/更新链接统一调用平台 opener |
| ClipboardManager / ClipData | expect readClipboard / copyToClipboard | iOS UIPasteboard；JVM AWT 剪贴板，读写失败可降级 |
| Android 剪贴板监听 / 生命周期监听 / 2s 轮询 | expect OnForeground | iOS 进入页面及 UIApplicationDidBecomeActive 时检测；关闭开关不读取，取消后台/周期轮询；JVM 进入页面检测 |
| SAF / WRITE_EXTERNAL_STORAGE / 电池优化 | App 沙盒目录说明 | 下载忽略旧 SAF URI，使用 appDownloadDir；无全文件访问或电池优化授权流程 |
| Onboarding 权限页 | 仅通知权限入口 | 不把通知授权设为使用应用的必要条件 |
| QQ 加群 scheme | 复制 AppLinks.QQ_GROUP | 新设置/引导页直接复制群号 |
| APK 更新安装 | 查看 GitHub 发布页 | Release 说明、忽略/稍后保留，不为 iOS 更新自动下载/安装 APK |
| Gopeed 内核页面 | 可返回的引擎说明页 | Stage 2 无 Gopeed 服务；启动选择 builtin，真实下载使用既有 Ktor 引擎 |
| Android BackHandler | 公共占位 helper + 页面可见返回按钮 | 原生返回手势/桌面 Escape 接入待 Stage 4 |

### 文案与资源

**iOS 版文案内联，Localizable.strings 待补。** 检查了上游 strings.xml：UI 本身大部分已使用中文文字字面量，本阶段保留这些文案，并为通知权限、沙盒目录、更新发布页和平台限制加入内联中文说明。公共 UI 无 Android R/stringResource/getString 资源调用。需要后续统一抽取国际化文案；原 AboutScreen 的项目介绍沿用上游文字。

`shared/src/commonMain/composeResources/` 已建立并留空。未复制 Android drawable/mipmap，当前图标改为 Material Cloud；Mac 上补资源清单：

- `drawable/icon`：关于页/引导页应用图标以及主题页默认图标预览。
- `drawable/icon2`：主题页替代图标预览；iOS Alternate App Icon 及 Assets.xcassets 配置待补。
- `drawable/weixin`：支持开发二维码；目前支持页展示说明及项目链接，不展示伪造二维码。
- Android mipmap 启动图标的 iOS AppIcon 尺寸集合与正式品牌资源。
- Markdown SVG 徽章与图片的跨平台解码支持；桌面远程图片目前为有意占位。

### 默认选择与未解决问题

1. WKWebView 在每次导航完成时读取 WKHTTPCookieStore（WKWebView 不保证同步系统 Cookie jar）并合并 HTTPCookieStorage，只回调当前登录域范围内的 Cookie，拦截非 HTTP(S)/about scheme，避免把其他站点凭证带到账号保存。Compose 状态回调回到主线程。各站跨域登录、SPA 无导航 Cookie 更新、登录会话隔离/退出清理、WebKit 与 Ktor jar 的策略仍需在 Stage 4 细化及实机检查。
2. 夸克、UC、百度、139、115 使用原 ViewModel 的网络校验/落库函数保存 Cookie；光鸭、蓝奏优享、蓝奏保留账号密码登录界面。123 保留账号密码与手动 Token 入口；迅雷保留密码/短信和手动 Token/JSON 入口。**localStorage Token 自动提取暂未移植**，不会把 Cookie 误当 Token 保存。当前 Cookie 回调只填入输入框，用户点击保存后才校验，不自动写入中间登录态。
3. 迅雷网页验证只允许可信 xunlei.com HTTPS 页面，并能打开网页；deviceId/JS SDK 验证初始化、原生 callback scheme 与验证结果解析仍待 Stage 4。页面明确提示完成验证后返回重试；不会因拿到 Cookie 就误报验证成功。
4. iOS 通知申请已接真实系统 API；现有 PermissionState 状态查询、通知投递与通知点击、后台下载/锁屏持续下载能力属于后续平台阶段。界面没有宣称后台下载已经可用。
5. 文件打开与调试日志分享暂用现有 openUrl(file://) 语义；QuickLook、UIDocumentInteractionController/UIActivityViewController 待 Stage 4。下载文件在 App 沙盒，SAF 目录与 Android APK 安装流程不再使用。
6. 公共 BackHandler 为占位，所有叠加页面仍有可见返回按钮；iOS 返回手势及 JVM Escape 暂未绑定。JVM 剪贴板只在进入解析页时检测，窗口重新激活检测待补。
7. SettingsScreen 使用标准 Material 控件重排；包含按平台线程（迅雷固定 8）、并发/重试/限速、SHA-256、夸克免转存、主题/剪贴板/预发布、代理/镜像、认证备份导出/粘贴导入/保存、通知申请与诊断开关。取消 Android 文件选择、图标组件切换、权限/电池流程及 Gopeed 内核导入。代理 host/port 编辑后通过开关重新应用；上游不安全 SSL 调试入口未加入新设置界面。
8. 图像 autoHeight 暂按占位宽高比计算；后续补按真实图片尺寸布局、平台原生下采样和 SVG。自定义颜色不是完整 Hct 色调生成；iOS 壁纸动态取色不可用。
9. UpdateChecker.installedVersion 仍为 Stage 2 的占位版本，需 Stage 4 从 Bundle 接入；当前检查展示上游 GitHub Release，不代表已有 iOS 发布渠道。替代 App 图标只保存选项并提示待接入，没有修改系统图标。
10. **未运行构建、编译、Gradle、依赖解析或测试。** 已做文件覆盖、授权文件头、禁止 import 与源码括号静态检查；这不代表编译/运行已验证。后续独立验证阶段仍需检查 CMP 1.8.2、生命周期 2.9.2、Markdown 与 Kotlin/Native WebKit/URLSession 的实际 API 签名及 UI 行为。

### 本阶段静态检查结果

- 上游 UI 109/109 文件就位；AGPL 文件头 109/109 保留。
- commonMain UI 共 113 个 Kotlin 文件（上游 109 + 新增 4）。
- `grep -rn "^import android\." shared/src/commonMain/kotlin/com/yunx/app/ui` 无结果；Java/Android activity/core/webkit import 也无结果。
- 120 个 UI/入口 Kotlin 文件的词法括号检查无发现；不使用 Kotlin 编译器。
- 公共 App() 与现有 iOS MainViewController/Swift 桥接保持一致。

### 文件清单

以下是 Stage 3 新增或修改的完整文件清单。composeResources 目录为空，不包含资源文件。

<details>
<summary>展开完整文件清单</summary>

- `PORTING-NOTES.md`
- `shared/build.gradle.kts`
- `shared/src/commonMain/kotlin/com/yunx/app/App.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/platform/UiPlatform.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/MainScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/SnackbarController.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/ExpressiveLoading.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/FileNameText.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/GitHubMarkdownImageTransformer.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/MarkdownTypography.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/PlaceholderScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/PlatformImage.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/RemoteImage.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/RemoteImageLoader.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/components/ScrollToTopButton.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/items/CustomFabMenu.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/items/MultiSelectBar.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/BaiduLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/C139LoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/CookieLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/CookieLoginWebView.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/DiagnosticWebViewClient.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/GuangYaLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/ILanzouLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/LanzouLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/Pan115LoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/Pan123LoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/QuarkLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/UCLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/WebLoginAutoDetect.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/WebViewJs.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/XunleiLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/XunleiVerificationPolicy.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/XunleiVerifyWebViewScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/login/XunleiWebLoginScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/navigation/MainTab.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/platform/UiSupport.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/resolve/DownloadLinkDialog.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/resolve/ResolveFileActionSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/resolve/ShareDetailScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/AboutScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/AnnouncementDetailScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/AnnouncementListScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/AnnouncementScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/BaiduAccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/BaiduCloudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/BaiduSaveSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/BookmarkScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/C139AccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/C139CloudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/C139SaveSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/CloudDriveScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/CloudFileSheets.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/DownloadDebugScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/DownloadEngineScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/DownloadScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/DriveScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/GuangYaAccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/GuangYaCloudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/GuangYaSaveSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/ILanzouAccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/ILanzouCloudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/LanzouAccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/LanzouCloudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/OnboardingPermissionPage.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/OnboardingScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/Pan115AccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/Pan115CloudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/Pan115SaveSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/Pan123AccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/Pan123CloudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/Pan123SaveSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/QuarkAccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/ResolveScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/SafetyNoticeDialog.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/SaveToCloudSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/SettingsScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/SupportScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/ThemeScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/UCAccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/UCCoudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/UCSaveSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/UpdateSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/XunleiAccountSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/XunleiCloudScreen.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/screens/XunleiSaveSheet.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/theme/Color.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/theme/Motion.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/theme/Theme.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/theme/ThemeController.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/theme/Type.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/AnnouncementViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/BaiduAccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/BaiduCloudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/BookmarkViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/C139AccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/C139CloudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/DownloadViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/DriveQuotaViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/GuangYaAccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/GuangYaCloudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/ILanzouAccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/ILanzouCloudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/LanzouAccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/LanzouCloudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/Pan115AccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/Pan115CloudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/Pan123AccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/Pan123CloudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/PendingDownload.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/QuarkAccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/QuarkCloudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/ResolveViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/UCAccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/UCCoudViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/XunleiAccountViewModel.kt`
- `shared/src/commonMain/kotlin/com/yunx/app/ui/viewmodel/XunleiCloudViewModel.kt`
- `shared/src/iosMain/kotlin/com/yunx/app/platform/PermissionState.kt`
- `shared/src/iosMain/kotlin/com/yunx/app/platform/UiPlatform.kt`
- `shared/src/iosMain/kotlin/com/yunx/app/ui/components/PlatformImage.kt`
- `shared/src/iosMain/kotlin/com/yunx/app/ui/login/CookieLoginWebView.kt`
- `shared/src/iosMain/kotlin/com/yunx/app/ui/platform/OnForeground.kt`
- `shared/src/jvmMain/kotlin/com/yunx/app/platform/UiPlatform.kt`
- `shared/src/jvmMain/kotlin/com/yunx/app/ui/components/PlatformImage.kt`
- `shared/src/jvmMain/kotlin/com/yunx/app/ui/login/CookieLoginWebView.kt`
- `shared/src/jvmMain/kotlin/com/yunx/app/ui/platform/OnForeground.kt`

</details>

## Stage 4 — iOS 平台 actual 与 Swift 胶水（2026-10-09）

本阶段只写代码并清点源码；没有运行构建、编译、Gradle、Xcode 或测试。`.upstream/yunx-orig` 只读，`jvmMain` 未修改。

### expect 清点与接口兼容

开始时 platform 有 19 个 `^expect` 顶层声明，另有 `internal expect localCredentialKey`。本阶段新增 `BackgroundDownloader` 和 `ClipboardMonitor`，结束时：

- `grep -rn "^expect" shared/src/commonMain/kotlin/com/yunx/app/platform | wc -l` = **21**。
- `grep -rn "^actual" shared/src/iosMain/kotlin/com/yunx/app/platform | wc -l` = **21**。
- `grep -rn "^actual" shared/src/iosMain | wc -l` = **27**，额外 6 项逐项为 `CookieLoginWebView`、`PlatformImage`、`OnForeground`、`installCrashHandler`、`createDbDriver`、`ArchiveProbe`，它们的 expect 在 platform 目录外。
- 上述 anchored grep 不包含 `internal` 和缩进成员。包括 internal 后，platform 顶层 expect/actual 均为 **22**；整个 commonMain/iosMain 顶层 expect/actual 均为 **29**，名称一一对应。额外 internal 两项是 `localCredentialKey` 和图片的 `loadRemoteBitmap`。

platform 对应名称：`SecureStore`、`localCredentialKey`、`SettingsStore`、`Notifier`、`clearLoginWebData`、`setDownloadIdleTimerDisabled`、`PlatformLock`、`secureRandomBytes`、`aesCrypt`、`gunzip`、`PlatformLog`、`appDataDir`、`appCacheDir`、`appDownloadDir`、`platformHttpEngine`、`requestPermission`、`openUrl`、`copyToClipboard`、`readClipboard`、`showToast`、`BackgroundDownloader`、`ClipboardMonitor`。

合理默认/接口调整：

- 保留 Stage 2b `Notifier.progress/result/clear` expect，用 common 扩展提供 `notifyProgress/notifyComplete/cancel`。`Notifier.requestPermission()` 为 **suspend 返回 Boolean**：iOS 授权弹窗异步，不能阻塞主线程伪造同步结果。它复用已有 `requestPermission(Permission.NOTIFICATIONS)` actual，不改变 JVM 的旧 actual。
- `setKeepAwake(enabled)` 为 common 包装，复用既有 `setDownloadIdleTimerDisabled` expect/actual，避免为同一原生动作再增加一个 expect。
- Cookie 新增公开的 `CookieLoginWebView(url, loginDomains, onCookies)` common 重载，经 CompositionLocal 把域名传给 iOS actual；同步更新两个 common 调用点。为遵守“不动 jvmMain”，保留原二参数 expect 的 ABI，没有直接扩展其参数。默认域名使用明确的已知网盘根域名表，未知服务仅允许初始完整 host，调用者可以传完整允许列表；不采用“取最后两段”处理公共后缀。
- 新增 `BackgroundDownloadListener` 的三个回调是 suspend，以便等待数据库写入后再结束系统后台唤醒。`BackgroundDownloader` 额外有 `isEnqueued`，防止前台重启同一 OS 任务。
- **JVM 验证限制：**任务同时要求新增 common expect、禁止修改 jvmMain；新增的 `BackgroundDownloader` / `ClipboardMonitor` 因此只提供 iOS actual，当前 JVM 目标缺少这两个 actual，后续 JVM 验证阶段须补桩。本阶段不声称 JVM 仍可编译；原有 JVM 文件和 expect ABI 保持不动。这是约束冲突的显式取舍。

### 已实现及保留实现

- Keychain：GenericPassword，service `com.yunx.app.ios`，account 为调用 key；新增和更新均设置 `kSecAttrAccessibleAfterFirstUnlock`。CFString/CFData/字典均在操作完成后释放，空 ByteArray 不取非法首元素地址。load 的 Security 状态失败返回 null，由 common 凭证恢复层处理；save/delete 真正的写入错误仍抛异常。相比 Stage 2b 的 service `com.yunx.app.credentials` 与 ThisDeviceOnly 属性，这次按任务改名/改属性，没有迁移旧测试凭证，旧安装可能要求重新登录。
- SettingsStore 已完整使用 `standardUserDefaults`，string/bool/int/64 位 long/float 与默认值、remove 均已存在，保留实现。没有用字符串模拟整数。
- Cookie：Swift 已有的 UIViewControllerRepresentable → Compose controller → UIKitViewController → 内含 WKWebView 的 child UIViewController。WebKit 每次 didFinish 读取 defaultDataStore.httpCookieStore，按传入域名做边界匹配，再回调 name→value；不混入全局系统 Cookie jar。桌面 UA 与上游 Chrome 131 字符串一致，但 WebKit 不会变成 Chromium，不能承诺模拟 client hints。登录页“完成”按钮返回并销毁 WebView；保存凭证仍使用已有校验流程。迅雷验证页不把 Cookie 出现当成验证成功，提示返回并重试；没有伪造专有 SDK 验证回调。
- 通知：UNUserNotificationCenter，进度首次投递后仅变化 **超过 10 个百分点**再更新；相同进度 identifier 替换通知，sound=nil。完成使用不同 `yunx.result.*` identifier 和默认声音，避免 DownloadServiceController.release 清理进度时删除完成消息。Swift delegate 前台仅给结果弹 banner/list/sound，进度不弹。**iOS 没有 Android ongoing 进度条；相同 identifier 和无声音不等于系统保证后台无横幅，真正静默更新无法承诺。**通知权限由现有引导页/新增 suspend API 请求，拒绝授权不影响下载。
- ClipboardMonitor：主 run loop 每 2s 检查，只在 UIApplication active 时读 UIPasteboard；去重并复用 ShareLinkParser.parse，不写新的分享链接正则。接入 iOS OnForeground 的 DisposableEffect，使当前解析页面已有分享建议逻辑响应新链接；disabled/dispose 时停止。iOS 的读取提示/授权不能绕过，GitHub 建议仍由原有前台回调处理。
- 防休眠：仅设置 idleTimerDisabled 防自动锁屏。**iOS 无桌面式阻止系统休眠 API，仅防锁屏；真后台下载靠 background session。**
- 崩溃：NSSetUncaughtExceptionHandler 尽力写 `Library/Caches/yunx-nsexception.log`（时间、异常类型、调用栈，不写 reason/userInfo/凭证）。不能保证捕获 Kotlin fatal、信号或 OOM，也不能保证崩溃现场日志写入成功。
- Toast 使用既有 Snackbar 替代，切到主队列显示。PlatformImage 保留 NSURLSession → NSData → UIImage 校验尺寸 → Skia 解码 → Compose ImageBitmap/Image 的现有实现，已有取消、HTTP 状态、8MiB/像素限制。openUrl 保留 UIKit 异步调用，返回 true 仅表示本地提交请求，并非保证外部 App 已打开。
- ArchiveProbe 的 APK/Dex 检测在 iOS 不适用，fast/deep 返回空 findings 并写明这一点，不能理解成已经验证 iOS 包签名。数据库 NativeSqliteDriver、Darwin HTTP 引擎、目录、日志、锁和密码学 actual 保留。

### 后台下载：实际能力与降级（重点）

1. 仅一个进程共享 NSURLSession，配置 identifier **`com.yunx.app.bg`**，sessionSendsLaunchEvents=true、discretionary=false。不继承前台 Cookie jar。enqueue 支持 URL/headers，但 DownloadManager 自动接管采用更保守规则：HTTP(S)、非 m3u8、无任何请求头、无 provider 标识的普通直链才交给 OS；认证、Cookie、Referer、Range 组合、网盘刷新逻辑、HLS、磁力均不冒充可后台执行。
2. Swift willResignActive 时申请短暂 beginBackgroundTask 时间，让 DownloadManager 先取消全部前台 workers，等待取消完成，保留已下载 Range 分片，再提交 OS 单连接任务。**32 并发分片引擎只在前台运行；该短暂时间不是永久后台保活。**系统提前收回时间时取消 handoff，不承诺所有任务已成功交接。
3. **不把 common 的任意分片拼成 NSURLSession resumeData，不伪造跨引擎断点。**本阶段普通直链接管从 byte 0 下载完整文件，原有前台分片先保留；NSURLSession 自身重试/系统续传由 OS 决定。本阶段没有实现 common 分片到 OS 的无损字节续传。后台文件仅接受完整 HTTP 200，拒绝 206，避免保存截断内容。这个默认会重复传输已下载字节；需要 Range 加认证头的分片任务明确标记“已暂停，回到前台继续”。
4. 降级任务在本次进程回到前台时自动走原 common 引擎继续；成功接管的 OS 任务回到前台仍由 session 持有，isEnqueued 阻止双引擎下载。用户暂停/删除/重新下载会取消相应 OS 任务。OS 错误记录为暂停，让用户回前台重试。前台的线程数/速率限制/重试策略不移植到 OS session，不能承诺后台仍遵守 32 线程或同一全局限速。
5. session delegate 进度最多约每秒回写一次。任务 id、原生 taskIdentifier、目的路径和终态写 NSUserDefaults JSON journal；我们不在这个 journal 保存 URL/认证头，但 **系统 NSURLSession 为恢复任务会持久化自己的请求**。delegate 完成时在返回前同步把临时文件 move 到下载目的路径，然后记录终态、交给 common DAO；用 taskIdentifier 验证任务代次，取消后的旧 callback 不更新新任务。
6. 冷启动也可在没有 Compose UI/DownloadManager 时由 BackgroundDownloadPersistence 更新 DAO 并发完成通知。终态未成功写 DAO 时保留 journal，下次接入重放。didFinishEvents 等待此前 listener 的 suspend 写入结束后，在主 dispatcher 调用 Swift 保存的 completionHandler；**这个事件表示本批 delegate 事件送达，不代表所有下载均已完成。**普通启动接入 listener 同样重新连接唯一 session。common 的一次性 onComplete 清理闭包不持久化，冷启动完成不能保证执行之前进程的云端临时目录清理闭包。
7. 系统调度时间不可保证；用户强制划掉 App 后通常取消后台传输且不会自动唤醒。残留 running journal 不代表 OS 仍在下载，必要时在前台暂停后重新开始。后台 handoff 尚未提交就被终止的任务保持分片，可在前台手动继续。`fetch` 已在 Info.plist 中，保留；background URLSession 不依赖它获得无限执行时间，不新增虚构的后台保活模式。
8. 文件 move 与 journal 写入不是一个跨文件系统事务，极端终止窗口仍可能留下文件但无完成 journal；没有声称达到断电级一致性。回调写入失败时仍按系统协议结束本轮唤醒，保留 journal 待下一次恢复。

### Swift 入口与文件清单

ContentView 原入口 `MainViewControllerKt.MainViewController()` 与 Kotlin `ComposeUIViewController { App() }` 对得上，保留。新增 AppDelegate 用 UIApplicationDelegateAdaptor 安装、持有系统 completionHandler、处理前台通知，并已加入 Xcode PBXBuildFile/PBXFileReference/group/Sources。

新增：

- common platform：`BackgroundDownloader.kt`、`ClipboardMonitor.kt`。
- common download：`BackgroundDownloadPersistence.kt`、`DownloadBackgroundLifecycle.kt`。
- iOS platform：`BackgroundDownloader.kt`、`ClipboardMonitor.kt`、`IosLifecycleBridge.kt`、`Notifier.kt`。
- Swift：`iosApp/iosApp/AppDelegate.swift`。

修改：common `platform/Notifier.kt`、`data/download/DownloadManager.kt`、`ui/login/CookieLoginWebView.kt`、`CookieLoginScreen.kt`、`XunleiVerifyWebViewScreen.kt`；iOS `platform/SecureStore.kt`、`UiPlatform.kt`、`ui/login/CookieLoginWebView.kt`、`ui/platform/OnForeground.kt`、`crash/CrashHandler.kt`、`util/ArchiveProbe.kt`；Swift `iOSApp.swift`、Xcode `project.pbxproj`；本 notes。

### 需在 Mac 上验证（本阶段未执行）

- Kotlin 2.1 / Compose 1.8.2 下 NSURLSessionDownloadDelegate selector、Foundation NSMutableURLRequest、NSError** 的 ObjCObjectVar 内存参数、NSTimer block 签名、UIKitViewController API 与 Security CF 指针绑定。
- Swift 导出 `.shared`、闭包 Unit→Void 桥、AppDelegate 注册和新增文件的 target membership，主入口导出名仍与 Stage 1 一致。
- Keychain 首次保存/覆盖/空值/读取失败/重启后可读、AfterFirstUnlock 锁屏行为、service 改名后重新登录；NSUserDefaults 64 位 long 与 float 往返。
- 各网盘登录重定向、明确 domain allowlist、HTTP-only Cookie、桌面 UA 在 WKWebView 的实际兼容性、完成按钮销毁页面和凭证校验路径；迅雷专有验证行为单独确认。
- 真机长文件后台传输、锁屏、系统杀进程后唤醒、冷启动 move/DAO/journal 重放、完成 handler 一次性调用；force-quit 与短暂 handoff 过期的真实降级；相同文件名、保存路径错误、HTTP 206/403、直链过期、取消后重试的代次隔离。
- 有认证头/Range/HLS 的任务暂停后前台续传，前台分片不与 OS 临时文件混合；同时进入/返回前台的取消和数据库写入顺序。
- 通知授权拒绝、超过 10% 节流、前台 banner/静默进度、后台实际展示限制，release 不删除完成通知。
- 剪贴板 active-only 2s 读取、权限提示、链接去重、disabled/dispose 停止；idleTimer 的锁屏行为。
- NSException 沙盒日志与捕获范围；远程图片格式/尺寸/取消/失败 fallback；外部 URL 实际 completion 行为。另行补齐新增 JVM actual 后再做 JVM 验证。

参考：[Apple 后台文件下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)、[Apple 临时下载文件生命周期](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didfinishdownloadingto:))、[Kotlin Objective-C 互操作](https://kotlinlang.org/docs/native-objc-interop.html)。


## Stage 5 — 文档定稿与当前静态发现（2026-10-09）

已用 find 清点工程，读取构建配置、xcconfig、脚本、共享 scheme、Swift、Info.plist 以及关键 iOS 登录/下载实现；没有执行构建或编译命令。完成 BUILD-iOS.md 与 README 互链，保留 Stage 1/2a/2b/3/4 五章历史，补充当前验证边界。

### 文档内容依据

- `shared/build.gradle.kts` 仅配置 iosArm64 / iosSimulatorArm64 两个动态 shared framework，无 XCFramework 聚合注册。构建指南列出 Debug/Release 四种 link task 与对应输出目录，未声称通过运行 Gradle 枚举或验证任务。
- Debug/Release xcconfig 通过 SDK 条件切换 framework 路径；build-shared.sh 从两个配置变量拼接 task，Xcode 自己负责链接、嵌入和签名。
- iOS 后台接管只允许无请求头、无 provider 标识的非 HLS 普通 HTTP(S) 直链，从头单连接下载；认证、网盘和 HLS 任务回前台继续。Gopeed/磁力不支持，WKWebView 与文件导出限制已在两份用户文档显眼说明。

### Mac 首次执行前已知问题（只记录，未改工程）

1. wrapper jar 仍缺失，顶部的下载超时原因保留。当前 gradlew 的 CLASSPATH 赋值含不寻常的转义引号字面量，未执行判断影响，指南建议生成整套 wrapper；brew 安装的版本可能变化，生成后须显式固定分发版本 8.10.2。
2. `iosApp/iosApp.xcodeproj/xcshareddata/xcschemes/YunX.xcscheme` 三个 BuildableReference 使用 `A1000000000000000000001B`，与 project.pbxproj 的真实 YunX PBXNativeTarget ID `A50000000000000000000001` 不一致。指南明确要求在 Mac 修复引用或重建并共享 scheme 后执行命令示例。
3. Info.plist 的 CFBundleIdentifier 写死 `com.yunx.app.ios`，修改签名设置时须同步 plist 或改为 PRODUCT_BUNDLE_IDENTIFIER 展开值；Team 当前未配置。Keychain service 与后台 session ID 有各自用途，不可只改一侧 session 常量。
4. 当前 Kotlin/CMP/Ktor/SQLDelight 组合、Native cinterop 与 Swift 导出/闭包签名仍需实际 Mac 编译验证；文档未声称任何 framework、App 或 CI 已成功生成。
5. AppIcon/品牌资源、原生文件分享/预览、localStorage Token 与部分专有网页登录流程仍待补齐；锁屏/冷启动后台接管、Keychain、通知与网盘服务端兼容性需真机检查。

文档自查仅核对本地路径、配置映射、scheme ID 和章节/链接；它不是 JVM、Native、Swift 编译或功能验证报告。
