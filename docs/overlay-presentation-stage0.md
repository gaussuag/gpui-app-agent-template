# Host presentation：阶段 0 验证记录

日期：2026-09-22。开发基线：`492fb18`。
依据：[技术方案](overlay-host-presentation-design.md) 第 8、12 节。

## 当前结论

**裸 `SWP_ASYNCWINDOWPOS` 候选不通过“过期请求不得生效”的要求。**
已实现独立跨进程原语验证工具并运行对照实验；尚未实现生产 HostPresentation，
没有更改当前 Demo 的失焦隐藏、TOPMOST、输入、geometry、margins 或生命周期行为。
阶段 0 整体未通过，阶段 1–3 未启动。

这不是锁屏或没有人工输入造成的结果。本实验不要求前台、不发送鼠标键盘输入；
只操作本次创建的原生测试窗口。它证明原语的延迟执行风险，不证明实际用户首击或 GPUI 行为。
本次未判定桌面是否锁定，不能据此声明真实桌面测试已通过或因锁屏失败。

## 可重复运行

```powershell
cargo run --locked -p overlay-win32 --features test-support --example presentation-probe --target x86_64-pc-windows-msvc
```

工具由 `test-support` 限定。创建一个独立宿主子进程和控制进程自己的 Overlay 替身、
遮挡窗、第三窗口；不使用原生 owner/parent，不使用生产 binding，也不注入用户进程。
宿主在自己线程通过阻塞读 stdin 暂停消息泵，以握手确认 HWND；恢复命令才重新泵消息。
控制进程核对 HWND 的进程身份，每次实验结束或报错均终止并回收自己的子进程和读取线程。
协议等待最多 5 秒；层级遍历最多 512 个窗口。窗口均不激活，不读取其他窗口标题。

实验步骤：

1. 初始测试窗口顺序为 Overlay 替身 > 遮挡窗 > 宿主，宿主消息泵暂停。
2. 实验组提交 `SetWindowPos(host, overlay, ... ASYNCWINDOWPOS | NOACTIVATE | NOMOVE | NOSIZE | NOOWNERZORDER)`；对照组不提交。
3. 创建第三窗口置于上述组合前面，模拟提交后的视觉上下文改变，并将本地意图视为过期。
4. 此时再次确认宿主仍在遮挡窗后面。
5. 恢复宿主消息泵，观察实际层级是否改变。

第 3 步**不是实际用户切换前台**；没有调用 SetForegroundWindow，没有测试 WM_MOUSEACTIVATE、
首击、捕获或焦点。当地意图是否被清空不能影响已投递的系统请求，是本实验检验的原语边界。

## 本次实测输出

```text
INTENT_EXPIRED_WHILE_HOST_PAUSED submit=false
AFTER_RESUME submit=false host_crossed_occluder=false third_above_pair=true
ASYNC_SUBMIT_US=12
INTENT_EXPIRED_WHILE_HOST_PAUSED submit=true
AFTER_RESUME submit=true host_crossed_occluder=true third_above_pair=true
PRESENTATION_CANDIDATE_REJECTED: queued host reorder executed after intent expiry
```

对照组宿主没有跨越遮挡窗；实验组恢复后跨越了遮挡窗。第三窗口仍在组合上面，
**没有观测或声称“抢走第三窗口焦点”**。12 微秒仅为一次提交调用耗时，不是性能验收结果。

退出码 0 仅表示实验采集完成，绝不表示候选或阶段 0 通过；必须读取候选状态标记。
若未观察到迟到，输出 `PRESENTATION_CANDIDATE_UNPROVEN`，同样不通过架构门槛。
初始条件不成立、握手超时、系统调用错误等返回非零，不算通过。

[SetWindowPos 官方契约](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos)
说明 ASYNCWINDOWPOS 在不同输入队列时投递给目标线程；未提供取消句柄。
实测与契约一致。本地 generation、超时或 worker 隔离不能撤销已提交的操作。
不能因同步 API 没有本地队列就认定其不阻塞；本次不引入一个可能等待外部线程的同步生产调用。

## 下一步所需决定

当前被否定的是上述具体候选，并非已经证明所有可能的 Win32 组合均不可行。
按已批准方案，不能将该候选直接接入生产，也不能把失败标记为“等待人工确认”。
已向用户提出两条明确路径，等待选择：

- 保留过期效果约束：转向方案 C，由宿主线程在执行前核对有效性，增加游戏侧接入；仍需设计和验证协议，不能宣称已经解决。
- 保留任意外部 HWND 接入：明确接受已提交的操作可能迟到生效，再修订对应验收；不隐式放宽要求，不加入周期抢焦点。

## 验证与待人工项

- Windows x64 示例编译、运行成功；得到上述候选拒绝证据。
- `overlay-win32` 全目标、test-support 严格 Clippy 通过。
- `overlay-win32` 的 3 项单元测试通过；这些没有证明新的完整 presentation 行为。
- 文档链接和 staged diff 检查、双轴审查结果在交付时记录。
- 统一 repository/generated 回归继续按用户先前要求延期。

待后续实现/真实桌面验收：后台露出区域首击与输入保持、真实前台切换、GPUI 捕获/IME、
任务栏、标题栏拖动/双击、边框/键盘缩放、模态窗、topmost 分组、显示桌面/虚拟桌面、
原生子控件以及多会话性能。**当前没有交付可用于这些新行为验收的 Demo。**
