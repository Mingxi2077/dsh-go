# 内置浏览器验证记录

截至2026-11-02，基于DSH Go 1.0.8 / `214ff5a9500901c3664572c5d34f61af4c8a704f`。代码位于本分支，未合并上游。下文区分本机自动化、设备操作和未验证范围，不把源码实现等同于所有设备均已通过。

## 最新本机检查

- 浏览器相关 **446项测试通过**：`app/test/browser/`，覆盖导航/加载、搜索与资料库、作用域、提取、下载确认/导入、侧签、任务指示和界面交互。
- 原生下载策略/流 **7项通过**：`BrowserDownloadPolicyTest` 3项，`BrowserDownloadStreamTest` 4项，无失败或跳过。MediaStore实际重名分配另用真机验证，不由这些单元测试代替。
- 完整 `flutter analyze --no-pub` 无问题，格式及差异空白检查通过。最新原生测试初次遇到Flutter遥测日志权限问题，设置进程环境 `FLUTTER_SUPPRESS_ANALYTICS=true` 后重跑成功，没有修改产品代码绕过检查。
- 下载布局另检查360dp/1.3倍字号widget渲染；空态、短屏、长路径与列表顺序有断言。widget渲染不当作手机截图。
- 历轮草稿/账号/论坛/导航/刷新率专项另有测试，存在重叠，不累计成独立总数。没有宣称全仓库测试全部通过。Windows性能页4项golden差异曾在精确基线复现，另有旧web_mode golden差异未单独证明来自基线；均未通过覆盖golden消除。

## 真机范围

PLA_AL10 / Android12 / Huawei WebView 114。始终使用独立 `.browserdev` 包并保留正式版和用户数据；最新安装版本 `1.0.8-browser` / **11021501**，arm64/profile。以下浏览功能来自历轮设备验证，最后一轮重点验证下载布局、交接及文件引用。

| 场景 | 观察到的结果 |
| --- | --- |
| AI链接 | 已登录模型实际返回项目链接，点击打开App内GitHub网页 |
| 中文输入 | 手机拼音键盘输入nihao、选择“你好”并搜索成功 |
| 日常浏览 | 必应/百度切换，书签/历史增删，标签切换、关闭/撤销、资料重启恢复通过 |
| 导航 | 首页可后退；网页A→B、退出再进入后仍可后退；原生销毁/恢复专项也覆盖SPA前进/后退 |
| 网页引用 | 整页及原生长按选区预览确认后进入独立草稿卡片，真实模型读出引用内容 |
| 动效/高刷 | 录屏可见搜索/历史/标签连续过渡；滚动时系统切到120Hz，某次Surface呈现间隔中位数8.313ms；不外推为所有场景固定120fps |
| 会话提示 | 真实任务运行环、正常完成蓝点、看回会话后清除；主动停止不误亮蓝点 |
| 下载确认 | 取消不创建独立任务/文件，确认后保存默认目录 |
| 目录选择器 | 打开再取消后原目录与记录保留；尚未据此声称切换目录通过 |
| 文件引用 | 两份不同JSON独立导入，保留提示词、不自动发送；主动发送后模型返回各自正确值，工具读取路径中的SHA256与文件一致 |
| 重名文件 | 原始文件、(1)、(2)均保留，原始哈希不变；最终列表/磁盘/附件名称一致 |
| 下载页 | 修复后目录与卡片正常铺满，完成项显示实际大小；未知长度不再显示0B，交给下载器后网页不持续转圈 |
| 论坛授权 | 网站提示当前WebView不受支持，系统浏览器兜底入口可用；未证明内置登录成功 |

下载文件对照：原始JSON为224B，SHA256 `47276770f315cd51b192c0fc3d525b2ea64bc65263c9c8ef391f4b95a524f090`，模型读出 `WHALE-7926-BLUE / 37`；第二份为225B，SHA256 `92a757148ee331aa84469d17dd48a8d4bca68164df38439e1b0f94a90815e7b5`，模型读出 `CORAL-4819-GREEN / 61`。最后新增(2)验证名称与导入，未重复发送第三轮模型请求。测试字段仅为人工构造的公开响应数据。

最新APK为221705252字节，SHA256 `d38d4cbd7a2de8ea81be333c51dac7852060841fb935e74c857eabaeea0ec8b2`。本仓库提交源码，不包含本机签名、APK或用户数据。最终设备应用进程的Flutter/AndroidRuntime错误日志为空，仅对应本次实际操作。

## 本机复现入口

按仓库既有开发说明准备Flutter/Android/JDK环境与依赖。widget测试需要 `app/test/support/test_fonts.dart` 指定的字体；可用 `DSH_TEST_FONT_DIR` 指向本机字体目录。

在 `app` 目录执行：

```sh
flutter pub get
flutter analyze --no-pub
flutter test test/browser/
```

在 `app/android` 目录运行原生专项；Windows使用 `gradlew.bat`，环境需要JDK17：

```sh
./gradlew :app:testArm64DebugUnitTest --tests '*BrowserDownload*' -PdshBrowserTestBuild=true -Pkotlin.incremental=false -Pkotlin.compiler.execution.strategy=in-process --max-workers=2
```

原生导航与刷新策略另见对应测试文件。`app/tool/browser_extraction_scripts.dart` 导出实际生产提取脚本，`app/tool/check_browser_dom.mjs` 可在外部准备的Chromium/Playwright环境运行真实DOM检查；并非运行上述widget命令就自动执行。

需要独立安装时在自己的Gradle用户目录配置 `dshBrowserTestBuild=true`，使用仓库 `tooling/build-apk.sh --profile --flavor arm64 --build-name 1.0.8-browser` 构建并核对实际包名为 `.browserdev`。该开关默认关闭，正常正式构建保留原包名。不要用卸载正式应用解决测试签名差异。

## 待验证与限制

- 多侧签已有实现和自动化，3个以上侧签的完整设备操作及最终总览渐隐的连续操作观感仍需专项复测。
- 文件引用真机覆盖小型JSON；PDF、图片、压缩包等尚未逐一执行同样的模型读取链路。
- 实际切换下载目录、撤权、长时间后台下载、断网、空间耗尽和进程终止场景未完成本轮设备验收。
- 下载仅普通HTTP(S) GET，未实现blob/POST重放、DRM及断点续传；登录下载、跨站CDN兼容性未全部实测。
- GitHub登录/2FA以及部分服务完整OAuth回跳未逐一测试；Google/DuckDuckGo实际联网搜索也不计入已测。
- 导航栈、侧签、缩略图及未发送文件附件为进程内状态。网页引用草稿持久化不等于所有附件跨进程恢复。
- Cookie/网站存储未分区，地址策略不是完整网络沙箱，引用标注不是提示注入免疫保证。
- 尚未基于最新上游重新整合，未做多设备、iOS、鸿蒙或生产发布验收。
