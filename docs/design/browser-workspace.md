# 会话内置浏览器

基于 DSH Go 1.0.8 / `214ff5a9500901c3664572c5d34f61af4c8a704f` 的 Android 功能分支。实现与自动化测试位于本分支，尚未合并上游，也不代表正式发布版本。当前验证范围见 [browser-validation.md](browser-validation.md)。

## 使用流程

AI 回复或 App 内普通网页链接 → 内置浏览器 → 用户选择正文、选区或下载文件 → 预览/确认 → 对应会话草稿 → 用户发送。浏览网页不需要运行本机引擎，发送仍使用原会话及模型链路。

首页、搜索、书签、历史及标签见 [browser-daily-use.md](browser-daily-use.md)，动效与授权页见 [browser-motion-refresh.md](browser-motion-refresh.md)。

## 实现位置

| 层 | 代码与职责 |
| --- | --- |
| 浏览状态 | `app/lib/browser/`：主机/会话作用域、标签、搜索与资料库、导航控制、页面提取、图标/快照、下载、侧签及任务状态 |
| Flutter界面 | `app/lib/ui/browser/`：首页、网页、标签总览、资料库、引用预览、授权页、下载管理及返回会话 |
| 草稿 | `app/lib/state/draft_store.dart`、`web_quote.dart`、`app/lib/ui/chat/`：独立网页引用卡片、文件附件、归属与发送恢复 |
| Android | `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/web/BrowserDownloads*.kt` 及 `BrowserDownloadPolicy.kt`、`BrowserDownloadStream.kt`、`BrowserSelectionPlugin.kt`：下载服务、存储和选区入口 |
| 导航与刷新率 | Android `islands/BrowserNavigation.kt`、`BrowserImages.kt`、`performance/RefreshRate*.kt`：原生导航栈、快照和刷新请求 |
| 测试 | `app/test/browser/`、相关chat/state/account测试及Android `BrowserDownload*Test.kt`、`BrowserNavigationTest.kt`、`RefreshRatePolicyTest.kt` |

草稿使用主机与会话联合键，网页引用预览确认后作为独立结构保存；发送边界才接入已有模型协议。过期页面、异步返回、切主机/会话及删除会话均检查归属，避免旧引用或文件进入其他草稿。无主机归属的旧文本草稿保留，通过手动预览恢复，不自动分配。

最多同时保留3个存活WebView。原生导航栈在进程内按标签保留并限制内存；强停、重启、资源淘汰或恢复失败时降级为地址重载，不保证表单和滚动位置恢复。

## 下载与会话往返

默认下载目录为 `Download/DSH-Go/Browser`。每次下载均确认，首次说明目录，确认页及下载管理提供系统文件夹选择和恢复默认。普通HTTP(S) GET由原生前台服务执行，使用MediaStore或系统授权目录；失败/取消清理未完成文件，进程重启时未完成任务标为中断。

同名下载创建新文件，写入结束后重新读取存储提供者实际名称；已有完成记录也刷新名称。完成项可打开文件，或再次确认后加入会话草稿。导入遵循原有文件/图片限制、9附件上限，额外限制草稿附件总量60MiB。导入不自动发送，用户提示词保留。

第五个工具栏按钮返回会话并保留当前标签侧签，第七个直接退出并保留已有侧签。每个浏览标签最多一个侧签，多条可展开选择，移除侧签不关闭网页。侧签及快照仅存内存。第五个按钮同时显示对应会话的运行环/正常完成蓝点，取消、失败或明确断线不当作正常完成。

## 作用边界

普通外部网页不注册DSH JavaScript通道，网页权限默认拒绝，SSL错误取消。标签/草稿归属隔离不等于Cookie与网站存储分区；地址策略也不是对子资源、iframe及DNS重绑定的完整网络沙箱。网页文本需用户预览确认，但标注引用不保证模型免疫提示注入。

普通自动历史/标签保存时清理URL查询和片段，受支持搜索入口可保留必要搜索词；用户主动书签保留所选地址，引用来源清除查询和片段。标题、路径和搜索词仍可能包含网站提供的信息，资料库不是加密保险箱。

下载仅实现普通HTTP(S) GET，没有blob/POST重放、DRM、断点续传，也未自动收集模型通过Python下载的文件。未发送文件附件沿用已有进程内生命周期。本分支没有新增远程服务、浏览器自动操作、真正无痕或iOS/鸿蒙适配。
