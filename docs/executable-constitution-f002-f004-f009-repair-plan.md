# F-002、F-004、F-009 可执行修复方案

- 状态：Proposed，等待独立执行 Agent 实施
- 方案 Change ID：`EC-F002-F004-F009-REPAIR-PLAN`
- 当前事实快照：`c15fa9bc88a223a5db2e469ba4c298148b2360bb`
- 实施任务类型：Governance change
- 实施结果上限：`review_required`

本文只处理 F-002、F-004、F-009。它是实施说明，不是修复完成证据。
执行 Agent 必须为真正的代码修复创建新的 Governance ChangeSpec，不得复用本方案的
ChangeSpec。

## 1. 执行边界

### 1.1 目标

修复后必须同时满足以下不变量：

1. Scope 和 Protected-Path 检查使用的任务起点来自 ChangeSpec 之外的任务上下文；
   `ChangeSpec.task_start_revision` 只是需要核对的声明，不再是自己的权威来源。
2. Full/Governance 最终验收时，Runner 自动解析本任务唯一且已提交的 ChangeSpec；
   调用方不能通过指定另一个路径选择更宽松的契约。
3. Authoring 状态可以检查未提交的草稿，但不得产生 Final/通过语义。
4. Scope、Protected Paths 和 ChangeSpec 校验必须消费同一个解析结果和同一个有效任务
   起点。
5. Executable Constitution 的每个命名测试用例拥有独立 Git 仓库、基线和 Spec；用例
   可以单独运行，也可以改变顺序运行。

### 1.2 信任边界

本方案针对正常 Code Agent 流程中的遗漏、恢复、换 Agent 和错误选择，不建设恶意
Candidate 的密码学信任链：

- 任务编排器在任务刚开始、任何仓库修改之前记录 task-start SHA；
- 仓库脚本必须接收并校验这个独立值，禁止从 ChangeSpec 回退推导；
- 本地 Candidate 仍不是 Base-trusted CI。Hosted Trust、Evidence 签名、CODEOWNERS、
  Branch Ruleset 和平台设置不在本次范围。

如果最终验收没有独立的 task-start 输入，脚本必须失败关闭，不能退回使用
`spec.task_start_revision`。

### 1.3 明确排除

- 不修复 F-001、F-003、F-005、F-006、F-007、F-008、F-010；
- 不新增第二套完整质量门，`scripts/check.ps1` 仍是唯一完整仓库质量 Oracle；
- 不实现远端 Trust Stage 或持久化 Evidence Bundle；
- 不修改产品 Crate、Cargo manifest、依赖、工作流或运行时行为；
- 不通过 `git reset`、`git clean` 或共享仓库复位来实现测试隔离。

## 2. 当前实现与问题证据

| 事实 | 当前实现 | 后果 |
|---|---|---|
| ChangeSpec 起点 | `scripts/new-change.ps1:68-72` 在生成时读取当前 `HEAD` | 如果 Agent 已经提交了任务改动才生成 Spec，起点会被推进到改动之后 |
| 起点校验 | `scripts/check-change-spec.ps1:62-65` 只证明 SHA 是一个存在的 commit | 无法证明 SHA 是真正的任务起点 |
| Scope 起点 | `scripts/check-scope.ps1:43-46` 直接使用 `contract.Spec.task_start_revision` | Spec 可以让已经提交的普通越界改动消失 |
| Protected 起点 | `scripts/check-protected-paths.ps1:23-26` 使用同一字段 | 同一个问题也会隐藏受保护路径改动 |
| committed 生命周期 | `scripts/check-change-spec.ps1:51-56` 只检查文件所在目录 | 位于正确目录但未被 Git 跟踪的 Spec 也被当作 committed |
| Spec 选择 | 三个检查均接受调用方提供的 `-ChangeSpecPath` | 多个 Spec 并存时，调用方可以选择其中任意一个 |
| Scope 测试状态 | `scripts/test-executable-constitution.ps1:289-620` 共用 `$scopeRoot` 和 `$scopeSpecPath` | 后续用例观察到前面用例遗留的修改、暂存区和提交 |

## 3. F-002：任务起点可被向前移动

### 3.1 问题是什么

`task_start_revision` 同时扮演“被检查的数据”和“决定检查范围的数据”。当前校验只确认
该 SHA 存在，然后 Scope 与 Protected-Path 检查直接使用它：

```text
ChangeSpec.task_start_revision
             │
             ├──> git diff <该 SHA>...HEAD
             └──> 结果被用于 Scope 与 Protected-Path 判定
```

这形成自我认证：ChangeSpec 声称从哪里开始，检查器就从哪里开始。

### 3.2 正常 Agent 流程中的触发例子

```text
A  任务真正开始
│
B  Agent 提交 scripts/check-scope.ps1 或 other/outside.txt 的修改
│
└─ Agent 此时才运行 new-change.ps1
   new-change.ps1 把 B 写成 task_start_revision
```

随后执行 `git diff B...HEAD` 时，B 中的改动不在差异内。Scope 会报告零路径，
Protected-Path 也看不到该提交。这个过程不需要攻击；Agent 忘记先建 Spec、任务中途升级
Lane、上下文恢复后重新生成 Spec，都会触发。

### 3.3 根因

- task-start 没有独立于 ChangeSpec 的输入来源；
- `check-change-spec.ps1` 没有比较“任务上下文起点”和 Spec 声明；
- 三个检查各自通过 Spec 间接获得起点，没有共享权威解析对象；
- 对 committed Spec 没有验证其首次引入的 Git 历史与任务起点的关系。

### 3.4 目标设计

定义两个不同概念：

- `declared_task_start`：ChangeSpec 中的 `task_start_revision`；
- `effective_task_start`：任务编排器在任何修改前捕获并传给检查器的 SHA。

唯一允许进入 Git 范围计算的是 `effective_task_start`。解析器必须验证：

1. 它是存在的 commit；
2. 它是待验 `HEAD` 的祖先；
3. 它与 `declared_task_start` 完全相等；
4. Full/Governance Spec 的首次引入提交位于该范围内；
5. Final 状态下，该 Spec 的首次引入提交以 task-start 为父提交，即 Spec 是任务的第一个
   已提交切片；后续可以继续修改同一个 Spec，但不得改变其 task-start。

第 5 条把现有“实现前创建并提交 ChangeSpec”的文字流程变成可检查的 Git 事实。

### 3.5 具体实现

#### A. 调整 `new-change.ps1`

- 新增必填 `-TaskStartRevision`；停止在脚本内部把当前 `HEAD` 当作隐式最终权威；
- 验证该 SHA 存在且是当前 `HEAD` 的祖先；
- 将其原样写入 ChangeSpec；
- 调用草稿校验时，也显式传递该独立值；
- `-PassThru` 同时返回 `TaskStartRevision`，便于 Agent 将其保存在任务上下文；
- 不提供“未传则从 Spec/当前 HEAD 猜测”的最终验收回退。

任务入口应变成：

```powershell
$taskStart = (git rev-parse HEAD).Trim()
.\scripts\new-change.ps1 `
  -TaskStartRevision $taskStart `
  <其余现有参数>
```

`$taskStart` 必须在任何编辑之前记录，并在整个任务和换 Agent handoff 中保持不变。

#### B. 建立一个权威解析函数

在 `scripts/lib/ExecutableConstitution.psm1` 中增加单一解析函数，例如
`Resolve-ECChangeContract`。它接收：

```text
RepositoryRoot
TaskStartRevision          # 独立输入，必填
HeadRevision               # 默认 HEAD
ChangeSpecPath             # 仅 transient lane 必填；committed lane 只是可选断言
AllowDraft
```

返回一个不可变结果对象：

```text
Spec
Policy
ChangeSpecPath
EffectiveTaskStartRevision
HeadRevision
Lifecycle                  # authoring 或 final
Outcome
```

`check-change-spec.ps1`、`check-scope.ps1` 和
`check-protected-paths.ps1` 必须调用这个函数。后两者把
`EffectiveTaskStartRevision` 传给 `Get-ECChangedPaths`，不得再读取
`Spec.task_start_revision` 来决定范围。

#### C. Authoring 与 Final

阶段由 Git/Spec 状态决定，不要求 Agent 自己声称：

- Spec 为 draft、未跟踪、仅暂存或有未提交修改时，只能得到 `authoring`；
- Full/Governance Spec 为 ready、已提交且工作副本中的 Spec 与 `HEAD` 一致时，才是
  `final`；
- 未设置 `-AllowDraft` 的验收调用只接受 `final`；
- `authoring` 可以用于早期反馈，但不得输出等价于最终通过的结果。

### 3.6 F-002 自动化验收

在独立 fixture 中增加以下回归用例：

| 用例 | 设置 | 预期 |
|---|---|---|
| retroactive ordinary path | 起点 A；先提交越界普通文件得到 B；Spec 声明 B；Runner 输入 A | ChangeSpec/Scope 拒绝起点不一致 |
| retroactive protected path | 起点 A；先提交受保护脚本得到 B；Spec 声明 B；Runner 输入 A | Scope 与 Protected-Path 均不能产生通过结果 |
| spec edit advances start | Spec 最初声明 A，后续把字段改为 B | 拒绝；有效起点仍为 A |
| legitimate original start | Runner 与 Spec 都为 A，Spec 是首个任务提交 | 通过契约解析并覆盖 A..HEAD |
| unavailable start | Runner 输入不存在的 SHA | 失败关闭 |
| non-ancestor start | Runner 输入另一条历史线上的 commit | 失败关闭 |
| later staged/untracked work | A 后有 committed、staged、unstaged、untracked 修改 | 四类修改都出现在 Scope 结果中 |
| transient mismatch | Focused/Bot 临时 Spec 声明 B，Runner 输入 A | 拒绝，不允许从临时 Spec 回退 |
| amended/multiple Spec commits | Spec 首次引入父提交为 A，之后修改同一文件且起点不变 | 仍解析为同一个 Spec，范围仍从 A 开始 |

## 4. F-004：没有唯一且真正 committed 的权威 ChangeSpec

### 4.1 问题是什么

当前 `committed` 的实际含义只是：文件路径的父目录是 `.agentinfra/changes/`。检查器
不知道文件是否被 Git 跟踪、是否进入 `HEAD`、是否属于当前任务，也不知道同一任务是否
出现两个 Spec。

当前入口还要求调用方指定路径：

```text
Agent 选择 ChangeSpecPath
          │
          └──> 校验所选文件
```

因此“哪个 Spec 是权威的”由调用者决定，而不是由 Git 任务范围决定。

### 4.2 正常 Agent 流程中的触发例子

- 实现 Agent 生成 `EC-A.json` 但没有提交；Repair Agent 看到它位于正确目录，以为已有
  durable contract；换到新工作区后该文件消失。
- 一个任务升级 Lane 或重试生成，留下 `EC-A.json` 与 `EC-B.json`；后续 Agent 把路径
  传成范围更宽的那个，得到与另一个 Agent 不同的结论。
- 历史任务已有许多 Spec；调用方误传旧文件。当前脚本没有证明它属于本任务范围。

### 4.3 根因

- 没有 repository-level resolver；
- “目录正确”被误当成“Git committed”；
- 没有按独立 task-start..HEAD 范围计算 Spec cardinality；
- 低层的单文件解析入口被当成最终验收入口。

### 4.4 权威解析算法

`Resolve-ECChangeContract` 按以下顺序执行，顺序不得由调用方改变：

1. 验证独立 task-start 和 head，并证明 task-start 是 head 的祖先。
2. 收集 task-start..head 的 net diff、逐 commit name-status 历史、暂存区、工作区和
   untracked 状态中所有 `.agentinfra/changes/*.json` 路径；Rename/Copy 的两端都
   计入。不能只看最终 net diff，因为“任务内先 Add、后 Rename”可能在最终差异中只
   表现为一个新增路径。
3. 根据 Git 状态自动区分 committed lane 与 transient lane，而不是先信任调用方路径。
4. 对 Full/Governance Final：
   - 当前任务范围内必须恰好新增一个 ChangeSpec；
   - 不得同时新增、修改、删除、Rename 或 Copy 另一个 ChangeSpec；
   - 文件必须被 `git ls-files` 跟踪；
   - `HEAD:<path>` 必须存在；
   - 该 Spec 自身不得有 staged/unstaged/untracked 差异；
   - 文件名必须等于 `<change_id>.json`；
   - 首次 Add commit 必须唯一可解析，其父提交必须等于有效 task-start；
   - 后续对同一个 Spec 的修改允许存在，但不能改变 change ID 或 task-start。
5. 对 Focused/Bot：
   - 仓库任务范围内不得出现 committed-lifecycle Spec 候选；
   - 必须由任务 Runner 提供一个仓库外的临时 Spec 路径；
   - 该文件 lane 必须是 transient，且声明起点必须等于独立 task-start。
6. 如果 committed lane 仍传入 `-ChangeSpecPath`，它只能作为“必须等于解析结果”的
   断言，不能参与选择。
7. 解析得到唯一 Spec 后，才执行现有 schema、lane/profile、budget 声明和 ADR 字段等
   单文档校验。

低层 JSON/schema 校验可以保留为内部函数，供 fixture 精确测试；它不能继续作为
repository acceptance 的公开捷径。

### 4.5 Authoring 规则

为了不阻碍 Agent 开发，`-AllowDraft` 可以接受一个未提交的候选，但结果必须明确是
`authoring`：

- 可以是一个未跟踪或暂存中的 draft Spec；
- 如果存在两个候选，即使在 Authoring 也拒绝；
- 如果 task-start 之后已经有提交、却没有在第一个任务提交中引入 committed Spec，
  Full/Governance Authoring 拒绝并要求恢复正确任务记录；
- Authoring 结果不能用于最终 handoff、commit Evidence 或 `passed` 状态。

### 4.6 F-004 自动化验收

| 用例 | 预期 |
|---|---|
| Full Spec 仅位于正确目录但 untracked | Final 拒绝 |
| Full Spec 仅 staged、未进入 HEAD | Final 拒绝；`AllowDraft` 只返回 authoring |
| 一个 ready Spec 已提交且干净 | Final 接受并自动返回该路径 |
| 两个 Spec 在任务范围内 | 在任何调用方路径选择前拒绝 cardinality |
| 一个 committed Spec 加一个 untracked Spec | Final 拒绝 |
| 修改历史任务的旧 Spec、没有新增本任务 Spec | 拒绝 wrong-range contract |
| 删除现有 Spec | 拒绝 |
| Rename 或 Copy Spec | 拒绝或明确计为多个端点，不能静默选新路径 |
| 文件名与 `change_id` 不一致 | 拒绝 |
| 调用方路径指向非解析结果 | 拒绝，不能校验被选中的宽松 Spec |
| 同一 Spec 在后续提交中更新 | 接受，前提是首次 Add provenance 和 task-start 不变 |
| Focused/Bot 使用仓库外唯一临时 Spec | 接受 transient 流程 |
| Focused/Bot 同时改动仓库内 ChangeSpec | 拒绝混合生命周期 |

## 5. F-009：Scope 测试共享并累积 Git 状态

### 5.1 问题是什么

Scope suite 只创建一次 `$scopeRoot`。随后每个用例在同一仓库中继续修改文件和暂存区：

```text
modify case
   ↓ 留下 working change
add case
   ↓ 同时看到 modify + add
delete case
   ↓ 同时看到 modify + add + delete
rename/copy/staged/... case
```

例如“allowed added path”没有创建自己的 Spec，而是依赖前一个 modify 用例写入的
`$scopeSpecPath`。后面的 path count 也持续包含前面用例的路径。

### 5.2 会发生什么

- 删除、重排或单独运行 add case 时，它缺少前一个用例创建的 Spec；
- 前一个用例失败但测试 Runner 继续时，遗留状态会让后续用例连锁失败；
- 一个应当只验证 rename 的用例，可能因为此前的允许路径而通过或因为此前的禁止路径而
  失败；
- 回归定位从“一个行为原因”退化为分析整段执行顺序。

这不是产品运行时故障，但会降低治理检查的可信度，Agent 最依赖的绿色测试也可能误导。

### 5.3 目标测试结构

建立按测试家族划分的 fixture factory：

```text
New-ECContractFixture
New-ECScopeFixture
New-ECProtectedFixture
New-ECAdapterFixture
```

每次命名用例执行以下生命周期：

```text
创建 GUID 临时目录
  -> 复制 policy/schema
  -> 初始化独立 Git 仓库和 baseline commit
  -> 创建该用例自己的 Spec
  -> 只制造该用例需要的变化
  -> 执行断言
  -> finally 校验路径位于系统临时目录并删除整个 fixture
```

禁止通过 reset/clean 复用仓库。丢弃整个临时 fixture 比恢复共享 Git 状态更简单、可证明。

### 5.4 具体重构

1. 将 suite 级 `$fixtureRoot`、`$scopeRoot`、`$protectedRoot`、`$adapterRoot` 改为
   case 级 fixture。
2. `New-ChangeSpecFixture` 的 `TaskStartRevision` 改为必填；删除
   `$script:contractTaskStartRevision` 回退。
3. 新增 `Invoke-IsolatedPolicyCase` 包装器，在 `try/finally` 中拥有并销毁 fixture。
4. 每个 Action 通过参数接收 fixture，不读取上一个 case 写入的 script/global 状态。
5. 每个 Scope case 自己写 Spec；不能依赖上一 case 的 `$scopeSpecPath`。
6. 增加集合相等断言，例如 `Assert-ChangedPaths`，验证该用例的精确相关路径，而不是只
   验证累计结果中“包含某个路径”。
7. 为 Runner 增加确定性的筛选/排序入口：
   - `-CaseName <exact-name>`：单独执行一个 case；
   - `-Order declared|reverse`：至少支持声明顺序和反向顺序；
   - 如果实现 shuffle，只能使用显式 `-ShuffleSeed` 并输出 seed，不能引入随机
     flakiness。
8. 保留总 passed/failed 汇总；一个 case 的失败可以继续收集其他结果，但其 fixture 必须
   已经清理，不能污染下一个 case。

### 5.5 F-009 自动化验收

- 单独运行原先依赖前序状态的 `allowed added path passes scope`，必须通过；
- 单独运行 delete、rename、copy、staged/unstaged case，必须各自通过；
- Scope suite 按 declared 和 reverse 顺序运行，case 结果集合必须一致；
- 在一个专用测试 case 中故意抛出异常，下一 case 必须得到全新 baseline；
- 每个 case 的 `Changes.Path` 与期望集合精确相等；
- 测试结束后，本次运行明确创建并记录的每一个 `gpui-contract-*`、`gpui-scope-*`、
  `gpui-protected-*` 或 `gpui-adapters-*` 目录都已清理；不得扫描或删除其他并发任务
  创建的同前缀目录；
- `scripts/test-policy-scripts.ps1` 和完整 `scripts/check.ps1` 继续通过。

## 6. 文件级改动清单

执行 Agent 应先以当前源重新核对路径；预期最小改动如下：

| 文件 | 改动 |
|---|---|
| `.agentinfra/changes/<NEW-REPAIR-ID>.json` | 新的 Governance ChangeSpec；必须是修复任务的第一个提交切片 |
| `scripts/lib/ExecutableConstitution.psm1` | 增加权威契约解析、task-start/ancestor 和 Git provenance 辅助函数 |
| `scripts/new-change.ps1` | 接受独立 task-start；停止让最终流程隐式信任生成时 HEAD |
| `scripts/check-change-spec.ps1` | 从“校验调用方所选文件”改为 repository-level resolve + document validation |
| `scripts/check-scope.ps1` | 使用 resolver 返回的 effective task start 和唯一 Spec |
| `scripts/check-protected-paths.ps1` | 使用同一 resolver 结果，不再独立读取 Spec 起点 |
| `scripts/test-executable-constitution.ps1` | F-002/F-004 回归用例；所有命名 case 独立 fixture；单例/顺序入口 |
| `docs/change-contract.md` | 说明独立 task-start、自动 Spec 解析、Authoring/Final 事实状态和新命令形状 |
| `docs/agent-workflow.md` | 任务开始时捕获并贯穿 task-start；Final 不允许调用方选 committed Spec |
| `.agentinfra/README.md` 或 `.agentinfra/changes/README.md` | 仅在需要时澄清 committed 的 Git 语义；不要复制完整规范 |

通常不需要修改 ChangeSpec schema、Cargo、产品代码、工作流或 `scripts/check.ps1`。
如果实现发现必须扩大范围，先更新实施任务的 ChangeSpec 和计划，不得静默扩张。

## 7. 实施顺序与提交切片

### 7.1 Bootstrap：在修复旧规则之前固定本任务

执行 Agent 必须在任何编辑之前：

1. 确认工作区和 index 干净，记录 `git rev-parse HEAD` 为修复任务起点；
2. 使用当前版本的 `new-change.ps1` 立即生成新的 Governance ChangeSpec；
3. 完成字段、设为 ready，并把它作为第一个本地提交；
4. 在任务上下文中保存原始 task-start，后续不得从 Spec 重新读取来替代；
5. 新实现完成后，用新增的独立 task-start 参数复验本任务本身。

这是一次 bootstrap：当前生成器尚未拥有计划中的新参数，所以必须在起始 HEAD 上立即
生成，不能先做实现提交。

### 7.2 Slice 1：F-002 + F-004 权威契约解析

F-002 和 F-004 必须在同一原子切片中完成，因为只修其中一项会留下绕过路径：

- 先添加预期失败的 provenance、retroactive-start、untracked 和 duplicate fixtures；
- 实现 `Resolve-ECChangeContract`；
- 让 ChangeSpec、Scope、Protected 三个公共检查消费同一解析结果；
- 更新 generator 和两份规范文档；
- 运行 contract/scope/protected suite；
- 形成一个包含行为、测试和文档的提交。

一个合理的 revert reason 是：撤回“任务起点和唯一 Spec 由 Runner/Git 解析”的整个契约。

### 7.3 Slice 2：F-009 fixture 隔离

- 先证明某个后续 Scope case 当前不能独立运行或反向顺序不成立；
- 引入 case-owned fixture factory；
- 迁移所有 contract/scope/protected/adapter cases；
- 增加单 case 与 reverse-order 验证；
- 形成独立测试结构提交。

一个合理的 revert reason 是：撤回“每个治理测试拥有独立 Git 状态”的测试架构。

不得把无关格式化、F-003/F-005 修复或 Trust/Evidence 建设混入两个切片。

## 8. 自动化测试矩阵

| 改变的契约 | 稳定观察面 | 最低测试层 | 预期 Red | Green 证据 |
|---|---|---|---|---|
| task-start 独立性 | public ChangeSpec/Scope/Protected scripts | Policy fixture | Spec 把起点推进到 HEAD 仍通过 | Runner 起点 A 与 Spec 起点 B 不一致时三个入口都不通过 |
| 唯一 committed Spec | repository-level resolver | Policy fixture | untracked/duplicate Spec 被选中并通过 | Final 只接受任务范围内唯一、tracked、committed、clean Spec |
| Spec 首次引入 provenance | Git history resolver | Policy fixture | Spec 可在任务提交之后补建 | Spec 不是首个任务提交时 Final 拒绝 |
| Scope fixture 隔离 | case runner | Policy fixture | 后续 case 依赖前序 Spec/状态 | 单 case、declared、reverse 得到相同结果 |
| 异常清理 | fixture owner/finally | Policy fixture | 失败 case 可能污染下一 case | 故意失败后下一 case 从新 baseline 开始，临时目录被清理 |

产品运行时的取消、窗口关闭、平台降级、通道容量和数据迁移均不适用；本次唯一资源生命周期
是测试临时仓库：case wrapper 创建，case `finally` 清理，路径必须先验证位于系统临时目录。

## 9. 验证命令

命令中的 `$taskStart` 必须来自实施任务开始时记录的独立值：

```powershell
.\scripts\check-policy.ps1
.\scripts\check-change-spec.ps1 -TaskStartRevision $taskStart
.\scripts\check-scope.ps1 -TaskStartRevision $taskStart
.\scripts\check-protected-paths.ps1 -TaskStartRevision $taskStart

.\scripts\test-executable-constitution.ps1 -Suite contract
.\scripts\test-executable-constitution.ps1 -Suite scope -Order declared
.\scripts\test-executable-constitution.ps1 -Suite scope -Order reverse
.\scripts\test-executable-constitution.ps1 -Suite protected
.\scripts\test-executable-constitution.ps1 -Suite adapters
.\scripts\test-policy-scripts.ps1

.\scripts\check.ps1
.\scripts\test-generated-project.ps1
.\scripts\check-commits.ps1 "$taskStart..HEAD"
git log "$taskStart..HEAD" --oneline
git status --short
```

如果实现选择不同但等价的 case 筛选参数，更新文档和命令；不能声称 reverse/individual
通过而没有实际可执行入口。

独立审查应另外重放原审计的 CONTRACT-001、CONTRACT-002、CONTRACT-003，并重新进行
完整审查。Repair Agent 自己运行 Candidate 测试不能代替独立复审。

## 10. 完成判定

只有以下条件全部成立，执行 Agent 才能报告完成：

- F-002 的普通路径和受保护路径 retroactive-start fixtures 均失败关闭；
- Spec 字段不再决定 Scope/Protected 的有效起点；
- F-004 的 untracked、staged-only、duplicate、wrong-range、deleted、renamed 和 caller-
  selected fixtures 均得到预期结果；
- Full/Governance Final 可以从任务范围自动解析唯一 Spec；
- Focused/Bot 仍能使用一个 Runner 提供的仓库外临时 Spec；
- 每个治理 fixture case 可独立运行，declared/reverse 结果一致；
- 直接 suite、policy suite、完整 gate、generated-project gate 和 commit-range 检查都已
  运行并准确记录；
- 实施历史是两个有明确 revert reason 的本地提交切片，工作区状态已说明；
- Governance 结果仍是 `review_required`，没有被绿色自测提升成 trusted/passed。

## 11. 交给执行 Agent 的启动指令

```text
在当前仓库中实施 docs/executable-constitution-f002-f004-f009-repair-plan.md。
范围只限 F-002、F-004、F-009。严格执行仓库 AGENTS.md 和 Governance lane；在任何
实现编辑前记录当前 HEAD，并立即创建一个新的、独立的 Governance ChangeSpec，作为
本修复任务的第一个提交，不能复用 EC-F002-F004-F009-REPAIR-PLAN。

按方案先完成 F-002+F-004 的权威 task-start/唯一 ChangeSpec 解析及回归测试，再以独立
提交完成 F-009 的逐 case Git fixture 隔离。不得顺带修复其他 Finding 或建设 hosted
Trust/Evidence。运行方案第 9 节全部适用命令，按 Quality/History/Worktree 交付；不要
push、merge 或发布。完成后仍保持 Governance 的 review_required，并等待独立复审。
```
