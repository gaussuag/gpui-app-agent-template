# Windows GPUI Overlay 设计规格

状态：持续实施的规格。日期：2026-09-22。层级扩展按用户已确认的[Host presentation 方案](overlay-host-presentation-design.md)执行，接受已提交异步宿主请求可能迟到的有限例外。

## 1. 目标与审查结论

在当前分支实现可复用的 `app_ui::overlay` 模块：调用方提供宿主窗口句柄和 GPUI 内容，模块创建、管理独立的无边框 Windows 窗口，并跟随宿主的位置、尺寸和可见状态。另提供窗口选择 demo，验证实际使用体验、模板的原生集成能力和资源生命周期。

用户已明确：Windows、GPUI 渲染、独立原生 overlay 窗口、宿主移动/缩放/最大化/最小化同步、模块与 demo 分离。本轮只设计规格，审查后再开发。

用户进一步确认两种模式：性能指标 HUD 只可见且不影响宿主交互；交互 overlay 有自己的界面和组件，支持鼠标与键盘输入。覆盖窗口和无边框全屏，不考虑独占全屏；具体游戏兼容性仍需实测。

用户进一步要求：Windows 相关处理集中到单一位置；overlay-gpui 层内部处理渲染适配和全部 overlay 特殊逻辑；业务自定义界面沿用普通 GPUI 窗口的 Entity、Render、Action 和组件使用方式。业务不得承担透明 Root、原生输入策略、DPI、跟随或清理补丁。

以下为本规格采用的设计默认值，并非用户逐项确认的产品要求；新任务按这些默认值实施，不需要重新询问普通实现选择：

- overlay 覆盖宿主客户区，标题栏和原生边框保留给宿主操作。
- HUD 默认整窗鼠标穿透；交互模式用户点击后可获得键盘焦点。交互模式内的局部控件命中、其余区域跨进程穿透不纳入首版。
- 默认宿主失焦仍显示，按宿主层级自然遮挡；可配置仅前台时显示。最小化、隐藏、cloaked 或空区域始终隐藏。宿主禁用时暂停 Overlay 交互。
- demo 同时只附着一个宿主；模块的会话互相独立，同一个宿主重复附着返回明确错误。

这里的“附属”是行为关联，不是 `SetParent` 嵌入、不修改宿主样式、不向宿主注入 DLL。Discord 仅作为外观和体验参考；其客户端技术栈不作为游戏 overlay 实现机制的证据。

## 2. 已核查的代码基线

分支 `dev/gpui_overlay_component`，本次复核 HEAD `63adba3c665d4e14e816cb8d49665fb1f8438b36`；工作区起始干净。该提交只新增本规格，运行代码仍为前一基线 `897e3dc81230fc0d7089780e44934509fc13d855`。以下是现状，后文新名称均为拟新增。

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
- `gpui-component 0.6.4/src/root.rs`：`Root::update` 查找实际窗口根 `Root`；`Root::render` 默认背景不透明，但实现 `Styled` 并在默认样式后 `refine_style`，可在创建时覆盖背景。Root 内建 tooltip/menu 等层，dialog/sheet/notification 另有显式 render-layer 方法。
- `gpui-pre 0.3.5/src/window.rs` 的 `on_window_should_close` 可阻止原生关闭，`app/context.rs` 有 `on_release`；`app.rs` 的 quit 流程有有界等待且退出阶段限制 foreground spawn，清理应在普通事件循环阶段完成。

以上只证明接口和源码路径存在，未证明透明合成与跨进程穿透组合运行正确。

## 3. 可见行为

### 附着与内容

选择有效的顶层宿主后创建一个隐藏的 GPUI PopUp，配置原生行为、装载业务内容、读取最新客户区，再无激活显示。创建期间不得闪出有边框或不透明的占位窗。overlay 无独立任务栏按钮、不出现在 Alt+Tab 列表，不可由用户拖动或缩放。

内容工厂构建业务自己的 GPUI Entity/Render。overlay 模块负责 Kit Root、透明根背景、弹层挂载、原生输入与生命周期；业务仅决定卡片、按钮、文字、动效，照常使用 Kit 组件，不创建第二个 Root。业务主动绘制的背景保留原样，模块只保证自身默认背景透明，不自动改写业务样式。

### 跟随、层级与 DPI

以客户区的屏幕物理像素矩形为权威输入：读取客户区尺寸并转换两个角点到屏幕空间。使用带符号坐标支持左侧/上侧显示器；宽高为右下独占坐标差。所有 Win32 采样线程使用明确的 PerMonitorV2 DPI 上下文，恢复临时线程上下文；GPUI 布局只在边界处按 overlay 当前 scale factor 转换，不能重复缩放。

原生位置和尺寸只由跟随器设置。最大化时取最大化后的客户区，不对 overlay 自身执行最大化；还原、Snap 和跨屏后重新采样。保留 GPUI 对大小和 DPI 消息的处理，DPI 建议矩形处理完成后再用宿主矩形收敛，避免两方循环争抢位置。

以下表格使用默认 `VisibilityPolicy::FollowHost`：

| 宿主情况 | overlay 结果 |
|---|---|
| 可见、非最小化、未 cloaked、客户区非空 | 匹配客户区并显示 |
| 拖动/缩放/最大化/还原 | 更新位置和尺寸，业务布局同步 |
| 最小化、隐藏、cloaked、空客户区 | 隐藏并保持会话，不销毁内容 |
| 其他窗口成为前台，包括宿主独立弹窗 | 保持宿主相对层级，由其他窗口自然遮挡；宿主 disabled 时暂停输入 |
| overlay 在交互模式下因用户点击成为前台 | 保留首击与输入；一次性异步协调宿主视觉前置，不把键盘焦点交给宿主 |
| 宿主恢复且再次成为前台 | 先更新矩形，再无激活显示 |
| 宿主销毁或身份失效 | 关闭 overlay，终止会话，demo 保留“宿主已关闭”及重新选择入口 |

Overlay 只在宿主自身 topmost 时进入同一分组；普通宿主不全局置顶。不枚举遮挡矩形裁剪。被动跟随携带 NOACTIVATE 且只调整自身；真实用户点击允许一次异步宿主 Z-order 调整。已提交请求可能迟到，未提交请求在失效时取消，禁止周期激活或重试前置。独立跨进程窗口不保证原子无过渡帧。

显隐策略与输入模式独立。`VisibilityPolicy::FollowHost` 为默认值；
`ForegroundOnly` 额外要求前台为宿主、Overlay 或原生 owner 链归属于二者的窗口，
同 Overlay 线程的 `IME` / `MSCTFIME UI` 输入辅助窗口也保留显示。其他应用、
Demo 控制窗口或前台暂时为空时报告 `Background` 并隐藏；点击交互 Overlay 不会因此隐藏自身。
最小化/隐藏/cloaked/空区域等原因优先。`set_visibility_policy` 无需宿主移动或重建内容，
通过现有驱动异步应用；snapshot 的 `visibility_policy` 为已应用值。关闭后设置返回
`SessionClosed`，重复设置不发新状态事件。策略不改变层级、焦点规则或输入模式。
Demo 提供“失焦隐藏”开关，支持附着前选择、附着后切换和下一次附着沿用；不做磁盘持久化。

### 输入模式

`Passthrough`（性能指标 HUD）：overlay 的不透明内容和透明区域都将真实鼠标操作交给下方窗口；不取得焦点，不吞点击/滚轮，不转发合成输入。

`Interactive`（交互界面）：整窗允许 GPUI 输入，透明区域不保证穿透；不因切换模式强制激活，用户点击后可聚焦、操作按钮及输入文字。Esc 优先交给正常 GPUI 组件处理（如关闭菜单、取消输入法组合、关闭弹层），未被消费时由 overlay 切回穿透，不能在原生层全局抢占 Esc。若此时 overlay 自身拥有前台焦点，可尝试把焦点还给仍有效的宿主；被系统拒绝时发布提示状态，不循环抢焦点。切回穿透需由模块清理本窗口鼠标捕获、弹层和按键交互状态，业务不参与。

demo 可在控制窗口切换模式，切回宿主后验证。首版无需全局快捷键或键盘 hook；不会承诺后台热键接管游戏输入。

## 4. 模块与接口

### 4.1 三层职责

依赖方向：`desktop -> app-ui -> app-core` 保留；新增 `app-ui -> overlay-win32`。逻辑上的 overlay-gpui 层落在 `app_ui::overlay`，是独立 Rust module，不单独创建依赖 Kit 的 crate；因此保留“只有 app-ui 使用 Kit”的现有规则。

```text
业务 UI / overlay_demo
  普通 Entity<V> + Render + Kit 组件 + Action
             |
             v
app_ui::overlay                 [overlay-gpui 层]
  open_window / OverlayWindow<V> / 状态与事件
  Kit Root、透明渲染、弹层、焦点、GPUI 生命周期
             |
             v
overlay-win32                  [Windows 层，独立 crate]
  宿主发现与校验、WinEvent、几何与可见性采样
  HWND 样式、输入策略、DPI、Z-order、subclass 与回收
```

Windows 系统知识全部收口在 `overlay-win32`：overlay-gpui 不出现 windows crate 类型、Win32 常量、WM_* 分支或 unsafe。唯一互操作入口在 `overlay/native_bridge.rs`：从真实 `Window` 借用 `raw_window_handle::WindowHandle` 交给 adapter，具体平台 variant 的解析与 HWND 转换仍在 adapter 内。

业务仅依赖 `app_ui::overlay`；连窗口枚举、外部句柄解析、窗口标题等诊断信息也从此门面访问，不直接引用 adapter。`overlay-win32` 不依赖 Kit、app-ui 或 app-core；内部状态转换可在纯测试运行，不为未来平台增加空壳实现。

| 拟新增位置 | 职责 |
|---|---|
| `crates/app-ui/src/overlay/mod.rs` | 公共门面及导出类型，隐藏原生 adapter |
| `crates/app-ui/src/overlay/window.rs` | `OverlayWindow<V>`、创建闭包、正常内容读写入口 |
| `crates/app-ui/src/overlay/root.rs` | Kit Root 组装、内部 Surface、弹层、焦点和 Esc 策略 |
| `crates/app-ui/src/overlay/session.rs` | 会话状态及 GPUI 任务，模式切换、失败回滚 |
| `crates/app-ui/src/overlay/runtime.rs` | App-global 会话所有权、owner-window 关联、退出清理票据 |
| `crates/app-ui/src/overlay/native_bridge.rs` | 唯一原生 adapter 调用点、句柄借用与线程切换，不实现 Win32 规则 |
| `crates/overlay-win32/src/lib.rs` | 安全的窗口标识、枚举和跟随接口 |
| `crates/overlay-win32/src/windows/` | HWND 校验、枚举、采样、WinEvent、仅本进程 overlay 的样式和 subclass |
| `crates/app-ui/src/overlay_demo.rs` | 窗口列表、过滤/刷新、附着/分离、错误恢复和示例内容 |

### 4.2 像普通 GPUI 窗口一样创建与更新

2026-09-22 用户确认扩展：`OverlayMargins { top, right, bottom, left }` 四边使用
`u32` 逻辑像素（96 DPI），默认全零。按宿主当前 DPI 换算，四舍五入到物理像素，
从完整客户区向内扣除；HUD 和 Interactive 均生效。留白区域既不绘制 Overlay，
也不拦截宿主输入；不模拟宿主拖动，不自动识别自绘标题栏。
`set_margins` 在原会话内异步应用，不重建内容，也不等待宿主移动。
边距过大时将剩余区域钳制为空，隐藏并报告 `EmptyViewport`；缩小边距或宿主变大后恢复。
`physical_client_rect` 仍表示宿主客户区；新增 `physical_overlay_rect` 表示实际覆盖区域，
snapshot 的 `margins` 表示已应用值。关闭后的设置返回 `SessionClosed`。
Demo 提供上/右/下/左输入和“应用边距”，拒绝负数、非整数及超出 u32 的输入，
错误时保留上一份配置；新附着继承已提交配置，普通窗口预览不参与宿主边距计算。


以下均为拟新增接口；省略 import、泛型 lifetime 和具体错误实现，不是现成可编译代码。实施时可调整 Rust 泛型细节，必须保留这些语义：

```rust
pub enum InputMode { Passthrough, Interactive }
pub enum VisibilityPolicy { FollowHost, ForegroundOnly }

pub struct OverlayOptions {
    pub owner: AnyWindowHandle, // 本应用普通窗口，非外部宿主
    pub input_mode: InputMode,
    pub visibility_policy: VisibilityPolicy, // 默认 FollowHost
    pub margins: OverlayMargins, // 默认四边为 0 的非负整数逻辑像素
}

pub fn open_window<V: Render + 'static>(
    host: HostWindowId,
    options: OverlayOptions,
    build: impl FnOnce(&mut Window, &mut App) -> Entity<V> + 'static,
    cx: &mut App,
) -> Result<OverlayWindow<V>, OverlayError>;

impl<V: Render + 'static> OverlayWindow<V> {
    pub fn content(&self, cx: &App) -> Result<Entity<V>, OverlayError>;
    pub fn update<R>(
        &self, cx: &mut App,
        f: impl FnOnce(&mut V, &mut Window, &mut Context<V>) -> R,
    ) -> Result<R, OverlayError>;
    pub fn snapshot(&self, cx: &App) -> Result<OverlaySnapshot, OverlayError>;
    pub fn observe(
        &self, cx: &mut App,
        f: impl FnMut(OverlayEvent, &mut App) + 'static,
    ) -> Subscription;
    pub fn set_input_mode(&self, mode: InputMode, cx: &mut App)
        -> Result<(), OverlayError>;
    pub fn set_margins(&self, margins: OverlayMargins, cx: &mut App)
        -> Result<(), OverlayError>;
    pub fn set_visibility_policy(&self, policy: VisibilityPolicy, cx: &mut App)
        -> Result<(), OverlayError>;
    pub fn close(&self, cx: &mut App) -> Result<(), OverlayError>;
}
```

调用示例（`BusinessPanel` 为业务自有普通 Render，`host` 为已选择宿主）：

```rust
let overlay = overlay::open_window(
    host,
    OverlayOptions { owner: window.window_handle(), input_mode: InputMode::Interactive, margins: OverlayMargins::default(), visibility_policy: VisibilityPolicy::FollowHost },
    |window, cx| cx.new(|cx| BusinessPanel::new(window, cx)),
    cx,
)?;
overlay.update(cx, |panel, window, cx| {
    panel.set_message("运行中", cx);
    // 可照常访问 Window、Context<V>、焦点和组件能力。
})?;
```

业务 Render 不需要实现 OverlayContent trait，不接收每帧宿主矩形，不自己同步 DPI，不写 Windows 条件编译。`content` 返回同一个 V Entity；`update` 在模块内部找到真实 Window 并更新 V，不要求业务找到隐藏的 Surface 或 Root。创建闭包只执行一次，普通 show/hide、缩放和模式切换不重建 V。内容 Action、Subscription、Task、`cx.notify()` 都沿用 GPUI 用法。

`open_window` 在 GPUI 前台调用，创建真实窗口与内容并返回初始 `Attaching` 会话的 handle；即时参数/GPUI 创建错误通过 Result 返回，异步原生准备失败通过状态与事件返回。成功返回不等于已显示；`Ready` 表示原生初始化、首个有效状态及内容树已就绪，后台宿主此时可为 Attached/Hidden，不等待隐藏窗口的首帧以免卡住附着。首次可见帧另由 native smoke 证明；显示前的透明和样式配置必须已完成。关闭发生在 Ready 之前时只发布 Closed，不补发 Ready。

`OverlayWindow<V>` 是可 Clone 的操作 handle，和普通 WindowHandle 类似，丢弃最后一份 handle 不关闭窗口；App-global runtime 持有会话，真实窗口树持有内容。必填的 `owner` 指定哪个普通 GPUI 窗口负责生命周期，其关闭时模块自动清理 overlay；拒绝无效 owner、overlay owner 和循环所有权。外部宿主与本应用 owner 是两个不同概念，业务不需要写 owner-close hook。业务可随时显式 `close`；内容内普通 `window.remove_window()` 也必须由模块收敛到相同清理。

窗口关闭后 `content/update/set_input_mode` 返回 SessionClosed；`close` 幂等成功。handle 保留终态诊断，不强持有 V；业务自己留存 Entity 时其寿命遵循普通 GPUI 引用规则，但不能再更新已关闭窗口。`snapshot` 在 App 有效期间可读最终状态；`observe` 先推送当前 snapshot，再按 revision 推送后续事件，晚订阅终态也能看见 Closed。订阅由调用方像普通 GPUI Subscription 一样保留；模块内部订阅不泄漏给业务。

### 4.3 宿主、状态和错误

门面提供 `list_hosts(cx: &App) -> Task<Result<HostList, OverlayError>>` 与 `resolve_host(raw: RawHostHandle, cx: &App) -> Task<Result<HostWindowId, OverlayError>>`，两者内部转后台；RawHostHandle 为可从 usize 创建的数值对象，不保证有效性，不公开 windows crate 类型或 unsafe 构造要求。`list_hosts` 返回带 HostWindowId、可显示信息及跳过项统计的快照；`resolve_host` 将已有 HWND 数值转换为同一安全标识。失败不隐式挑选其他窗口，取消结果不提交 UI；demo 对刷新请求增加 revision。完成后把 HostWindowId 传给 `open_window`，附着前后二次校验，不能信任列表刷新时的有效性。

会话 snapshot 包含 phase、宿主标识、输入模式、最新物理矩形和隐藏原因；状态变化只通过这一份权威状态发布，不另设 demo 跟随器。业务保留自己的内容 Entity 即可更新内容；无需模块理解业务模型。

`HostWindowId` 包含 HWND、PID、窗口线程 ID 及附着代次。记录销毁后永不自动重连到同数字 HWND；每次采样校验 PID/TID。Win32 无 HWND 永久唯一 token，不能声称完全消除同线程极短间隔复用的竞态；销毁终态、重采样和事件代次降低风险，测试需覆盖可观测复用。

`set_input_mode` 相同值幂等；Result 表示请求被接受，即时关闭/参数错误直接返回。异步成功原生应用后发布 ModeChanged，失败保留旧模式并发布 OperationFailed；快速请求按递增 revision 以最新目标为准，过期完成不能覆盖当前请求。业务以已应用模式更新模式标签；控制窗口可额外显示正在切换。关闭中的模式变更返回 SessionClosed，同宿主重复附着返回 AlreadyAttached。每个 session 独立拥有资源，不使用单个全局 current HWND。

OverlayEvent 包含 Ready、StateChanged、ModeChanged、OperationFailed、Closed；都携带会话 ID、单调 revision 和权威 snapshot。非致命操作失败保留会话，跟随器失效等致命错误隐藏并关闭；Closed 在每个订阅的事件流中只发生一次。常规几何信息可合并，不丢终态和错误。高频错误按分类合并为最后一条及计数，防止观察队列无限增长。

错误至少区分 InvalidHost、HostGone、UnsupportedHost、AccessDenied、AlreadyAttached、WindowCreateFailed、NativeSetupFailed、TrackingFailed、SessionClosed。保留 Win32 错误码供诊断，demo 显示可理解的原因及刷新/重选/重试动作。

### 4.4 渲染、输入和 Kit 组件适配

真实窗口树固定为 `Kit Root -> OverlaySurface<V> -> 业务 Entity<V> + Kit 弹层`。最外层必须仍是实际 `Root`，不能在 Root 外再包一个自定义 Entity 导致 `window.root::<Root>()` 查找失败。模块创建 Root 时覆盖透明背景、移除自身装饰，不改全局 theme；普通窗口背景保持原状。

OverlaySurface 内部负责挂载 sheet、dialog、notification 层，并沿用 Kit 规定的布局/叠放顺序；tooltip、menu 等 Root 已有层不重复挂载。层全部位于 overlay 客户区，业务调用普通 WindowExt/组件接口即可显示。业务只返回内容 Entity，不负责重复 render_*_layer，避免普通控件能画但弹层不可见的问题。

支持范围必须实际覆盖：Button/开关、滚动容器、输入框的键盘编辑/中文 IME/剪贴板、Tab 与 Shift+Tab、tooltip、下拉/上下文菜单、dialog/sheet/notification。保留 GPUI Windows 的文字输入、IME、光标、鼠标捕获和消息默认链；平台 subclass 只消费 overlay 特有消息，不重写业务输入分发。IME 候选窗不属于“用户切换至其他应用”：由 Windows 层识别相关输入辅助窗，避免组合输入时自隐藏；外部宿主弹窗依然按第 3 节隐藏。

首次打开可由内容闭包照常设置逻辑 FocusHandle，但显示动作不抢操作系统前台。隐藏时保存逻辑焦点、停止捕获并结束失效交互；恢复交互时恢复仍存活的焦点节点，不重置文本。模式切换关闭临时菜单/弹层并处理未完成输入法组合，状态必须明确收敛；不能把下一次宿主点击误当之前 overlay 的拖动释放。细节使用当前 Kit/GPUI 能力在 root/native_bridge 内实现并测试，不向业务增加清理 callback。

HUD 不主动刷新整窗，也不持续空转；业务指标变化用普通 notify/request-frame 驱动渲染。模块内部配置不激活窗口的动画调度，使非焦点但可见的 HUD 可更新；隐藏暂停模块自身帧请求，业务后台数据任务仍按普通 Entity 生命周期执行。应用主题/字体变化正常传递给内容，不全局改 theme 来实现透明。

“普通 GPUI 用法”不包含对宿主几何的控制：业务不对 overlay 调用移动、缩放、最大化、全屏等窗口操作；这些由模块独占，OverlayOptions 不接受这类 WindowOptions。普通 Window 用于组件、布局、焦点、输入及关闭，不能把操作系统 HWND 控制暴露为业务需求。业务自行创建的其他顶层窗口/系统文件对话框不自动成为附着窗口；普通系统窗口仍可使用，其激活不会触发 Overlay 主动抢回焦点。支持它们与宿主组成多窗口交互组属于后续范围。

### 4.5 Windows adapter 内部 seam

adapter 面向 native_bridge 提供粗粒度协议：后台 discover/resolve；前台 bind 本进程窗口；后台 watch 宿主；前台 apply 最新状态/set_mode；幂等 stop/unbind。不能让 GPUI 层逐项拼 style flags 或调用零散 Win32 getter。

原生 watch 输出 `HostSnapshot { generation, sequence, physical_client_rect, visibility_reason, dpi, input_suspended, terminal }`；adapter 计算平台可见性及身份，GPUI session 只合并其结果与业务要求的 mode/closing 状态。apply 负责最终前台复核、位置、尺寸、显隐与 Z-order 原生事务，并返回实际应用结果；GPUI 层负责触发布局/重绘和发布用户状态。watch 快照有单调 sequence；本窗口 dirty 信号独立触发协调，不因宿主 sequence 相同漏掉 Z-order 更新。交互取消 epoch 保留中间失焦事实，防止最新前台覆盖旧取消。

bind 接收借用的 raw-window-handle，adapter 校验为本进程、正确线程窗口后建立非 Send 的 WindowBinding；Windows 句柄只在 adapter 内暂存，并非获得窗口销毁权。WindowBinding 只在创建线程使用，live 标记和原生销毁通知使过期调用失败，正常关闭前先 unbind；内部 callback 不持有 GPUI 引用。watch 只拥有宿主的借用身份和自己的 hooks，不拥有宿主窗口。所有 Win32 FFI、thread DPI scope、hook 注册/卸载、subclass 和真实输入 smoke helper 都位于 adapter 的 windows 子目录。

测试用 adapter 在此内部 seam 注入快照与操作失败，业务门面不增加 test-only HWND 或假 Render；真实 Windows 测试另行证明 FFI 和线程约束。

## 5. 原生实现与生命周期

### 事件与收敛

每个会话一个有消息泵的原生跟踪线程，安装 OUTOFCONTEXT WinEvent：宿主 LOCATIONCHANGE、SHOW/HIDE、DESTROY、MINIMIZESTART/END，以及全局 FOREGROUND；按 HWND、对象/child ID、会话代次过滤。callback 只更新有界状态/脏标记，不执行 GPUI、不等待、不跨进程同步发消息。

事件触发完整状态采样，不把事件参数当最终几何事实。位置事件合并为最新快照，最多每 16ms 提交一次；隐藏、销毁等状态不排在位置积压后。增加 250ms 低频复核用于漏通知、cloaked 和身份检测；隐藏期间仍低频复核，终态停用。单槽最新快照加独立不可覆盖的关闭/错误状态，断连即进入清理，不允许无界消息队列。

GPUI 前台消费快照，检查会话 generation 和 owner 存活后，通过 native_bridge 请求 adapter 修改本进程 overlay；原生操作结果再提交 GPUI 状态。除用户点击后一次异步 Z-order 调整外，不修改宿主；不附着宿主输入队列或替换宿主 WndProc。枚举/元信息在后台运行，失败单项跳过并汇总；不以宿主响应 `SendMessage` 为前提。

### 透明与鼠标行为：第一阶段必验

初始采用现有 Kit/GPUI 创建透明 PopUp，再由 native_bridge 通过 `HasWindowHandle` 借用原生 handle 交给 adapter。adapter 内解析 HWND、在创建线程配置样式；需要时仅对自己的窗口使用 subclass，保留 GPUI 默认处理链，处理激活消息和窗口销毁清理。

Microsoft 的 layered window 文档说明 LAYERED + TRANSPARENT 的鼠标穿透，但当前 GPUI 使用 DirectComposition，组合兼容性未验证。`HTTRANSPARENT` 文档仅保证同线程后续命中，不能单独作为跨进程穿透方案。透明像素也不能当作独立可靠的跨进程输入策略。

开发首先验证现有渲染链下的整窗穿透、透明显示和可交互切换；不能以黑背景、停止渲染、截图贴图、输入转发或永远不接收鼠标作为通过。如果必须修改 GPUI 后端或改变合成方式，暂停该部分并提交具体源码证据、依赖修订与 ADR 供审查；当前 spec 不预先批准 fork。

### 资源所有权和退出

状态：`Attaching -> Attached(Visible | Hidden(reason)) -> Closing -> Closed(reason)`；附着失败先回滚，再到 Closed(error)。窗口失效和显式分离都是终态；再次附着创建新 generation。

| 资源 | owner / 释放 |
|---|---|
| GPUI overlay 窗口、业务 Entity | runtime 持有 session，真实窗口树持有业务 Entity；主线程 `remove_window`；原生层不直接 DestroyWindow GPUI HWND |
| WinEvent hooks、消息泵、复核 timer | 原生跟踪线程；停止命令后在安装线程 unhook、停 timer、释放 callback 数据并退出 |
| subclass 和其上下文 | overlay 创建线程；移除窗口之前解除或在 NCDESTROY 安全完成，转发默认处理，不留下悬空引用 |
| GPUI 消费任务、订阅 | session；进入 Closing 先失效 generation，关闭通道/取消任务 |
| 线程 join、清理完成通知 | overlay runtime 的清理 coordinator；adapter 后台等待并返回完成票据，前台保持响应；禁止从 callback 或 UI 同步 join |

`close` 顺序：失效 generation、立即隐藏、停用输入、请求停跟踪、解除本窗口原生桥接、由 GPUI 移除窗口，后台确认原生退出后发布 Closed。宿主销毁、overlay 被外部关闭、创建半途失败、本应用 owner 窗口被移除都进入同一条幂等路径。runtime 持有活跃 session 与独立清理票据，窗口树只持 session 的弱引用，避免引用环；Closed 后从活跃注册表移除并释放内容，操作 handle 只保留终态记录。Drop 操作 handle 或业务观察订阅不触发关闭，与第 4.2 节一致。

关闭 demo 控制窗口或 Quit 时触发全部相关 overlay 清理，清理完成后才允许最后窗口退出政策终止进程；辅助 overlay 不得使程序永远存活。清理正常目标 2s 内完成，超过 2s 显示/记录失败并继续观察至原生 smoke 的 15s 进程期限；不得在活线程仍引用数据时强制释放或声称清理完成。正常运行不得靠杀进程释放资源。应用关闭清理需要保留 coordinator 活性，完成前不调用 `cx.quit()`。

overlay runtime 随 app-ui 初始化一次，重复初始化幂等。现有 `ApplicationLifecycle` 只调用模块的单一 `prepare_quit` 完成通知再执行最终 quit，不遍历 hooks 或实现关闭顺序。owner 移除通过 on_window_closed 触发子 overlay 清理，并把零窗口 quit 延迟至票据完成；不覆写业务已有的 on_window_should_close，以保留普通窗口的取消关闭/未保存确认能力。用户 Quit 先请求所有会话清理，再退出；owner 原生关闭允许 owner 先消失，模块在同一轮通知中隐藏其 overlay。最后窗口政策和用户 Quit 共用同一完成屏障。`on_app_quit` 仅作最后防线，不能到此时才创建需要 foreground 更新的清理任务。主窗口不需要在业务 Render 中挂任何原生或 overlay 清理钩子。

## 6. Demo 产品流程

新增 `--overlay-demo` 启动模式；默认模板示例和已有 `--smoke-test` 保持不变。两种内部模式冲突时明确报错。demo 仍使用已有产品 identity 和同一 binary。

1. 控制窗口显示标题/进程名或 PID/十六进制 HWND 的候选列表，支持标题或 PID 搜索、刷新、键盘选择；空列表和加载失败有说明。
2. 枚举当前交互桌面的可见顶层窗口（含最小化窗口）；排除本产品进程、桌面/shell、tool window、cloaked 和非顶层窗口。列表展示句柄，但不要求用户手输；显示信息缺失以 PID/HWND 兜底。
3. 点击“附着”后显示进行中状态，期间禁止重复提交；成功后展示已附着宿主、可见/隐藏原因、模式，以及“分离”。选中项与当前附着目标分别显示。
4. 提供两份业务内容：HUD 显示会话状态、几何同步延迟和更新次数等可实际测量的指标，使用半透明卡片和四角定位标记；交互界面包含计数按钮、开关、文本输入、滚动列表、菜单和弹层示例。指标明确标注测量对象，不把示例值称为宿主 FPS。主体保持透明，缩小时内容自适应/裁剪在客户区。两份内容由一个普通 DemoContent Entity 根据已应用模式投影，切换不重建 Entity；输入文本和计数保留。
5. 切换输入模式，再切回宿主验证。控制窗口成为前台时按正常层级遮挡 Overlay；界面显示模态输入暂停与错误状态。
6. 切换宿主时先清理旧会话再附着新会话；失败后保留所选目标及重试入口，不暗中恢复旧绑定。宿主关闭后控制窗口可继续选新目标。

首版无设置持久化、自动附着、进程注入、录屏、语音、托盘或安装器。普通权限/同一交互桌面为支持基线；管理员、受保护程序、远程桌面及游戏特殊渲染路径单独标识未验证，不承诺覆盖“任意 HWND”。

另提供“在普通窗口预览同一内容”：相同 DemoContent Render 和组件处理代码放入标准 Kit 窗口，用于对照 Action、输入法、弹层、布局和主题。仅创建入口/根包装由两种窗口容器负责，内容内部不得出现 `if overlay` 的平台兼容分支。demo 使用门面列举宿主、创建窗口并观察状态，不准补写坐标跟随、Root 层、focus 修复或清理代码来绕过模块缺陷。

## 7. 文件与依赖变更计划

- 新增上述 overlay 模块、demo 和 `overlay-win32` crate；模块为业务提供独立入口，暂不拆成另一个依赖 Kit 的 crate，也不发布包。
- 根 manifest 注册 adapter，app-ui 添加 adapter 和 `raw-window-handle = 0.6.2`；Windows API 依赖选择锁文件中兼容版本并精确固定，仅在 Windows target 启用所需 Foundation、WindowsAndMessaging、Accessibility、Dwm、HiDpi、线程/subclass 功能。最终 feature 名以所选 registry manifest 为准。
- 保持其余三个 crate 的 workspace lint 继承和全局 forbid；adapter 独立声明同等 lint，仅 windows FFI 模块显式允许 unsafe，其他部分仍禁止。每个 unsafe 注明句柄、线程、回调寿命条件。不得尝试在继承 forbid 的 app-ui 内局部 allow。
- 修改 `app-ui/src/lib.rs` 暴露 overlay、增加 demo launcher，初始化 overlay runtime 并让 ApplicationLifecycle 经单一 prepare_quit 接口退出；具体 coordinator 全部放在 overlay/runtime.rs。desktop 只加模式路由，保留已有示例和 smoke 语义。
- 在 `scripts/check-architecture.ps1` 和 `scripts/lib/UiDependencies.psm1` 加入新 crate 的依赖/unsafe 隔离检查，遍历所有 workspace crate 防止新增成员绕过 Kit 规则；扩展现有验证器正反 fixtures。此项改变允许的结构，不降低“仅 app-ui 用 Kit”和“领域无平台依赖”的要求。
- 新增原生 overlay smoke 和受控宿主 fixture，接入 `scripts/check.ps1`；先读取 scripts 目录 scoped AGENTS。更新架构、Windows 文档和 README 运行说明；在实现时记录原生 adapter/退出策略 ADR。产品名、图标和模板初始化规则保持现状。
- 原生 fixture 的实现放在 adapter windows 测试模块，example/脚本仅做启动与调度；生产及测试的 Windows 特殊逻辑都可在该位置找到。非 Windows target 可编译纯状态测试，原生门面返回 UnsupportedPlatform，不能静默运行假 backend。不新增第二个 desktop binary。

## 8. 实施顺序与验收

### 阶段 0：新任务接手

用户在新任务明确要求“按此 spec 开发”后，即可执行后续阶段；不必再次重做需求访谈或等待本任务启动实现。先复核 Git、锁文件及相关源码，采用第 1 节默认值；有源码漂移时修订实现计划，不静默改变需求。普通模块内部细节自主处理；依赖 fork 或必须改变用户可见行为时报告具体冲突。本任务不创建新任务或实现代码。

### 阶段 1：可行性路径

使用锁定依赖沿三层结构创建隐藏透明窗口并配置原生行为，附着一个受控的外进程 Win32 宿主。验证真实透明渲染、不透明内容也穿透、无激活、交互切换、跨屏 DPI 后 GPUI 布局一致和无边框；同时验证真实 Kit Root、输入框与一个 dialog，证明无需业务补丁。提供真实截图和鼠标/焦点结果。上述任一失败时先处理可行性，不扩展 demo UI；需要 fork 则按第 5 节回审。

### 阶段 2：模块和生命周期

完成公共接口、事件合并、跟随、隐藏、错误回滚、切换宿主、owner-window 关闭和退出 coordinator；原生 adapter 具有可替换的内部测试输入，生产和测试共用状态转换逻辑。完成内容 handle、最后 handle drop 不关闭、业务 remove-window 清理及晚订阅终态的测试后再进入 demo。

### 阶段 3：demo 和完整验收

完成窗口选择和业务内容，补齐 Windows 自动化及手工证据。计划验收如下，当前均未执行：

| 验收项 | 方法及通过标准 |
|---|---|
| 分层隔离 | 业务只使用 overlay 门面；Win32 类型/常量/unsafe/原生测试实现集中 adapter；native_bridge 是唯一调用点。检查生产依赖及源码，禁止 demo 含兼容补丁 |
| 内容解耦 | 同一个 DemoContent Render 放入普通 Kit 窗口和 overlay，不加条件分支即可操作；open 闭包一次，缩放/隐藏/模式切换保持 Entity 身份、文本和计数 |
| 普通组件能力 | 两种容器对照 Button、滚动、Tab/Shift+Tab、中文 IME、剪贴板、tooltip、菜单、dialog/sheet/notification；overlay 自动挂层，无重复背景或失效 Root 查找；Esc 先关闭弹层，再退出交互 |
| 几何同步 | 外进程 fixture 移动/缩放/最大化/还原/Snap；稳定后客户区与 overlay 四边误差 ≤1 物理像素 |
| 延迟 | 普通 60Hz 桌面受控测试记录事件至应用位置时间，目标 P95 ≤50ms；停止拖动后 ≤100ms 收敛；漏通知由 ≤500ms 复核收敛。记录硬件/系统和样本，不能用代码中的 16ms 当性能证据 |
| 隐藏与层级 | 最小化、隐藏、切其他应用/宿主弹窗、cloaked 后隐藏；正常事件 ≤100ms、复核 ≤500ms；返回宿主先定位后显示 |
| 输入 | 外进程 fixture 记录真实系统命中的点击和滚轮；穿透时收到操作且前台不变，交互时 GPUI 按钮/文本输入有效、Esc 可退出。禁止直接向目标 PostMessage 伪造穿透证据 |
| DPI/视觉 | 100%/150%/200%，负坐标显示器和跨屏移动；透明区域真实透出内容、无黑底/边框/累积偏移，文字清晰；保存截图 |
| 异常与恢复 | 无效句柄、枚举后宿主消失、创建失败、hook 失败、原生操作失败、旧 generation 晚到、模式切换失败均有确定状态及恢复入口 |
| 生命周期 | 连续附着/分离 100 次、宿主退出、overlay 外部关闭、owner-window 移除、内容 remove-window、控制窗退出；无剩余 overlay，线程/hook 计数回基线，无旧状态提交；最后 handle drop 不关闭，关闭后晚订阅看到终态 |
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

交接状态：分层、接口、内容兼容、所有权和实施顺序已经收敛，新任务可根据本规格从阶段 1 开始开发。透明合成与跨进程穿透组合、原生改尺寸后的 DPI 收敛及 Kit 弹层/IME 集成是明确的技术可行性门槛，未作已通过声明；这些前置验证不是缺少需求的占位符。不同游戏兼容性需要具体目标实测。本任务仅修订规格，不运行生产构建或原生实验。
