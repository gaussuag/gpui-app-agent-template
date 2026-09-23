# Overlay 宿主层级与交互协调技术方案

日期：2026-09-22。状态：实现中，真实桌面交互与性能验收尚待完成。

用户已选择继续支持任意外部 HWND，并接受有限例外：已经提交的异步宿主层级请求，
可能在宿主恢复消息泵后迟到生效。未提交请求仍取消；禁止周期抢焦点和重复前置。
这一明确决定替代本文原先“任何过期效果都不得生效”的硬门槛。
[阶段 0 记录](overlay-presentation-stage0.md)保留原语反例，不改写为成功证据。
锁屏或真实桌面前提不满足的测试可留待人工，不据此宣称验收通过。

当前代码基线：`f1d4bb55fffd368800766a8876f858f27ea72ef5`。
本方案承接 [Overlay spec](overlay-gpui-spec.md)，讨论用户新要求：不建立原生 owner/parent，
Overlay 在视觉、遮挡和交互上接近宿主内嵌内容。实现与实际验证进度见[进度记录](overlay-implementation-progress.md)。

## 1. 推荐结论与保证范围

采用一个内部 `HostPresentation` Module，统一管理宿主事实、显隐、Z-order 和用户交互意图。
保留现有 GPUI facade Interface、内容 Entity、margins 和生命周期；业务不接触 Win32 消息或层级修复。
普通跟随只移动 Overlay 自己；**真实用户点击交互 Overlay** 才允许一次宿主层级协调。
不通过定时激活、全局置顶、原生 owner、SetParent 或 AttachThreadInput 模拟内嵌。

默认目标是：失焦仍显示，其他应用自然遮住宿主与 Overlay；点击露出的 Overlay 内容，
宿主也随之进入前面的视觉组合，原始点击和后续键盘输入仍交给 Overlay。
这里“宿主一起前置”指视觉层级，不表示两个独立窗口可以同时持有前台或键盘焦点。
游戏若在失焦时暂停、停止渲染或改变输入策略，需要游戏自身配合；本方案不伪造 WM_ACTIVATE。

独立跨进程窗口没有 Windows 提供的原子组合保证。本方案不承诺完全没有过渡帧，
也不把“异步调用已返回”当作完成、可取消或性能达标。阶段 0 专门验证最难的激活路径；
已确认裸异步调用存在迟到效果；按用户接受的例外继续实现，不能将被动跟随包装成已经验证第二种交互目标。

## 2. 当前实现事实：已合并，尚未统一协调

| 位置 | 当前行为 | 本次处置 |
|---|---|---|
| `overlay-win32/src/signal.rs` | 一个 pending 位和一个 Waker，先写状态再通知，不排消息队列 | 复用 |
| `windows/watch.rs::event/run` | 单 worker；回调只记 DIRTY/DESTROYED；16ms 节流、250ms 补偿 | 扩展失效原因与消息泵预算 |
| `HostWatch.latest` | `Mutex<Option<HostSnapshot>>` 单槽覆盖；终态不再覆盖 | 保留有界快照与终态优先 |
| `overlay/driver.rs` | generation/sequence 检查；原生调用在 GPUI borrow 外执行 | 保留，加入 presentation revision |
| `windows/host.rs::sample` | 区分最小化、隐藏、cloaked、空区域及 Background | 移除“其他应用前台必隐藏”的规则 |
| `windows/mod.rs::apply_host` | 最终重采样；几何变化或重新显示才 SetWindowPos；强制 TOPMOST | 独立计算 geometry/order/visibility 差异 |
| `windows/mod.rs::flush_style` | 切模式也会强制 TOPMOST | 改为保留现有层级的样式刷新 |
| own HWND subclass | DPI 标记、销毁、HUD 鼠标不激活、阻止自身系统移动缩放 | 保留，加本窗口交互意图记录 |
| 锁定 `gpui-pre-windows 0.3.5` | WM_MOUSEACTIVATE 返回 MA_ACTIVATE；GPUI 有自己的捕获与焦点处理 | 不重复实现，不任意吞首击 |

所以现状已有消息合并和顺序保护，但**geometry sequence 并不能表达所有 Z-order/用户意图变化**。
现有 `sequence 相同且 margins 相同则返回` 必须调整，否则窗口没有移动时的层级修复会被跳过。
当前 worker 的 `while PeekMessageW` 没有批次预算；新添全局层级事件前需限制一次排空工作量。

代码入口：
[driver](../crates/app-ui/src/overlay/driver.rs)、
[native binding](../crates/overlay-win32/src/windows/mod.rs)、
[watch](../crates/overlay-win32/src/windows/watch.rs)、
[signal](../crates/overlay-win32/src/signal.rs)、
[lifecycle ADR](decisions/0009-native-overlay-lifecycle.md)。

## 3. 参考 SDK：提取约束，不移植结构

参考仓库：`D:/workspace/repository/unitysdk`。
固定提交：`c030ca8bbb6279c9fe926af811d1bf9c7dac348c`。
核对材料为该提交的以下路径，避免将之后工作区变更混入证据：

- `UnityPCChannel/GiantSDK/GiantSDK/GiantSDKHostWindowUtils.h`
- `UnityPCChannel/GiantSDK/GiantSDK/HostWindowManager.cpp`
- `UnityPCChannel/GiantSDK/tests/account-register/HostOverlayTests.cpp`
- `UnityPCChannel/GiantSDK/docs/webview/overlay-activation-drag-troubleshooting-20260921.md`

指定提交修复的是**原生激活判定与非客户区交互保护**，没有重写整体 Z-order 策略。
其案例记录 WebView2 输入后 Qt active 状态与 Win32 不一致，以及修复前置后标题栏拖动被破坏的 A/B。
这些是参考项目的证据，不能算本项目已验证 WebView2。

| 可借鉴的经验 | 本方案如何落实 |
|---|---|
| Framework active 不等于原生 foreground/focus | 使用原生事实判断；GPUI FocusHandle 只代表内容焦点 |
| WM_MOUSEACTIVATE 早于进入移动循环 | 不因“宿主激活”自动激活 Overlay，从规则上保护首次标题栏点击 |
| captionPending 覆盖 move-size-start 之前的间隙 | 外部方案不假设能收到宿主这一消息；不复制同线程状态机 |
| 同步调用会重入，目标可能在回调中销毁 | 原生状态写入与副作用分离；generation/live/weak 检查 |
| Z-order 修复会再次触发窗口消息 | 幂等差异计算；自身事件仍重采样，不按消息次数盲目忽略 |
| A/B 与真实输入能揭露状态测试遗漏 | 验收首击、拖动起始、双击、任务栏、原生子窗口焦点 |

不照搬 `HostWindowManager::refresh()` 中每次同步排列遮罩和宿主的方式，
不照搬恢复时无条件 `raise()`，也不将 `QTimer::singleShot(1, ...)` 当时序保证。
参考 SDK 的 WH_CALLWNDPROC 安装在初始化线程；当前 Module 是外部宿主 + WINEVENT_OUTOFCONTEXT，
不能直接取得外部宿主的全部 WndProc 消息。获取这些消息将改变进程/线程和注入约束，本期不做。

## 4. 三种 Interface 设计与选择

**A：整体升级跟随语义（默认行为）。**
`OverlayOptions { owner, input_mode, margins, visibility_policy }` 不增加层级、激活或计时参数；
`open_window/update/set_input_mode/set_margins/close/observe` 继续使用。
Depth 来自一次附着获得完整协调能力；Locality 集中在 native Module。
现有 `owner` 仍只是本应用生命周期窗口，不设置原生 GWLP_HWNDPARENT，不承担宿主层级关系。

**B：显隐策略（2026-09-23 用户要求，现已加入）。**
`VisibilityPolicy::FollowHost` 默认保持 A 的行为；`ForegroundOnly` 可选失焦隐藏。
`set_visibility_policy` 支持原会话动态切换，HUD/Interactive 均适用；宿主、Overlay、
二者原生 owned 窗口或 Overlay 输入法辅助窗口在前台时保持显示，其他情况隐藏。
具体优先级与接口见 [spec](overlay-gpui-spec.md)。这仅是显隐策略，不能改变
topmost/activation 规则；不建立原生 ownership，也不把所有同进程窗口当作宿主。

**C：增加显式宿主协作 Adapter。**
由游戏 UI 线程执行带期限、代际和确认的用户前置请求，执行前拒绝失效意图。
可控宿主下保证更强，但引入接入和协议成本，不再是仅凭任意外部 HWND 即可使用。
仅在 A 的原生验证不能满足要求时回到此选项，不预建通用 IPC 或插件体系。

用户已选择 A 并接受已提交请求的迟到例外；C 不进入本期支持范围。
B 不作为默认实现。三种设计都禁止业务逐个调用 bring-to-front、repair-z-order 等浅层 Interface。

## 5. 深 Module 与内部 Seam

```text
业务 / Demo：现有 OverlayWindow Interface
                   ↓
GPUI Session + driver：内容、生命周期、已应用状态
                   ↓ native_bridge（唯一原生入口）
HostPresentation Module
  事实观察 → 纯 reconcile 决策 → 原生效果 → 重新观察确认
  最新状态槽 / 单个用户意图 / 代际与局部 revision
                   ↓
Win32 Adapter（生产） / 脚本化 Adapter（确定性测试）
```

这些是现有 Module 的深化，不另起与 driver 竞争的定时协调器。
建议 `overlay-win32/src/presentation.rs` 放纯状态与决策，`windows/presentation.rs` 放采样和效果。
Windows FFI 仍全部在 `windows/`，GPUI 内容不感知它们。

内部 Interface 示意（不是冻结后的公开类型）：

```rust
reconcile(observation, desired, intent, previous) -> ApplyPlan
apply(plan, expected_epoch) -> ApplyOutcome
```

`observation` 是新读取的身份、客户区/DPI、可见性、enabled、前台、焦点/捕获、topmost 分组及层级邻居。
`desired` 包含 mode/margins/closing；`intent` 仅来自本窗口真实交互；
`ApplyPlan` 分开 geometry、order、visibility、input suspension 与一次性 host promotion。
`ApplyOutcome` 区分完成、等待原生确认、取消、拒绝、失败，不能以调用次数代替结果。

纯决策是 in-process 依赖；Win32 是 true-external 依赖。
真实 Adapter 与脚本化 Adapter 是两个实际需要的实现，因此这个内部 Seam 有测试价值。
不为未来平台建立空实现，也不导出通用 HWND registry 给业务。

## 6. 可观察行为契约

| 情形 | 建议行为 |
|---|---|
| 宿主失焦但仍可见 | Overlay 继续显示；不激活、不前置宿主 |
| 其他应用覆盖部分或全部宿主 | 由 Z-order 自然遮挡 Overlay，不枚举遮挡矩形做裁剪 |
| 宿主最小化、隐藏、cloaked、空 viewport | 隐藏；内容与输入草稿保留 |
| 通过任务栏/Alt-Tab 激活宿主 | Overlay 无激活跟随到宿主上方；不自动把键盘焦点抢给 Overlay |
| 点击 Overlay 内容 | 原始点击正常分发，协调宿主视觉前置，键盘仍由被点内容接收 |
| 点击/拖动宿主标题栏、边框、margins 留白 | 由宿主处理；禁止被动激活 Overlay |
| 宿主弹出模态窗口 | 模态窗保持在 Overlay 上方；宿主 disabled 时暂停 Overlay 交互，恢复后恢复原请求模式 |
| 显示桌面/虚拟桌面切换 | 不以激活修复对抗系统；不可见的宿主不留下孤立 Overlay |
| 普通/置顶宿主切换 | Overlay 跟随同一层级分组，不更改宿主 topmost 属性 |
| 关闭、宿主销毁或重新附着 | 终态优先，旧意图与尚未提交的效果失效；已提交外部效果见第 8 节限制 |

“暂停交互”是内部有效状态，不能把用户请求的 Interactive 永久改成 HUD。
优先使用自有窗口的原生禁用/恢复并交给 GPUI 正常失焦路径；由阶段 0 验证捕获释放与恢复。
若需要隐藏作为降级，应明确记录原因，不能伪报宿主被最小化。
不按 PID 判断全部宿主弹窗；不重新排列宿主已有 owner/owned 家族，不绕过系统模态关系。
宿主层级写入可能触发系统对 owned 窗口的联动；不能仅凭 NOOWNERZORDER 推断整个家族保持不变。
阶段 0 必须读取实际结果，证明模态窗口不会被压到 Overlay 后面。

## 7. 被动 Z-order 跟随

稳定不变量为：`原本在宿主上面的其他窗口 > Overlay > 宿主`。
排除 Overlay 自己和已明确登记的本会话原生表面后，找宿主上方的插入邻居。
只有实际不满足位置或分组约束时才调整自身 HWND。已经相邻时零操作。

- `hWndInsertAfter` 表示新位置之前的窗口，直接传宿主会将 Overlay 放到宿主后面。
- 普通与 topmost 分组分别处理；普通宿主不能因为上一个邻居是 topmost 就把 Overlay 升成 topmost。
- 宿主位于普通组顶部时使用普通组顶部位置；宿主位于 topmost 组时才允许自身进入该组。
- 插入锚点向宿主上方有界查找，排除 Overlay 自己及同组隐藏辅助窗口（外部 IME
  窗口可能拒绝作为插入锚点）。遇到可见窗口即停止；普通宿主遇到第一个 topmost
  边界也必须停止，即使该边界窗口隐藏。不能跨过它，也不能替换成 `HWND_TOP`，
  后者受前台权限限制，可能让 Overlay 留在激活宿主后面。视觉相邻判断仍跳过所有
  隐藏窗口；它与原生插入锚点是不同的查询目的。
- 从旧模式遗留或宿主降级带来的 topmost 状态必须真正解除。
- band 变化如需要多次调用，优先采用不暴露错误中间层级的顺序；原生截图/轨迹验证后冻结。
- 几何不变但 order 变化：只改层级；不要触发无意义的 renderer resize 或 notify。
- 正常跟随带 NOACTIVATE；样式刷新带 NOZORDER。不得在刷新样式时隐式升层。

以上依据 [SetWindowPos](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos)
和 [Z-order 分组](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features)。

邻居采样不是原子桌面快照。查询前后验证宿主身份、前台与本地 epoch，
失效则放弃本次计划，等待下次合并协调。查询使用有限步数，不能无限遍历 GetWindow 链。
阶段 0 以 64 个邻接查询为单次上限；超限报告暂时无法确认，不退回全局 TOPMOST。

## 8. 用户激活：保留首击，避免 host→overlay 焦点往返

推荐先验证这个候选顺序：

1. 自有 Interactive HWND 收到 WM_MOUSEACTIVATE 时，记录一次性 `UserIntent`。
   消息回调只复制值、写状态和唤醒，不执行宿主操作，不进入 GPUI update。
2. 保留 GPUI 的正常 MA_ACTIVATE 和原始 mouse-down 路径，不使用 ANDEAT、SendInput 或重放首击。
3. 离开消息处理/GPUI borrow 后，确认原生 foreground 属于本会话、宿主有效且 enabled、
   未最小化/cloaked，意图未被用户切换应用或关闭取代。
4. **只调整宿主 Z-order 到已激活 Overlay 下方**，保持宿主尺寸、位置与 topmost 属性；
   不先 SetForegroundWindow(host) 再夺回 Overlay。这样避免临时游戏焦点和浏览器焦点往返。
5. 等实际层级与焦点符合目标，消费意图；随后回到只移动 Overlay 的被动协调。

这里对宿主的唯一新增写入授权是用户触发的层级调整；当前 spec“只写本窗口”的范围必须随新需求明确修订。
后台事件、Ready、计时器、宿主 WM_ACTIVATE/前台事件不产生用户激活权限。
`GetAsyncKeyState(VK_LBUTTON)` 只能辅助观察，不能证明用户点击了 Overlay；任务栏也会涉及左键。

WM_MOUSEACTIVATE 在鼠标激活和后续按键消息之间发挥作用，MA_ACTIVATE 保留鼠标消息。
参见 [WM_MOUSEACTIVATE](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mouseactivate)。
前台、活动窗口与 focus 分开判断；跨线程不拿当前线程 GetActiveWindow 代表宿主，
需要时读取并重新验证 [GetGUIThreadInfo](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getguithreadinfo)。

**关键困难不是 epoch 字段，而是外部线程执行时机。**
同步 SetWindowPos 外部宿主可能引入线程等待；SWP_ASYNCWINDOWPOS 能将不同输入队列的操作投递，
但提交后不提供本地撤销句柄。设置 200ms/500ms 超时、切换 epoch、将调用放到后台线程，
都不能证明已提交的原生操作被撤销。不得写成“超时即取消成功”。

阶段 0 对上述顺序使用真实跨进程宿主，记录调用时长与原生生效时间。
一次意图最多发一个宿主前置操作，未确认前不再积累同类请求。
前台离开会话、宿主销毁/最小化/禁用、mode 变更、会话关闭：取消所有尚未提交的效果；
对已提交效果只能标记“待确认/结果未知”，被动修正自身层级，不能宣称撤销。
必须记录宿主暂停消息泵→上下文改变→恢复后的真实结果。用户已接受提交后可能迟到，
因此原语反例不再阻断开发；仍禁止重复投递。最多等待 500ms 观察层级，超时或未确认即离开会话
则标记结果未知、恢复被动跟随并提示重新附着；本会话不再提交前置请求。这个超时不是系统请求取消。

`SetForegroundWindow` 也受系统前台策略限制，拒绝时停止本次尝试，不循环抢焦点。
见 [前台权限](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)。
当前模式切换返回宿主焦点的路径仍需纳入同一“明确用户操作、一次请求、拒绝可见”约束。

## 9. 事件合并、顺序与反馈抑制

区分以下输入，不能都当成可丢弃的几何快照：

| 输入 | 存储与优先级 |
|---|---|
| Geometry/Visibility/Order/DPI/Focus 等失效通知 | dirty 位集合 + 最新事实单槽，中间重复值可合并 |
| 一次性用户激活意图 | 独立单槽：session generation、intent id、创建时间、取消状态；最多一个执行中 |
| Closing/HostGone | 粘性终态，先失效意图、隐藏与停止，再清理 |

增加本地 `presentation_revision`，与宿主 `sequence` 分开；自己的激活、层级消息或 margins 更新
即使没有新宿主 sequence 也能触发协调。旧 generation 永远不能提交。
取消早于重新激活；被合并掉的“用户已离开会话”须使旧 intent 永久失效，即使最新前台又回到了本会话。
不要只保存最后一个 foreground HWND 丢掉中间取消事实。

继续现有 foreground、host show/hide/destroy/location/minimize 监听，增加窄范围的
move-size、state/cloak/uncloak 及经过验证的顶层 show/hide/reorder 失效来源。
全局事件回调只做可低成本判断和置位；不要在 callback 枚举桌面、查询 COM/UIA、记录标题或刷新 GPUI。
`EVENT_OBJECT_REORDER` 不保证覆盖每种顶层重排，因此保留补偿采样；它可能对应父容器，不能只按 host HWND 过滤。
[WinEvent 常量](https://learn.microsoft.com/en-us/windows/win32/winauto/event-constants)明确描述其容器语义。

Out-of-context 事件按队列传递，但回调可重入，完成顺序不能被当作全局因果顺序。
[SetWinEventHook](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook)
文档也要求处理这一点。原始 LPARAM 中的临时指针不得保留。

- 回调记录，单个 driver 消费；一次 native apply 期间 reentry 只置 dirty，不嵌套协调。
- 开始 apply 前取走当前 dirty；执行中产生的新 dirty 留到下一轮，不能末尾全清空。
- 不忽略“接下来 N 个事件”，不全局 skip-own-process，否则会漏 Overlay 的真实状态变化。
- 自己造成的事件重新观察后应得到 NoOp，靠幂等消除反馈。
- 常规变化延续 16ms 节流；关闭/销毁立即唤醒；用户意图下一个安全 UI turn 处理，不额外 sleep。
- worker 一次排空建议最多 64 条消息或 1ms，然后检查 stop/终态/采样截止时间。
  这个预算只限制本次处理，不丢弃终态和未处理系统消息。
- 250ms 补偿只检查与纠正自身状态，不产生新的宿主激活请求。

## 10. WebView 与原生交互表面

本期没有 WebView 实现，不能把 GPUI 文本框通过等同于 WebView2 通过。
当前根窗口和已支持的 IME 仍正常工作；不能要求每个业务控件手工转发 focus。

真正接入 WebView 时，由对应 Adapter 在内部登记其原生子窗口和明确的独立弹出窗口，
带会话代际和生命周期 token；销毁即移除。普通 child ancestry 可核对，独立 popup 必须显式关联。
不把同 PID 的控制窗口、另一个 Overlay 或浏览器辅助进程全部当成同一会话。
不重设外部 owner/parent；浏览器自身已有的合法关系保留。

阶段 0 先用真实原生子窗口验证 WM_MOUSEACTIVATE 传播与首击，记录 root 未收到的情况。
未来 Adapter 若需要观察子窗口交互，使用原生表面已有回调形成相同 intent，
不向业务暴露伪造激活事件的通道，不增加覆盖整个桌面的低级鼠标 hook。
IME 组合、浏览器菜单/文件选择器和新窗口在实际 WebView 集成阶段补充验收。

## 11. 性能、失败与资源约束

这些是实现验收目标，不是此次文档已经测得的结果：

| 项目 | 目标/验证方式 |
|---|---|
| 静止 60 秒 | 非动画场景重复 geometry/order 写入为 0；后台前置请求为 0；允许每秒约 4 次补偿读取 |
| 事件风暴 | 常规采样不超过现有 16ms 频率；单槽有界；不按每条消息新建 Task/timer |
| 无相关变化 | 不为层级检查触发业务 render/通知；按实际差异发布状态 |
| 单次自身协调 | 建议 P95 CPU ≤1ms；超过 4ms 的样本必须记录与分析；这是软预算，不是 OS 硬实时承诺 |
| 正常跟随 | 沿用几何 P95≤50ms、最大≤100ms；层级新增目标相同，计到实际观测收敛，不只计函数返回 |
| 丢事件补偿 | 稳定后≤500ms 收敛；不能作为前台权限补偿 |
| 输入 | 首击业务结果恰好一次，输入/IME 不因额外焦点切换丢失；记录 P95/P99/max 延迟 |
| 宿主挂起 | Overlay/UI 关闭仍响应；请求不堆积；已提交请求可能迟到，结果未知时提示重新附着 |
| 多会话 | 保持一宿主一会话；至少测 1/4 会话，报告总体 CPU 与每会话操作数，不先引入共享全局调度器 |

不在 GPUI 线程同步调用不受控的宿主 SendMessage，不轮询 sleep，不同步 join。
同线程 Win32 调用会产生原生重入；不能把“同步返回很快”的一次实验当无阻塞证明。
查询失败或锚点失效先不应用该计划，有限后续复核；无法确认安全可见性/顺序时可暂时隐藏并报告暂态失败，
不能恢复全局 TOPMOST，也不能假报成功。
正常短暂拒绝通过现有 OperationFailed/error 返回且去重；宿主销毁和不可恢复 binding 失败按现有关闭路径处理。

关闭复用 ADR 0009：失效 intent→隐藏/停输入→解绑→停止 watcher→移除 GPUI window→后台 join。
设计不新增常驻激活 worker。已投递给外部线程的请求无法由这个关闭序列撤回，属于用户已经接受的迟到例外，不能宣称撤销。
诊断只用有上限的内存环形记录：时刻、generation/intent、原生前台/捕获、层级摘要、计划与结果；
不记录窗口标题、账号或页面文本，不在消息回调写磁盘。

## 12. 分阶段实施与验收

### 阶段 0：先验证架构风险，不能跳过

只做受控跨进程原型：宿主、Overlay、第三方遮挡窗口均由 fixture 创建；
宿主支持原生标题栏、自绘标题栏、disabled 模态窗口、消息泵暂停/恢复。

1. 正常后台露出区域点击：宿主+Overlay 前置；首击按钮/输入框恰好一次；输入仍在 Overlay。
2. 点击后立即切第三窗口；延迟到达的 foreground 事件不能复活旧 intent。
3. 暂停宿主 UI 线程，发出真实点击，再切第三窗口/关闭 Overlay，恢复宿主：不追加前置请求、无 UI 卡住；记录允许的迟到效果。
4. 任务栏前置、首次标题栏拖动、边框拉伸、双击最大化/还原、键盘移动/缩放、Esc 取消。
5. 普通/topmost 宿主升降级、其他 topmost、宿主模态/禁用、显示桌面和虚拟桌面。
6. 本窗口原生子控件：捕获、focus、一次点击；验证 GPUI 的实际消息顺序。

真实桌面前提失败必须记录 Abort/Skip，不能计为通过。最小红对照用旧全局 TOPMOST/失焦隐藏行为，
证明测试能区分旧行为。只允许控制 fixture 窗口，不对用户游戏或文件浏览器注入输入。
阶段 0 已确定异步原语、flags 与迟到反例。用户接受该例外并允许无法执行的窗口测试留待人工，
因此继续后续实现；真实输入、桌面与性能未完成项必须保留，不将提交成功当完成。

### 阶段 1：统一被动 presentation

修改 `host.rs` 的 visibility 分类、`watch.rs` 的失效合并、`mod.rs` 的样式/层级执行，
在纯 Module 中实现 NoOp、分组插入、状态优先级。去掉两处无条件 TOPMOST，
但保留匹配 topmost 宿主所需的有条件支持。native_bridge/driver 只消费结果。

### 阶段 2：接入已经验证的用户意图事务

落实代际、revision、首击、取消、模态保护和确认；不重新发明业务激活 Interface。
确定性测试覆盖事件乱序/合并、自己触发的反馈、宿主销毁、锚点失效和结果未知。
宿主消息泵与自己的消息回调分别模拟，不能只用同线程假宿主掩盖风险。

### 阶段 3：Demo 与针对性验收

Demo 自动使用新的跟随语义；提供只读关系状态/错误展示，不增加 bring-to-front 按钮掩盖自动协调问题。
继续用已接受的 margins、四角标记、HUD/Interactive 流程。
保留原几何/DPI/输入/生命周期验收，将“失焦应隐藏”断言替换为“正确自然遮挡且不抢焦点”，
新断言必须通过真实第三窗口的 Z-order、命中与视觉证据证明，不能简单删除旧测试。

未来每个实施阶段按用户指定的 implement 流程执行；只运行与变化有关的专项。
统一 repository/generated 回归仍按用户当前决定延期，不能因此宣称整个 spec 最终门禁已经通过。

## 13. 决策记录与未证明事项

已确定方向：无 owner/parent；复用现有架构；同一个深 Module 管显隐、Z-order、意图；
保留原始输入；宿主非客户区操作优先；不用周期激活实现效果；不扩展当前交付到真正 WebView。

**已解决的范围决定：使用异步宿主层级操作，接受提交后迟到，不增加游戏侧接入。**
“无过期晚到效果”已由用户明确放宽；无周期抢焦点、无重复请求和 UI 响应约束保留。
模态关系、topmost 分组切换、桌面切换及原生子控件也必须通过阶段 0 的对应验证。
跨窗口原子性、独占全屏、特殊游戏反作弊/渲染行为不在本次保证内；普通窗口和无边框窗口仍是目标。

原始设计工作未修改运行时。后续开发与验证结果以进度记录为准；参考 C++ SDK 始终只读，未移植其历史结构。
