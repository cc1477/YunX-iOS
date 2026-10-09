# UI 适配修复 · 2026-10-09

本地分支：`codex/ui-adaptation`。

完整页面共用 `AppScaffold`：统一应用并消费安全区、为键盘留出空间，内容宽度上限为 840dp。SwiftUI 宿主把窗口交给 Compose 管理。主导航在宽屏使用侧栏，短屏使用紧凑顶栏；键盘打开时收起底部导航。安全区处理参考 [JetBrains 的窗口布局说明](https://youtrack.jetbrains.com/projects/KMT/issues/KMT-1505/KMP-Wizard-Compose-for-iOS-should-ignore-safe-area-completely) 与 [Compose Insets 消费规则](https://developer.android.com/develop/ui/compose/system/insets-ui#inset-consumption)。

欢迎页内容可滚动，说明勾选和开始按钮固定在底部。账号、文件操作、移动与转存弹层支持滚动。操作按钮使用最小高度，快捷方式列数按可用宽度和字号调整；备份和批量操作按钮可换行。网页登录表单可以独立滚动，保留网页操作区域。说明页采用统一顶栏和滚动布局，颜色选择对话框支持滚动。

本地渲染还修复了 JVM 数据库初始化的事务连接问题；测试数据库位于 `shared/build/ui-test-home`。桌面渲染依赖仅加入 JVM 测试。

## 验证

执行 `:shared:jvmTest`：**8 项测试通过**，包含原有 3 项业务回归和 5 项 UI 检查。

- 验证安全区只应用一次、平板内容居中且不超过 840dp。
- 实际点击欢迎页：未同意时无法进入，同意后在手机竖屏与两倍字号横屏可以进入。
- 用真实 Compose JVM 渲染欢迎页、登录页、说明页、四个主 Tab、账号弹层、转存目录弹层，生成 **61 张 PNG**。
- 覆盖 320×568、375×667、667×375、834×1194、1194×834；主要页面包含浅色、深色和 1× / 2× 字号场景。
- 主导航包含动画时长缩放为 0 的渲染检查。检查了小屏、横屏、大字号、深色模式和弹层的代表截图。

截图位于 `shared/build/ui-layout`，测试报告位于 `shared/build/reports/tests/jvmTest/index.html`。本机已准备 `.tools/check-ui.ps1`，可在 PowerShell 中运行：

```powershell
& .\.tools\check-ui.ps1
```

标准 JDK 17 环境也可以使用：

```text
./gradlew :shared:jvmTest --console=plain
```

## 设备验证范围

以上图片来自共用 Compose 界面的 JVM 渲染。登录图片中的网页区域是 JVM 平台的手动凭证入口。Windows 无法编译或运行 iOS App，因此 Swift 宿主改动、真实刘海与 Home Indicator、WKWebView、键盘弹出/收起、iOS 最大辅助字号、VoiceOver 和 iPad 分屏仍需要在 macOS 模拟器或真机检查。当前没有生成更新的 IPA。

本次技能数据库命中了安全区指导；字体缩放的 Compose 专项检索未命中，相关调整采用技能通用规则，并通过实际渲染检查。
