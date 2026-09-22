# Windows GPUI Overlay 设计规格

状态：待用户审查的方案草案；尚未授权实现。日期：2026-09-22。

## 1. 目标与审查结论

在当前分支实现可复用的 `app_ui::overlay` 模块：调用方提供宿主窗口句柄和 GPUI 内容，模块创建、管理独立的无边框 Windows 窗口，并跟随宿主的位置、尺寸和可见状态。另提供窗口选择 demo，验证实际使用体验、模板的原生集成能力和资源生命周期。

用户已明确：Windows、GPUI 渲染、独立原生 overlay 窗口、宿主移动/缩放/最大化/最小化同步、模块与 demo 分离。本轮只设计规格，审查后再开发。

用户进一步确认两种模式：性能指标 HUD 只可见且不影响宿主交互；交互 overlay 有自己的界面和组件，支持鼠标与键盘输入。覆盖窗口和无边框全屏，不考虑独占全屏；具体游戏兼容性仍需实测。

以下为本稿建议，尚非用户确认：

- overlay 覆盖宿主客户区，标题栏和原生边框保留给宿主操作。
- HUD 默认整窗鼠标穿透；交互模式用户点击后可获得键盘焦点。交互模式内的局部控件命中、其余区域跨进程穿透不纳入首版。
- 仅宿主本身或 overlay 为前台窗口时显示；切换至其他窗口、宿主弹出独立对话框时隐藏。切回宿主恢复。
- demo 同时只附着一个宿主；模块的会话互相独立，同一个宿主重复附着返回明确错误。

这里的“附属”是行为关联，不是 `SetParent` 嵌入、不修改宿主样式、不向宿主注入 DLL。Discord 仅作为外观和体验参考；其客户端技术栈不作为游戏 overlay 实现机制的证据。

## 2. 已核查的代码基线

分支 `dev/gpui_overlay_component`，HEAD `897e3dc81230fc0d7089780e44934509fc13d855`；调查开始时工作区干净。以下是现状，后文新名称均为拟新增。

| 位置 / 符号 | 已有能力及设计影响 |
|---|---|
| [根 manifest](../Cargo.toml)、`Cargo.lock` | 三个 workspace crate；Kit 固定 0.6.4，GPUI pre 锁定 0.3.5；workspace `unsafe_code = forbid` |
| [UI 入口](../crates/app-ui/src/lib.rs) `run_with_mode` | Kit 初始化、默认主窗口、`TemplateView` 和原生 smoke；没有 overlay、外部窗口枚举或 WinEvent 订阅 |
| 同文件 `ApplicationLifecycle` / `install_last_window_quit_policy` | 只有所有 GPUI 窗口消失才退出；新增 overlay 后需先清理辅助窗口，避免主窗口关闭后进程残留 |
| [领域模块](../crates/app-core/src/lib.rs) `AppState` | 仅计数和后台计算示例；不得把 HWND 或 Win32 放入这里 |
| [desktop 入口](../crates/desktop/src/main.rs) `main` | 单一 binary、产品 identity、`--smoke-test`；增加 demo 模式而不增加产品 binary |
| [已有 UI 测试](../crates/app-ui/src/tests.rs) | Action、真实 Button、任务取消、owner drop、最后窗口退出回归需保留 |
| [依赖策略](dependency-policy.md)、[Windows 规范](windows-platform.md) | 仅 app-ui 依赖 Kit；原生代码可进入专用 adapter crate；unsafe 例外必须局部、显式；依赖 fork 需要 ADR 与验证器配套 |

另已读取本机 Cargo registry 中锁定版本的源码；可在任意机器通过 `Cargo.lock` 对应包定位：

- `gpui-pre 0.3.5/src/platform.rs`：`WindowOptions` 有 `show`、`focus`、`kind`、`window_background` 和移动/缩放选项。
- `gpui-pre 0.3.5/src/window.rs`：`Window` 实现 `raw_window_handle::HasWindowHandle`，可取得本进程 GPUI 窗口的原生句柄。
- `gpui-pre-windows 0.3.5/src/window.rs`：PopUp 默认带 TOOLWINDOW/TOPMOST；默认 DirectComposition 路径带 NOREDIRECTIONBITMAP；支持 Transparent 背景分支。`show = false` 可先配置再显示。
- `gpui-pre-windows 0.3.5/src/events.rs`：默认 `WM_MOUSEACTIVATE` 返回 MA_ACTIVATE；处理 `WM_SIZE`、`WM_MOVE`、`WM_DPICHANGED`。不能假设“不聚焦创建”等于“后续点击不激活”。

以上只证明接口和源码路径存在，未证明透明合成与跨进程穿透组合运行正确。

## 3. 可见行为

### 附着与内容

选择有效的顶层宿主后创建一个隐藏的 GPUI PopUp，配置原生行为、装载业务内容、读取最新客户区，再无激活显示。创建期间不得闪出有边框或不透明的占位窗。overlay 无独立任务栏按钮、不出现在 Alt+Tab 列表，不可由用户拖动或缩放。

内容工厂构建业务自己的 GPUI Entity/Render。模块只提供透明根容器、生命周期和状态接口；业务决定卡片、按钮、文字、动效。不能把模板主视图的不透明全屏背景复用到 overlay。业务使用 Kit 组件时负责适当的 `Root` 包装，并验证透明根背景。

### 跟随、层级与 DPI

以客户区的屏幕物理像素矩形为权威输入：读取客户区尺寸并转换两个角点到屏幕空间。使用带符号坐标支持左侧/上侧显示器；宽高为右下独占坐标差。所有 Win32 采样线程使用明确的 PerMonitorV2 DPI 上下文，恢复临时线程上下文；GPUI 布局只在边界处按 overlay 当前 scale factor 转换，不能重复缩放。

原生位置和尺寸只由跟随器设置。最大化时取最大化后的客户区，不对 overlay 自身执行最大化；还原、Snap 和跨屏后重新采样。保留 GPUI 对大小和 DPI 消息的处理，DPI 建议矩形处理完成后再用宿主矩形收敛，避免两方循环争抢位置。

| 宿主情况 | overlay 结果 |
|---|---|
| 可见、非最小化、未 cloaked、客户区非空且处于前台 | 匹配客户区并显示 |
| 拖动/缩放/最大化/还原 | 更新位置和尺寸，业务布局同步 |
| 最小化、隐藏、cloaked、空客户区 | 隐藏并保持会话，不销毁内容 |
| 其他窗口成为前台，包括宿主独立弹窗 | 隐藏；不盖住其他应用或弹窗 |
| overlay 在交互模式下因用户点击成为前台 | 继续显示，避免焦点切换造成自隐藏 |
| 宿主恢复且再次成为前台 | 先更新矩形，再无激活显示 |
| 宿主销毁或身份失效 | 关闭 overlay，终止会话，demo 保留“宿主已关闭”及重新选择入口 |

显示时可使用 TOPMOST，失去前台资格立即隐藏；这不承诺与其他 topmost 系统面板竞争，也不实现后台宿主的精确遮挡裁剪。所有跟随调用携带 NOACTIVATE，不主动将宿主拉到前台。显示之前复核前台，异步窗口切换仍可能有短暂收敛延迟。

### 输入模式

`Passthrough`（性能指标 HUD）：overlay 的不透明内容和透明区域都将真实鼠标操作交给下方窗口；不取得焦点，不吞点击/滚轮，不转发合成输入。

`Interactive`（交互界面）：整窗允许 GPUI 输入，透明区域不保证穿透；不因切换模式强制激活，用户点击后可聚焦、操作按钮及输入文字。Esc 切回穿透；若此时 overlay 自身拥有前台焦点，可尝试把焦点还给仍有效的宿主；被系统拒绝时提示点击宿主，不循环抢焦点。切回穿透需清理本窗口鼠标捕获和按键交互状态。

demo 可在控制窗口切换模式，切回宿主后验证。首版无需全局快捷键或键盘 hook；不会承诺后台热键接管游戏输入。

## 4. 模块与接口

依赖方向：`desktop -> app-ui -> app-core` 保留；新增 `app-ui -> overlay-win32`。`app_ui::overlay` 是唯一公共 GPUI overlay 入口，`overlay-win32` 是不依赖 GPUI 的 Windows adapter。这样不改变“只有 app-ui 使用 Kit”的架构约束。

| 拟新增位置 | 职责 |
|---|---|
| `crates/app-ui/src/overlay/mod.rs` | 公共接口、会话 owner、内容工厂、状态事件 |
| `crates/app-ui/src/overlay/session.rs` | GPUI 窗口创建/移除、原生通知归并、输入模式与生命周期 |
| `crates/overlay-win32/src/lib.rs` | 安全的窗口标识、枚举和跟随接口 |
| `crates/overlay-win32/src/windows/` | HWND 校验、枚举、采样、WinEvent、仅本进程 overlay 的样式和 subclass |
| `crates/app-ui/src/overlay_demo.rs` | 窗口列表、过滤/刷新、附着/分离、错误恢复和示例内容 |

接口草图（拟新增；省略 import、文档和内部异步桥接的具体类型，非现成可编译 API）：

```rust
pub enum InputMode { Passthrough, Interactive }

// HostWindowId 是不透明的已校验标识；HWND 只是借用，不拥有宿主。
pub fn attach<V: Render + 'static>(
    host: HostWindowId,
    mode: InputMode,
    build: impl FnOnce(&mut Window, &mut App) -> Entity<V> + 'static,
    cx: &mut App,
) -> Result<Entity<OverlaySession>, OverlayError>;

impl OverlaySession {
    pub fn snapshot(&self) -> OverlaySnapshot;
    pub fn set_input_mode(&mut self, mode: InputMode, cx: &mut Context<Self>);
    pub fn detach(&mut self, cx: &mut Context<Self>);
}
```

`attach` 在 GPUI 前台调用，返回初始 `Attaching` 的会话；即时参数/GPUI 创建错误通过 Result 返回，异步原生准备失败通过状态与 GPUI Event 返回。窗口枚举及 `HostWindowId` 从外部 HWND 的解析/身份采样在后台执行，再交给 attach；过期标识仍需 attach 前后二次校验。

会话 snapshot 包含 phase、宿主标识、输入模式、最新物理矩形和隐藏原因；状态变化只通过这一份权威状态发布，不另设 demo 跟随器。业务保留自己的内容 Entity 即可更新内容；无需模块理解业务模型。

`HostWindowId` 包含 HWND、PID、窗口线程 ID 及附着代次。记录销毁后永不自动重连到同数字 HWND；每次采样校验 PID/TID。Win32 无 HWND 永久唯一 token，不能声称完全消除同线程极短间隔复用的竞态；销毁终态、重采样和事件代次降低风险，测试需覆盖可观测复用。

`set_input_mode` 相同值幂等；成功原生应用后发布新状态，失败保留旧模式并报告错误。`detach` 幂等且非阻塞。关闭中的模式变更返回/发布 SessionClosed；同宿主重复附着返回 AlreadyAttached。每个 session 独立拥有资源，不使用单个全局 current HWND。

错误至少区分 InvalidHost、HostGone、UnsupportedHost、AccessDenied、AlreadyAttached、WindowCreateFailed、NativeSetupFailed、TrackingFailed、SessionClosed。保留 Win32 错误码供诊断，demo 显示可理解的原因及刷新/重选/重试动作。

## 5. 原生实现与生命周期

### 事件与收敛

每个会话一个有消息泵的原生跟踪线程，安装 OUTOFCONTEXT WinEvent：宿主 LOCATIONCHANGE、SHOW/HIDE、DESTROY、MINIMIZESTART/END，以及全局 FOREGROUND；按 HWND、对象/child ID、会话代次过滤。callback 只更新有界状态/脏标记，不执行 GPUI、不等待、不跨进程同步发消息。

事件触发完整状态采样，不把事件参数当最终几何事实。位置事件合并为最新快照，最多每 16ms 提交一次；隐藏、销毁等状态不排在位置积压后。增加 250ms 低频复核用于漏通知、cloaked 和身份检测；隐藏期间仍低频复核，终态停用。单槽最新快照加独立不可覆盖的关闭/错误状态，断连即进入清理，不允许无界消息队列。

GPUI 前台消费快照，检查会话 generation 和 owner 存活后修改本进程 overlay。平台调用不得修改宿主、附着宿主输入队列或替换宿主 WndProc。枚举/元信息在后台运行，失败单项跳过并汇总；不以宿主响应 `SendMessage` 为前提。

### 透明与鼠标行为：第一阶段必验

初始采用现有 Kit/GPUI 创建透明 PopUp，再通过 `HasWindowHandle` 获取 HWND，在其创建线程配置样式；需要时仅对自己的窗口使用 subclass，保留 GPUI 默认处理链，处理激活消息和窗口销毁清理。

Microsoft 的 layered window 文档说明 LAYERED + TRANSPARENT 的鼠标穿透，但当前 GPUI 使用 DirectComposition，组合兼容性未验证。`HTTRANSPARENT` 文档仅保证同线程后续命中，不能单独作为跨进程穿透方案。透明像素也不能当作独立可靠的跨进程输入策略。

开发首先验证现有渲染链下的整窗穿透、透明显示和可交互切换；不能以黑背景、停止渲染、截图贴图、输入转发或永远不接收鼠标作为通过。如果必须修改 GPUI 后端或改变合成方式，暂停该部分并提交具体源码证据、依赖修订与 ADR 供审查；当前 spec 不预先批准 fork。

### 资源所有权和退出

状态：`Attaching -> Attached(Visible | Hidden(reason)) -> Closing -> Closed(reason)`；附着失败先回滚，再到 Closed(error)。窗口失效和显式分离都是终态；再次附着创建新 generation。

| 资源 | owner / 释放 |
|---|---|
| GPUI overlay 窗口、业务 Entity | session 管理；主线程 `remove_window`；原生层不直接 DestroyWindow GPUI HWND |
| WinEvent hooks、消息泵、复核 timer | 原生跟踪线程；停止命令后在安装线程 unhook、停 timer、释放 callback 数据并退出 |
| subclass 和其上下文 | overlay 创建线程；移除窗口之前解除或在 NCDESTROY 安全完成，转发默认处理，不留下悬空引用 |
| GPUI 消费任务、订阅 | session；进入 Closing 先失效 generation，关闭通道/取消任务 |
| 线程 join、清理完成通知 | 应用生命周期 coordinator；后台等待，前台保持响应；禁止从 callback 或 UI 同步 join |

`detach` 顺序：失效 generation、立即隐藏、停用输入、请求停跟踪、解除本窗口原生桥接、由 GPUI 移除窗口，后台确认原生退出后发布 Closed。宿主销毁、overlay 被外部关闭、创建半途失败、session owner 被释放都进入同一条幂等路径。应用级注册表保留清理所需的弱会话和独立清理票据，不能仅依赖已销毁的业务 Entity 执行回收。

关闭 demo 控制窗口或 Quit 时先清理其全部 overlay，再进入已有最后窗口退出政策；辅助 overlay 不得使程序永远存活。清理正常目标 2s 内完成，超过 2s 显示/记录失败并继续观察至原生 smoke 的 15s 进程期限；不得在活线程仍引用数据时强制释放或声称清理完成。正常运行不得靠杀进程释放资源。应用关闭清理需要保留 coordinator 活性，完成前不调用 `cx.quit()`。

## 6. Demo 产品流程

新增 `--overlay-demo` 启动模式；默认模板示例和已有 `--smoke-test` 保持不变。两种内部模式冲突时明确报错。demo 仍使用已有产品 identity 和同一 binary。

1. 控制窗口显示标题/进程名或 PID/十六进制 HWND 的候选列表，支持标题或 PID 搜索、刷新、键盘选择；空列表和加载失败有说明。
2. 枚举当前交互桌面的可见顶层窗口（含最小化窗口）；排除本产品进程、桌面/shell、tool window、cloaked 和非顶层窗口。列表展示句柄，但不要求用户手输；显示信息缺失以 PID/HWND 兜底。
3. 点击“附着”后显示进行中状态，期间禁止重复提交；成功后展示已附着宿主、可见/隐藏原因、模式，以及“分离”。选中项与当前附着目标分别显示。
4. 提供两份业务内容：HUD 显示会话状态、几何同步延迟和更新次数等可实际测量的指标，使用半透明卡片和四角定位标记；交互界面包含计数按钮、开关和简短文本输入。指标明确标注测量对象，不把示例值称为宿主 FPS。主体保持透明，缩小时内容自适应/裁剪在客户区。模式切换替换相应展示，业务状态保留在 demo 内容 owner 中。
5. 切换输入模式，再切回宿主验证。控制窗口成为前台时 overlay 按规则隐藏，控制窗口必须解释这一点。
6. 切换宿主时先清理旧会话再附着新会话；失败后保留所选目标及重试入口，不暗中恢复旧绑定。宿主关闭后控制窗口可继续选新目标。

首版无设置持久化、自动附着、进程注入、录屏、语音、托盘或安装器。普通权限/同一交互桌面为支持基线；管理员、受保护程序、远程桌面及游戏特殊渲染路径单独标识未验证，不承诺覆盖“任意 HWND”。

## 7. 文件与依赖变更计划

- 新增上述 overlay 模块、demo 和 `overlay-win32` crate；模块为业务提供独立入口，暂不拆成另一个依赖 Kit 的 crate，也不发布包。
- 根 manifest 注册 adapter，app-ui 添加 adapter 和 `raw-window-handle = 0.6.2`；Windows API 依赖选择锁文件中兼容版本并精确固定，仅在 Windows target 启用所需 Foundation、WindowsAndMessaging、Accessibility、Dwm、HiDpi、线程/subclass 功能。最终 feature 名以所选 registry manifest 为准。
- 保持其余三个 crate 的 workspace lint 继承和全局 forbid；adapter 独立声明同等 lint，仅 windows FFI 模块显式允许 unsafe，其他部分仍禁止。每个 unsafe 注明句柄、线程、回调寿命条件。不得尝试在继承 forbid 的 app-ui 内局部 allow。
- 修改 `app-ui/src/lib.rs` 暴露 overlay、增加 demo launcher 和清理 coordinator；desktop 只加模式路由，保留已有示例和 smoke 语义。
- 在 `scripts/check-architecture.ps1` 和 `scripts/lib/UiDependencies.psm1` 加入新 crate 的依赖/unsafe 隔离检查，遍历所有 workspace crate 防止新增成员绕过 Kit 规则；扩展现有验证器正反 fixtures。此项改变允许的结构，不降低“仅 app-ui 用 Kit”和“领域无平台依赖”的要求。
- 新增原生 overlay smoke 和受控宿主 fixture，接入 `scripts/check.ps1`；先读取 scripts 目录 scoped AGENTS。更新架构、Windows 文档和 README 运行说明；在实现时记录原生 adapter/退出策略 ADR。产品名、图标和模板初始化规则保持现状。

## 8. 实施顺序与验收

### 阶段 0：审查本稿

两种模式及窗口/无边框全屏范围已确认；审查第 1 节剩余建议，特别是客户区覆盖、前台显示及交互模式整窗接收输入。用户授权开发之前只维护文档。

### 阶段 1：可行性路径

使用锁定依赖创建隐藏透明窗口并配置原生行为，附着一个受控的外进程 Win32 宿主。验证真实透明渲染、不透明内容也穿透、无激活、交互切换、跨屏 DPI 后 GPUI 布局一致和无边框。提供真实截图和鼠标/焦点结果。上述任一失败时先处理可行性，不扩展 demo UI；需要 fork 则按第 5 节回审。

### 阶段 2：模块和生命周期

完成公共接口、事件合并、跟随、隐藏、错误回滚、切换宿主、owner drop 和退出 coordinator；原生 adapter 具有可替换的内部测试输入，生产和测试共用状态转换逻辑。

### 阶段 3：demo 和完整验收

完成窗口选择和业务内容，补齐 Windows 自动化及手工证据。计划验收如下，当前均未执行：

| 验收项 | 方法及通过标准 |
|---|---|
| 内容解耦 | 同一模块分别渲染状态卡和另一简单业务 Entity，无需修改跟随代码 |
| 几何同步 | 外进程 fixture 移动/缩放/最大化/还原/Snap；稳定后客户区与 overlay 四边误差 ≤1 物理像素 |
| 延迟 | 普通 60Hz 桌面受控测试记录事件至应用位置时间，目标 P95 ≤50ms；停止拖动后 ≤100ms 收敛；漏通知由 ≤500ms 复核收敛。记录硬件/系统和样本，不能用代码中的 16ms 当性能证据 |
| 隐藏与层级 | 最小化、隐藏、切其他应用/宿主弹窗、cloaked 后隐藏；正常事件 ≤100ms、复核 ≤500ms；返回宿主先定位后显示 |
| 输入 | 外进程 fixture 记录真实系统命中的点击和滚轮；穿透时收到操作且前台不变，交互时 GPUI 按钮/文本输入有效、Esc 可退出。禁止直接向目标 PostMessage 伪造穿透证据 |
| DPI/视觉 | 100%/150%/200%，负坐标显示器和跨屏移动；透明区域真实透出内容、无黑底/边框/累积偏移，文字清晰；保存截图 |
| 异常与恢复 | 无效句柄、枚举后宿主消失、创建失败、hook 失败、原生操作失败、旧 generation 晚到、模式切换失败均有确定状态及恢复入口 |
| 生命周期 | 连续附着/分离 100 次、宿主退出、overlay 外部关闭、业务 owner drop、控制窗退出；无剩余 overlay，线程/hook 计数回基线，无旧状态提交 |
| UI 可操作性 | 列表刷新时保留有效选中项；键盘导航、空态、错误、进行中状态可辨；GPUI tests 驱动生产 Actions，覆盖重复点击和替换 |
| 模板回归 | 原有 counter/后台任务/UI 测试、native smoke、identity 检查及 generated-project fixture 仍通过 |

纯测试验证转换和迟到通知；GPUI tests 验证 Entity/Action/owner 生命周期；真实 Windows fixture 验证 HWND 几何、显隐、输入、焦点、销毁。手工视觉/DPI结果单独报告，不由 headless tests 替代。fixture 只能操作自己创建的宿主和进程，不能关闭用户窗口。

开发后运行 `scripts/check.ps1` 与 `scripts/test-generated-project.ps1`；新的 overlay smoke 必须有有界等待和失败诊断，并接入正式检查。拟提供的手工启动路径为：

```powershell
cargo run --locked -p desktop -- --overlay-demo
```

该参数当前不存在；实现完成后才可运行。打开记事本，demo 刷新并选择它，附着后切回记事本，验证移动、缩放、最小化还原、输入模式，再关闭记事本和控制窗口。

## 9. 外部依据与待验证项

本稿据以下官方协议设计，均于 2026-09-22 核查；它们不代替本项目运行验收：

- [SetWinEventHook](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook)：OUTOFCONTEXT 的注册线程需要消息循环，回调在注册线程交付。
- [Window Features](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features)：layered window 的透明和鼠标命中规则；与本 GPUI 合成链组合仍待验证。
- [WM_NCHITTEST](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-nchittest)：HTTRANSPARENT 的同线程限制。
- [SetWindowPos](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos)：位置/尺寸、Z-order、NOACTIVATE 与样式变更应用方式。
- [GetClientRect](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getclientrect) / [ClientToScreen](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-clienttoscreen)：客户区与屏幕坐标契约。

交接状态：产品审查草案可用；实施仍等待用户授权。透明合成与跨进程穿透组合、原生改尺寸后的 DPI 收敛是明确的技术可行性门槛，未作已通过声明。不同游戏的兼容性需要具体目标实测。本轮仅核查代码、协议与文档，不运行生产构建或原生实验。
