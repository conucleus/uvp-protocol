# 合约边界审查记录（意见书 B1）

- 审查日期：2026-09-14
- 审查基线：`uvp-protocol` 仓 `govern/ai-debt` 分支，`contracts/uvp-contracts/src` @ 当前 HEAD（UVPStateMachine.sol 2,190 行）。
- 审查依据：《UVP 代码库结构治理与 AI 增生债务整改技术意见书》B1 工作包——「合约已有可用的物理模块边界，保留当前文件布局，重点调整具体职责归属。源码路径移动不会自动缩小部署后的核心字节码；能否外置取决于存储、调用上下文与链接方式。每项迁移必须给出授权、事件、布局及编译产物验证。」
- 审查方法：逐文件通读 `UVPStateMachine.sol`、`UVPStateMachineConstants.sol`、`UVPPlanRegistration.sol`、`UVPPlanMetadataModule.sol`、`UVPDockingModule.sol`、`UVPOrderLinkModule.sol`、`UVPStagePatchModule.sol`、`UVPDerivedSignalModule.sol`、`UVPStateMachineLens.sol` 及 `interfaces/`、`libraries/`，按「授权、事件发出方、存储访问、delegatecall 上下文、原子性」五个维度逐项判定。

## 总结论

**全部维持现有文件布局与职责归属，本轮不执行任何合约代码迁移。**

理由：

1. 意见书 B1 明确「已有合理边界无需为行数而再拆」。当前 8+1 个物理单元的切分已经按「核心状态机 / 计划注册库 / 元数据模块 / 对接模块 / 订单链接模块 / 补丁模块 / 派生信号模块 / 只读透镜」正交切分，模块间通信面全部收敛为显式接口（`IUVPStateMachineCore` / `IUVPPlanMetadataModule`），无隐性耦合。
2. 唯一一次已完成的职责外置（`commitPlan`/`finalizePlan` 主体外置 `UVPPlanRegistration` 链接库，DELEGATECALL 语义）已经实现且逐字节保持了事件 emitter、EIP-712 域与签名口径——文件头注释对此有明确约束（「禁止将任何调用目标改为可变地址」）。
3. 本轮不具备冻结产物变化的验证窗口：任何源码级迁移（即使 ABI 不变）都会改变 bytecode hash，需要跨语言冻结向量（TS/Rust/合约三方）与部署侧 fixture 的可复核解释窗口，本轮指令明确「任何会改变 bytecode 的迁移本轮不做」。
4. 审查中识别的三项「可选后续治理项」（见文末）均属跨合约公共代码收敛或双存储合并，全部触及多个已冻结合约的 bytecode，留待专门的冻结窗口评估。

## 逐项审查

### 1. UVPStateMachine.sol（核心，2,190 行）

#### 1.1 模块治理面（owner / setXxxModule / freezeModules / moduleSetHash）

- **决定：保留在核心。**
- 授权：`onlyOwner`；`freezeModules` 要求六个模块地址全部就位后一次性冻结，`modulesFrozen` 同时是 `commitPlan` 的前置（`UVPPlanRegistration.commitPlan` 首行检查）。
- 存储访问：六个模块地址 + `modulesFrozen` 是核心自身 `FromModule` 入口 `msg.sender` 闸的判定数据，属于「授权数据的授权数据」，外置即自举矛盾。
- 事件发出方：`StateMachineModuleSet` / `StateMachineModulesFrozen`（携带 moduleSetHash）由核心发出，是索引器钉模块拓扑的唯一事件源。
- 备注：`moduleSetHash` 将 lens 一并纳入冻结集合——lens 地址变化即拓扑变化，口径自洽。

#### 1.2 计划注册入口（commitPlan / finalizePlan 薄包装）

- **决定：维持现状（主体已外置 `UVPPlanRegistration`，核心只留签名兼容包装）。**
- delegatecall 上下文：库函数以 `_plans` storage 引用传参执行，状态写核心存储、`address(this)` 仍是核心（库内 `DOMAIN_SEPARATOR()` 用 `address(this)` 取核心域分隔符，EIP-712 口径与外置前逐字节一致）。
- 事件发出方：`PlanCommitted`/`PlanFinalized`/`PlanRegistered`/`PlanPublisherRecorded` 在库内 emit，经 DELEGATECALL 表面为核心地址——索引器无感。
- 原子性：`finalizePlan` 库内 CEI（`finalized` 先于 `planMetadataModule.finalizePlanMetadata` 外调落定），重入按 `PlanAlreadyFinalized` 拒绝。该顺序约束依赖「写标志 + 外调」同址，拆散即破坏。
- 进一步外置包装本身只会增加 indirection 而不减少核心 bytecode（`external` 薄包装经优化器已是最小 dispatch）。

#### 1.3 计划/订单/信号/授权存储与读视图

- **决定：保留在核心。**
- 存储访问：`_plans` / `_orders` / `_signals` / `_signalAuthorizations` / `_delegatedStageSignalAuthorizations` / `sourceSignalCount` / `lastSignalSubmitter` / `_activeStageExecutorPatches` 全部为 core 私有 storage；所有写路径（含模块代写）收敛于核心入口，读视图（`getSignal`/`getHookStatus`/`isSignalSubmitterAuthorized` 等）直接读私有 storage。任何外置都需要把私有 storage 改为跨合约 getter + 写入口，扩大攻击面且改变全部相关 bytecode。
- 授权：信号写路径的授权判定（显式授权 → 委托授权 → active executor overlay 三层）与存储同址是 fail-closed 的前提；`hasTriggerOriginConsent`（origin 同意集合：创建者 / origin 源阶段在任执行者 / 事实授权提交者）同样必须直读三张私有表。

#### 1.4 订单出生入口（triggerOrderFromOutsideFor / triggerOrderFromSignalFromModule / createDockedOrderFromModule）

- **决定：保留在核心。**
- 授权：outside 出生 = submitter EIP-712（核心域）+ capability 词表闸；order-link 出生 = `msg.sender == orderLinkModule` 闸 + origin 同意门（核心权威）+ 派生单号不自报（`orderLinkOrderIdFor` 重算比对）；dock 出生 = `msg.sender == dockingModule` 闸。
- 原子性：三条出生路径都是「建单 + 出生事实写入 + trigger hook 就绪断言/置位」同笔事务（`_createOutsideTriggerOrder` 末尾 `_requireTriggerHookReady` 失败即整笔回滚）。该原子性是「出生事实只应铸唯一订单」语义（文法 §7.2）的链上强制，任何跨合约拆分都会引入中间态窗口。
- 事件发出方：`OrderTriggered`/`OrderRegistered`/`OrderRelayerRecorded`/`SignalSubmitted` 均由核心发出；`OrderLinked`（链接事实）由 OrderLink 模块发出——同一事务、两个事件面，各自携带自身域的完整复合身份，无重复叙事。
- 订单号派生公式（`triggerOrderIdFor` / `orderLinkOrderIdFor` / `DOCK_ORDER_NAMESPACE_MASK`）：public pure 挂核心是 BFF/indexer/bootstrap 的镜像锚点，ABI 冻结；迁入库会变更核心 ABI。

#### 1.5 求值栈机（_evaluateInstructions / _andValue / _orValue / _notValue / _delayValue / _signalValue）

- **决定：保留在核心（记录为可选后续项，见 §10.1）。**
- 存储访问：`_signalValue` 直读 `_signals`，锚点语义（OR 取最早到达、DELAY 链式锚推进）与 core evaluator / replay oracle 三线冻结一致。
- 理由：这是每次信号提交的热路径，内联避免逐 hook 的 delegatecall gas 开销；迁库改变核心 bytecode 且需重放全部 golden fixtures 的 gas/trace 断言——无验证窗口不做。

#### 1.6 FromModule 代写入口（activateStageExecutorFromModule / delegateStageExecutorSignalFromModule / submitSignalFromModule / submitDerivedSignalFromModule / recordDockedInputFromModule / createDockedOrderFromModule / triggerOrderFromSignalFromModule）

- **决定：保留在核心。**
- 授权：每个入口首行 `msg.sender != <module>` 即 `UnauthorizedStateMachineModule`——闸数据（§1.1 的模块地址存储）与闸检查同址。
- 语义分层自洽：模块负责自身域的 EIP-712/词表校验，核心负责跨域不变量（订单存在、plan finalized、零字键拒绝、nonce 单调、capability 词表闸、物化门）。双层校验是显式防御纵深（如 `_validateDerivedSignal`（模块）与 `submitDerivedSignalFromModule`（核心）的两维度授权镜像），不是重复债务。

#### 1.7 EIP-712/编码微助手（_recoverSignalSubmitter / _writeWord / _writeAddress / 各 digest 构造）

- **决定：维持现状（记录为可选后续项，见 §10.2）。**
- 现状：`ECDSA` / `UVPSignatures` 已是共享库；但 `_recoverSignalSubmitter` + `_writeWord/_writeAddress` 三件套在 5 个合约内各有一份（核心 / OrderLink / StagePatch / Docking(permit) / DerivedSignal），digest 结构各不相同、`DOMAIN_SEPARATOR` 各绑自身 `address(this)`。
- 理由：收敛进共享库会同时改变 5 个已冻结合约的 bytecode 与各域签名验证路径；本轮不做。

### 2. UVPStateMachineConstants.sol（24 行，文件级常量）

- **决定：维持现状。**
- 是主合约与 `UVPPlanRegistration` 库的编译期常量单一声明点（Solidity 0.8.24 library 不能继承，文件级常量是标准解法）；主合约以 `public constant` 重导出 hook 标志与上限，保持拆分前 ABI getter 签名。无 storage、无运行时成本。

### 3. UVPPlanRegistration.sol（451 行，链接库）

- **决定：维持现状。**
- 职责单一：计划生命周期（commit/finalize）及全部注册边界校验（`_validateHook` 栈机、跨阶段依赖闸、阶段物化防御、依赖键上限）。
- 事件发出方：库内 emit 的计划事件经 DELEGATECALL 表现为核心地址（见 §1.2）。
- delegatecall 上下文：`_plans` 以 storage 引用传入，库不持有任何自身 storage；`address(this)` 语义（域分隔/事件）已在文件头注释钉死。
- 拆分建议评估过并否决：把 `_validateHook` 再拆成独立「校验库」只会把字节从本库挪到另一个库，不缩小核心部署体积（核心经链接库引用两者），反而增加一个链接地址的审查面。

### 4. UVPPlanMetadataModule.sol（309 行）

- **决定：维持现状。**
- 职责：selector bindings / signal capabilities 的注册与读面、E16 属主索引（`_currentOrderFactStages`）、plan dock roots 的承诺验证（`verifyDockRoute` / `verifyDockInterfacePort`）。
- 授权：唯一写入口 `finalizePlanMetadata` 限 `msg.sender == stateMachine`（经核心 finalizePlan DELEGATECALL 链调用）；其余全为只读。
- 存储访问：模块私有存储；核心经 `currentOrderFactStage` / `planSignalCapabilityCount` / `isSelectorTargetStage` 三个窄接口消费，E16 单键索引取代逐项扫描（注释明确记录该优化口径）。
- 事件发出方：`StageSelectorBindingRegistered` / `SignalCapabilityRegistered` 由模块发出，索引器据此建立元数据投影；核心的 `PlanFinalized` 表达生命周期终态，两者不重叠。
- dock roots 验证放本模块（而非 DockingModule）正确：roots 是 plan 元数据承诺，归属 plan 元数据面；DockingModule 作为消费方经接口验证 membership。

### 5. UVPDockingModule.sol（1,170 行）

- **决定：维持现状。**
- 职责：`openDockedOrder`（12 步验证链 + 原子开仓）、`submitDockedInput`（幂等重放面）、`submitDockedSignal`（permissionless output 回写通道）、entrance permit、交付账本与 dock 实例存储、哈希域常量族（与 Rust/TS 逐字节一致，compatibility manifest 冻结）。
- 授权：open 默认 permissionless，可选目标 plan publisher 的 entrance permit（模块自身 EIP-712 域，nonce 从 1 递增）；对核心的写入全部经 `msg.sender == dockingModule` 闸。
- 事件发出方：`DockOpened` / `DockInputSubmitted` / `DockOutputSubmitted` / `DockOutputSatisfied` 全部由模块发出；entrance 事实的 `SignalSubmitted`（核心域事件）由核心 `createDockedOrderFromModule` 路径发出——模块事件承载 dock 通道叙事，核心事件承载状态机事实叙事，互补不重复。
- 原子性：open 的「子单创建 + entrance 事实 + entrance hook Ready + 交付账本置位」一笔完成，任一步 revert 全回滚；兄弟 output 绑定等价交付的 `DockOutputSatisfied` 收敛路径（先落账本再发事件）有专门注释钉死口径。
- keeper 内容不可自选：payload/idempotency 全部由 committed route/binding + envelope word 重算。
- 拆分建议评估过并否决：open/submit/permit 再拆子库对本模块部署体积无 EIP-170 压力（独立合约），只增加链接面。

### 6. UVPOrderLinkModule.sol（244 行）

- **决定：维持现状。**
- 职责：trigger-origin 链接登记（`(planId, triggeredOrderId)` 寻址）+ 派生单触发 + 关系判定读面。
- 授权：submitter EIP-712（模块自身域，origin 复合身份入签名域）；origin 侧同意的**权威校验刻意留在核心** `triggerOrderFromSignalFromModule`（模块注释明确「整笔事务原子回滚，这里无需重复」）——授权判定的存储（订单创建者/在任执行者/事实授权）全在核心，归属正确。
- 原子性：链接记录先写、后调核心派生、再发 `OrderLinked`——核心 revert 时链接记录一并回滚，无悬空链接。
- 存储访问：模块自有 `_orderTriggerLinks`；`targetOrderRelation` 是 derived 模块与链下共同消费的关系判定权威。

### 7. UVPStagePatchModule.sol（814 行）

- **决定：维持现状。**
- 职责：executor patch（assign/handoff/replacement 三模式）与 resource patch 的申请、EIP-712 签名、selector 权与模式校验、nonce 单调、patch 存储；经核心 `activateStageExecutorFromModule` / `delegateStageExecutorSignalFromModule` 落 active overlay。
- 授权：selector = 显式 `EXECUTOR_PATCH_SIGNAL_ID` 授权或订单 creator；HANDOFF 需上一执行者会签；出生阶段（挂 mint/dock trigger hook）禁 executor patch（读核心 `stageHasOrderTriggerHook` 补门，与云侧「出生阶段执行者终生不可变」同口径）；资源补丁不受出生门（资源可替换已裁决）。
- 存储访问：模块持 patch 记录（含 mode/previousExecutor/approval 等 provenance 字段），核心持 active overlay（executor/role/nonce/URI，被信号写路径的执行者门消费）。**双存储是显式分层**：模块是「补丁档案 + 前置单调门」，核心是「运行时权威 + 兜底单调门」（核心入口二次校验 nonce）。合并两存储会改变两个合约的 bytecode 且迫使核心保存其从不读取的 provenance 字段（核心膨胀），本轮不做（记录为可选后续项，见 §10.3）。
- 事件发出方：`StageExecutorPatchApplied`（含 mode/previousExecutor 全 provenance，assembly 手写编码绕过栈深限制）由模块发出；`StageExecutorActivated`（active overlay 投影）由核心发出。两事件同一事务、两个投影面，消费方（投影/审计）各取所需，非重复。
- 同秒平局 fail-closed（`StagePreviousExecutorAmbiguous`）与 fallback/capability 双流计数口径有专门注释，属模块核心语义，不可外移。

### 8. UVPDerivedSignalModule.sol（266 行）

- **决定：维持现状。**
- 职责：派生信号的双端复合身份校验、capability 词表（跨订单时双侧 plan 都须声明）、提交者资格（from 侧在任执行者，或 target 侧显式授权）、经核心 `submitDerivedSignalFromModule` 写入。
- 授权分层：模块管「谁有资格声明派生关系」（capability + 提交者门），核心管「写入不变量」（零字键、显式授权豁免与普通提交路径同口径、relation 判定镜像）。`relation` 判定复用 OrderLink 模块的 `targetOrderRelation`（经核心 `orderLinkModule()` 目录解析），无复制实现。
- 事件发出方：`DerivedSignalSubmitted`（携带两端 planId）由模块发出；核心侧 `SignalSubmitted` 表达事实落账——同事务双面，与 §5/§6 同口径。

### 9. UVPStateMachineLens.sol（281 行）

- **决定：维持现状。**
- 职责：纯读聚合透镜——消费方经单一地址获得跨模块读面，无需自行解析模块目录。
- 存储访问：零存储；全部转发到各模块既有 view。本地窄接口（`IUVPStagePatchModuleLens` 等）是对所需读面的最小声明，避免与模块接口文件硬耦合——结构性重复但零运行时成本，是刻意的隔离手法。
- 授权：无写面，无授权面；lens 地址纳入 `moduleSetHash` 冻结（换 lens = 拓扑变化，可审计）。

### 10. interfaces/ 与 libraries/（IUVPStateMachineCore / IUVPPlanMetadataModule / DockMerkle / ECDSA / UVPSignatures）

- **决定：维持现状。**
- 接口文件即跨合约契约单一出处；`DockMerkle` / `ECDSA` / `UVPSignatures` 为 internal library 链接进各消费合约，无独立部署面。
- UVPIdentityRegistry / UVPDeploymentRegistry 是独立部署基础设施，不在 StateMachine 模块集合（`moduleSetHash` 不含它们），与 B1「状态机边界」正交，本轮不审查其内部职责。

## 可选后续治理项（本轮不做，需专门冻结窗口）

1. **求值栈机外置评估**（§1.5）：`_evaluateInstructions` 及五值代数可迁库缩核心 bytecode，代价是热路径 delegatecall gas 与全量 golden replay 重录。
2. **EIP-712 微助手收敛**（§1.7）：`_recoverSignalSubmitter`/`_writeWord`/`_writeAddress` 三件套 5 处重复可收敛为共享 internal library，一次改动触 5 个合约 bytecode。
3. **StagePatch 双存储合并评估**（§7）：模块 patch 档案与核心 active overlay 的合并可消除一套 nonce 单调门，但需重设计 provenance 读取面。

三项均需：ABI/bytecode diff 报告、跨语言冻结向量再生成（`pnpm verify:protocol-freeze`）、部署侧 fixture 重钉，缺一不可。
