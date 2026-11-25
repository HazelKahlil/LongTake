# LongTake 架构与第一性原理根因审计（v1.7）

> 本地母带级录音与录屏工具（基于 QuickRecorder `e820517` 深度重构）。本文档记录了从症状表象溯源至系统根因的核心修复、v1.7 GPT 审查闭环与自托管 Sparkle 2.10.1 OTA 架构。

## 0. v1.7 深度安全与并发加固（GPT 审查闭环）

- **会话隔离与回调排空（P0-1）**：引入 `RecordingSession` 与串行 `SCContext.sessionQueue`，先停止 `SCStream` 与冻结的 `MicBackend`、排空回调队列，再执行 `markAsFinished` / `finishWriting` / 关闭 `AVAudioFile`；`didStopWithError` 校验流身份防旧流误杀新录制。
- **三路统一时间轴与安全重映射（P0-2）**：画面、系统音、默认/指定/AEC 麦克风共享同一单调时钟累计暂停偏移；`adjustTime` 按 `entriesNeededOut` 动态分配并校验全部 CoreMedia 状态，默认麦克风 tap 采用实际采集 `AVAudioTime.hostTime`。
- **零冲突命名、拷贝落盘与 >24h 溢出防线（P0-3 / P0-5 / P0-6）**：`allocateUniqueFilePath` / `nonCollidingDestinationURL` 杜绝同秒覆写；`CMSampleBuffer.writePCM(to:)` 在 `withAudioBufferList` 借用期内拷贝落盘；离线混音以 64 位 `AVAudioFramePosition` 限幅防 `UInt32` 溢出。
- **全链路退出保护与零 TOCTOU 竞态（P0-4 / P1-1）**：普通视频、双轨音频、iPhone `AVCaptureMovieFileOutput` 与导出全部纳入 `beginAudioExport/endAudioExport`；`whenAudioExportsFinished` 合并至单一临界区；重复 ⌘Q 维持 `.terminateLater`，600s 超时改为用户确认弹窗。
- **Sparkle 2.10.1 自托管 EdDSA OTA（P0-8 / P1-12）**：升级 Sparkle `2.6.0 → 2.10.1`（修复 `GHSA-3x7w-j75x-ppq5`），配置 LongTake 独立 EdDSA 密钥（`SUPublicEDKey`）与 `HazelKahlil/LongTake/appcast.xml`，启动前清理残留 `SUFeedURL` 默认项，并通过 `SparkleUpdaterDelegate` 在录制/导出中自动推迟安装重启。

---

## 1. 第一性原理根因审计（R1–R9 全链路闭环）

| 编号 | 本质缺陷 | 触发后果 | 根因级解法（Crash-Only / WAL / 原生事件链） |
|---|---|---|---|
| **R1** | `SCContext.stopRecording()` 在 `systemaudio` 分支调用 `vW.finishWriting {}` **未做同步等待**，紧接着调用 `loadAudioFiles` 读取 `mic.m4a` | `AVAssetWriter` 尚未写入 `moov` 原子，导致 `mic.m4a` 打开失败、混音静默中断并产出 28 字节坏件 | 补齐 `DispatchGroup` 同步等待 `vW.finishWriting` 完成 `moov` 落盘；录制期启用 5 秒 `movieFragmentInterval` 分片检查点；系统音轨改由串行队列 `audioFileWriteQueue` 线程安全写入与关闭 |
| **R2** | `QmaPlayer.saveFile()` 复用绑定物理输出设备的 `self.engine`，且 `renderOffline` 遇 `.cannotDoInCurrentContext` 时 `break` 仅跳出 `switch` 未跳出 `while`；混音总长仅取 `audioFile1.length` | 摘耳机或蓝牙切换时触发 **100% CPU 死循环**，退出卡死 10 分钟并留下 28B 坏件；系统静音时人声被截断 | 导出时新建**完全隔离的纯离线 `AVAudioEngine`**（零物理硬件耦合）；总帧数取双轨换算至 48kHz 后的 `max(sys, mic)`；加入阻塞重试上限与显式错误抛出 |
| **R3** | 直接在最终输出路径打开写入句柄 | 任何中途中断都会在目标目录留下 **28B `ftyp` 残骸** | **Write-Ahead 原子暂存**：先写 `.longtake-staging-<UUID>.m4a`，作用域释放刷新 `moov` 后校验字节数与可读帧数 `> 0`，通过后再原子替换至目标路径 |
| **R4** | 3 条异步后处理路径漏出导出计数器（`.qma` 转 MP3、单轨转 MP3、视频多轨 `mixAudioTracks`）；且面对异常中断无自愈能力 | MP3 与视频混音退出即截断；强制中断后需手工合成 | 4 条异步导出链路全量纳入 `beginAudioExport / endAudioExport`（`.terminateLater` + 600s 安全阀）；新增 `longTakePendingRemuxPaths` 轻量日志，异常中断后下次启动自动静默补完 |
| **R5** | `stopRecording()` 调用 `qmaPackageHandle.load()` 将整包 `sys.m4a + mic.m4a` 全量读入内存 `Data`，仅为了读取 80 字节 `info.json` | 长时间录音停止瞬间暴涨数百 MB 内存峰值 | 新增 `qmaPackageHandle.loadInfo(from:)` 仅解析 `info.json` |
| **R6** | 退出拦截仅发延迟 1 秒的系统通知；Sparkle 仍连接上游 `appcast.xml` | 专注模式下无反馈导致用户强杀；检查更新会覆盖定制修复 | 新增胶囊悬浮窗 `savingHUDPanel`（「正在封存录音母带，完成后自动退出…」）；移除 `SUFeedURL` 并禁用 Sparkle 轮询 |
| **R7** | 启动即同步请求 `SCShareableContent`，被拒后每 1 秒无限递归重试；构建目录内残留同名包体干扰 LaunchServices | 系统反复弹出录屏权限弹窗；隐私设置出现死链或重复条目；重编易丢权限 | 启动改用零弹窗 `CGPreflightScreenCaptureAccess()` 并移除 1 秒无限递归；采用独立 Bundle ID `com.kahlilhazel.LongTake` 配合内向外签名与构建目录注销清理 |
| **R8** | 上游 `StatusBar.swift` 将 `NSHostingView` 强塞进 `NSStatusBarButton.subviews` 且挂载空 `.onTapGesture {}`，外加紫色自绘背景；无边框面板缺 `.borderless` | 顶部暂停/停止点击被父级按钮吞噬，且带非原生紫框与系统灰边 | 彻底移除 `NSStatusBarButton` 子视图塞入写法；悬浮窗统一改为 `FloatingHUDPanel`（`[.borderless, .nonactivatingPanel]`，`canBecomeKey = true`） |
| **R9** | ① `EscPanel` 继承 `NSPanel`，预设 `hidesOnDeactivate = true` 且重开未激活应用；② `applicationShouldHandleReopen` 过滤条件在设置窗打开时阻断重开；③ 频繁设 `NSStatusItem.isVisible = false` 写入 `VisibleCC = 0`；④ 暂停恢复计时与纯音频 `mic.m4a` 未扣除暂停时长 | 关闭主面板后点击 Dock 图标闪退或打不开；菜单栏图标被系统持久隐藏；多次暂停后人声与系统音错位 | ① 悬浮面板显式设 `hidesOnDeactivate = false`，由单一 `mainPanelWindow` 在当前鼠标屏幕激活打开；② 用 `removeStatusItem` 替代 `.isVisible = false`；③ 采用「顶部单行等槽位悬浮条（`sharingType = .none` 对录屏隐形）+ 菜单栏原生 `NSMenu`」双通道防误触控制；④ 补齐 `totalMicPausedSeconds` 时间戳扣除与混音完成预览卡 |

---

## 2. 界面与交互设计

- **单行连贯工作台**：整合为单一连贯圆角长条（高 `72pt`），从左到右为：原生点阵拖拽手柄（`WindowDragHandle`）→ 最前端独立音频输入仓（开关 + `Picker`）→ 6 项等高采集模式 → 偏好设置 → 关闭按钮。
- **高可读与可调背景浓度**：macOS 26/27 官方 `GlassEffectContainer` + `.glassEffect(.regular)` 内衬自适应高对比衬底，并在「偏好设置 → 一般设置 → 界面外观」提供 `25%–98%` 实时滑杆与预览按钮。
- **图标方案**：原生 SwiftUI `ImageRenderer` 2048px 连续超椭圆渲染 4 组方向（位于 `design/`），默认实装 `01 · 母带走带（Braun Offset Reel）`，可通过 `swift scripts/render_icons.swift --install <1|2|3|4>` 切换。

---

## 3. 开源构建与权限持久化说明

1. **保持 `PRODUCT_NAME = QuickRecorder`**：SwiftPM 资源包 `KeyboardShortcuts_KeyboardShortcuts.bundle` 依赖原可执行文件名，应用展示名通过 `Info.plist` 中的 `CFBundleName` / `CFBundleDisplayName = LongTake` 控制。
2. **本地签名与 TCC 权限**：使用个人 `Apple Development` 证书由内向外签名（`Sparkle.framework` 内部 helper -> `Sparkle.framework` -> `KeyboardShortcuts` bundle -> 主 `.app` 带 `QuickRecorder/QuickRecorder.entitlements`，不加 `--options runtime`），保证 `Sparkle.framework` 与主程序 `TeamIdentifier` 一致，同时让 macOS 持续记住录屏与麦克风权限。
3. **清理中间构建产物**：若使用 `xcodebuild -derivedDataPath build` 构建并复制到 `/Applications/LongTake.app`，请使用 `lsregister -u` 注销并删除 `build/Build/Products/Release/QuickRecorder.app`，避免 LaunchServices 中同一 Bundle ID 存在两份副本。
