# iOS UI 适配与云端验证 · 2026-10-10

代码提交：`aba36f839dd4acb2453357e15c1e01f7be0073ef`，版本 **0.1.1 (4)**。分支 `codex/ui-adaptation` 与 main 已同步。

保留 FontFamily.Default 使用 iOS 系统字体；调整正文、标题、标签的字号与行高，取消额外字距。Compose 1.8.2 的 UIKit density 已将系统 preferredContentSizeCategory 映射到 fontScale；不添加第二次字号乘数。SwiftUI 宿主观察 sizeCategory 并更新 Compose 子视图布局，使运行中修改 Dynamic Type 也触发内建 density 更新。此版本的辅助字号映射最大为 1.8，并非 UIKit 各文本样式的非线性曲线。

删除首次启动引导页及关于页引导预览入口。首次启动直接进入解析页；旧 onboarding 偏好不影响启动路径。关于页读取原生实际版本与构建号。

共用 AppScaffold 应用并消费安全区，为键盘留出空间，内容宽度上限 840dp。主导航按可用宽度和高度使用底栏、侧栏或紧凑顶栏；键盘打开时隐藏底栏。弹层可滚动，按钮可换行。支持 iPhone 横屏。设置页将平台线程设置折叠，下载目录说明改为“文件”App 中的路径；原生启用 Documents 文件共享。

## 实际验证

在 GitHub Actions macOS runner 执行 `./gradlew :shared:jvmTest`：**8 项通过，0 失败**（3 项业务回归、5 项 UI 检查）。最终提交新生成 **79 张实际 Compose PNG**，未复用之前的 61 张结果。

检查默认启动路径在旧引导偏好 true/false 下完全一致、安全区只应用一次、平板内容宽度、登录与说明页、四个主 Tab、弹层和动画时长缩放 0。覆盖窄屏、横屏、大字号、深浅色。图片与 XML/HTML 报告在 [本次验证运行](https://github.com/cc1477/YunX-iOS/actions/runs/37960349967) 的 YunX-ui-validation 附件。

同一运行已完成 Xcode iOS 模拟器编译和安装启动，生成 4 张原生截图：标准字号、运行中切换最大辅助字号、最大辅助字号冷启动、最大辅助字号深色。原生截图包含网络返回的上游版本说明弹层；不会将该截图描述为首页。完整截图与模拟器 App 位于 YunX-simulator 附件。

[真机打包运行](https://github.com/cc1477/YunX-iOS/actions/runs/37960350134) 已编译并验证 arm64 App、共享框架与未签名 IPA，GitHub Pages 部署成功。IPA 不包含 provisioning profile，需用户使用自己的签名工具签名安装。

没有实机验证 VoiceOver、WKWebView 输入、键盘弹出/收起和 iPad 分屏；相关共用布局已有渲染覆盖，不能视为这些原生交互全部验证。

## 分发

- [Cloudflare LCSign 分发页](https://yunx-lcsign-cc1477.pages.dev/)
- [GitHub Pages 备用](https://cc1477.github.io/YunX-iOS/)
- IPA：28,252,277 bytes
- SHA-256：`42124c0b4a7c5c8c9449b1f53adfb164481c25f4b877f6c0815d1a44a46f0eb9`
- 源提交：`aba36f839dd4acb2453357e15c1e01f7be0073ef`
- 构建时间：2026-10-09T17:00:15.928690+00:00

Cloudflare 发布继续使用 gametool 现有 Actions secrets，凭据未取出。其现有 deploy-yunx.yml 更新了可复用工作流固定提交和校验摘要，并添加仅该文件变更时触发的 main push 入口；没有为技能迁移新增工作流。
