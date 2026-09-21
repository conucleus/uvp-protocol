# 设计笔记（从源码注释迁出的协议考古与攻击推演）

- 迁出日期：2026-09-14（govern/ai-debt 治理批，对应审计 P0-3/P0-5）。
- 性质：源码原位只保留"当前约束一句话"，完整攻击推演、历史裁决叙事与
  历史编号考据归档于此。历史编号（0300 H-1 等）在源码中保留为检索锚
  （比照 risk 规则编号 U001 的处理），本文是其展开。
- 冻结面说明：纯注释改动不改变任何被 fixture 钉住的哈希
  （abiHash/bytecodeHash/deployedBytecodeHash/artifactHash；实测验证于
  本治理批探针，foundry.toml 已钉 `bytecode_hash = "none"`，
  artifactHash 只承诺 ABI/bytecode/事件/选择器/编译器版本，不含源码哈希）。

## 1. 订单号派生与防抢注（0300 H-1）

### 1.1 攻击推演：mempool 抢注受害者的未来单号

订单创建按 `_orders` 先到先得（`OrderAlreadyRegistered`）。若订单 id
允许调用方自报，攻击者可以抢先注册"受害者未来才会派生出的订单号"：

- outside-trigger 出生路径的订单号是公开可预计算的
  （`triggerOrderIdFor`：keccak256(abi.encode(planId, sourceId, signalId,
  payloadHash))，且派生时恒清最高位 dock 命名空间位）。攻击者在
  mempool 里看到受害者的触发交易后，可用派生公式预先算出其订单号并
  抢先建单占位——受害者的事实出生交易反而被 `OrderAlreadyRegistered`
  拒绝。
- 换单号重铸同理：若同一事实可以换一个 orderId 重复建单，"一事一单"
  语义被绕过，链下按订单号索引的全部投影都会重复计数。

### 1.2 防线的当前形态（源码原位约束的展开）

- **签名不背书调用方自选的订单号**：`_TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH`
  的摘要不包含 orderId——订单 id 由合约从事实纯函数派生，签名只对事实
  承诺（一事一单）。
- **派生域结构性隔离**：
  - outside-trigger 派生域 `triggerOrderIdFor`：恒清 dock 命名空间位；
  - order-link 派生域 `orderLinkOrderIdFor`：以独立哈希域
    `keccak256("uvp.order_link.order_id.v1")` 为首 word，且恒清 dock
    命名空间位；
  - dock 子单号恒置最高位（`DOCK_ORDER_NAMESPACE_MASK`）。
  三个命名空间两两分离，跨域占用只能靠 keccak256 碰撞。
- **自报单号只作镜像校验**：order-link 路径请求携带的 orderId 与重算
  派生值不一致即 `InvalidOrderLinkOrderId` revert——与 routeId /
  dockInstanceId 的"重算即拒绝"口径一致。
- **换 orderId 无限重铸与 mempool 抢注在入口处关闭**：重放同一事实恒定
  派生同一 id，按 `OrderAlreadyRegistered` 幂等拒绝。
- **dock 命名空间 fail-closed**：出生订单派生 id 若撞上高位保留命名空间
  （哈希碰撞级事件），按 `InvalidDockOrderNamespace` 拒绝，而不是放行
  让 dock 子单可被抢注。

### 1.3 历史编号考据

"0300 H-1"是设计评审期对该攻击面的编号（高位清零命名空间内抢注受害者
的未来单号）。源码中共出现三处检索锚：
`UVPStateMachine.sol` 的 `InvalidOrderLinkOrderId` 错误声明、
`orderLinkOrderIdFor` 文档、`triggerOrderFromSignalFromModule` 内的
镜像校验注释。

## 2. Dock 出生路径与 keeper 信任模型（UVPDockingModule 文件头迁出）

### 2.1 出生原子性与账本

`openDockedOrder` 在一笔交易内原子完成 child 创建、link 登记、entrance
fact 写入，并同步置位 entrance 交付账本。任何一步失败整笔回滚，不存在
"建了单但 link 未登记"或"事实写入但账本未置位"的中间态窗口。

### 2.2 双模式裁决：new 建单 / existing 挂接

链轨两种 order mode 各有专属入口：new（建单型委托，`openDockedOrder`）
与 existing（对等挂接既有单，`attachDockedOrder`，abiVersion 4.4 起）。
modeWord 进 routeHash 与 dockInstanceId 双 preimage，两侧各自钉死本模式
的 word——new 路由的哈希在 attach 重算处失配，existing 路由的哈希在
open 重算处失配，两模式身份不可互冒（显式拒绝，不静默降级）。

existing 的已裁决语义（唯一权威规格 = uvp-core subscription-mint-spec
§2.4 对等挂接五点；链轨侧落点如下）：

- **同意面**：目标单 creator / 目标单在任执行者（请求自报 targetStageId
  锚定）/ 目标 plan publisher 的 EIP-712 attach 预授权，三者之一。空
  签名只表示不携显式授权，不是放行——三腿全空即拒。成功挂接的重放是
  permissionless 幂等面（return false，先于同意门）。
- **不铸子单**：attach 不触碰 `createDockedOrderFromModule` 与 dock 子单
  namespace，效果集是 O(1) 存储写（与链上存量 dock 数无关）。
- **N:1 拼批**：多父 route instance 可挂同一目标单。幂等键是父侧
  `dockByLocalRoute`（unique(本地订单, 本地阶段)，spec 的 dock_instance
  唯一键同口径）；`dockByTargetOrder` 保持 new 专属（子单出生键），
  目标侧"谁挂了我"的投影由 `DockAttached` 事件（indexed linkedOrderId）
  承载。
- **target:null 动态选择**：未解析路由以候选集 root 占据 routeHash 的
  目标槽（`H(UVP_DOCK_CANDIDATE_V1, routeId, targetDefinitionRefHash,
  interfaceNameId)` 叶），随 dockRoutesRoot 在 finalize 冻结——不扩
  PlanCommit/PlanMetadata ABI。attach 先按静态目标槽重算，失配则按
  候选集根重算并要求选定目标的候选叶 membership proof。选定目标进
  dockInstanceId preimage（existing 第 10 word = 目标单键原字），叠加
  父 route 唯一键即"选定后终身钉住"：同 route instance 换目标即换
  实例 id，`DockEndpointOccupied` 拒绝。链下的退避重试/预算/死信归
  keeper，链上只做确定性验证与幂等。
- **深度账本**：attach 计入 dock 链长——目标单深度取 max(现值,
  父深+1)，长链/环路防护不被挂接绕过。

### 2.3 keeper 信任模型

链轨 new 模式恰一条 input 绑定且开仓即被消费为出生锚——对 new dock，
`submitDockedInput` 是纯幂等重放面（恒 return false）。existing 模式没
有出生锚：input 绑定在 attach 时登记为未交付，逐端口由
`submitDockedInput` 活交付（恰一次 + 幂等重放），就绪门在交付期（父
hook 的 EMIT_READY）。`submitDockedSignal` 两模式同构，是
permissionless 的 output 回写通道：keeper 只提交可从链上 committed
状态推导的数据，无法自选内容——payload/idempotency 不接受调用方自报，
全部由 committed route/binding + envelope word 重算，事实只读
StateMachine 存储。attach 前已成立的目标输出由此自然回填（回填=重放，
逐 output 绑定提交即可）；`DockAttached` 事件不内联已成立输出清单——
目标侧事实的唯一权威是 StateMachine 存储 + 交付账本事件，复制清单进
建立事件会造出第二事实源。

### 2.4 哈希域公式表

文件头原有的哈希域公式罗列已删除：链轨哈希层的唯一权威规格是
`packages/compiler/docs/dock-word-layout.md`（TS/Rust/Solidity 三线由
`DockManifestParity.t.sol` 逐字节对拍钉死），源码注释里的复制本属于
派生层，不再保留。

### 2.5 出生通道词表闸的不对称（有意裁决，勿当 bug 修）

mint 出生（`triggerOrderFromOutsideFor`）要求出生事实在目标 plan 的
能力词表内（成员资格由调用方携 proof 自证）；dock 出生
（`createDockedOrderFromModule`）无词表闸。不对称的理由：词表闸防的是
"调用方自选词表外事实免证落库"，而 dock 出生没有自选面——entrance
事实键取自 committed route 的 input 绑定叶（端口叶/接口承诺钉死），
payload 由模块按 committed 值重算（`_inputPayloadHash`），调用方无从
引入词表外事实，闸无对象可闸。
