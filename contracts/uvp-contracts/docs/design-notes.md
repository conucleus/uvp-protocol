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

### 2.2 new-only 裁决

链轨只支持 order mode new（建单型委托）：routeHash 与 dockInstanceId 的
modeWord 槽位被钉为 new(0)。existing 模式 route 的哈希在重算处直接失配
（显式拒绝，不静默降级）。

### 2.3 keeper 信任模型

链轨 new 模式恰一条 input 绑定且开仓即被消费为出生锚——`submitDockedInput`
因此是纯幂等重放面（恒 return false），不是活的交付/中继路径，**不得列
为 keeper 通道**。`submitDockedSignal` 才是 permissionless 的 output 回写
通道：keeper 只提交可从链上 committed 状态推导的数据，无法自选内容——
payload/idempotency 不接受调用方自报，全部由 committed route/binding +
envelope word 重算。

### 2.4 哈希域公式表

文件头原有的哈希域公式罗列已删除：链轨哈希层的唯一权威规格是
`packages/compiler/docs/dock-word-layout.md`（TS/Rust/Solidity 三线由
`DockManifestParity.t.sol` 逐字节对拍钉死），源码注释里的复制本属于
派生层，不再保留。
