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
  payloadHash))）。攻击者在 mempool 里看到受害者的触发交易后，可用派生
  公式预先算出其订单号并抢先建单占位——受害者的事实出生交易反而被
  `OrderAlreadyRegistered` 拒绝。
- 换单号重铸同理：若同一事实可以换一个 orderId 重复建单，"一事一单"
  语义被绕过，链下按订单号索引的全部投影都会重复计数。

### 1.2 防线的当前形态（源码原位约束的展开）

- **签名不背书调用方自选的订单号**：`_TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH`
  的摘要不包含 orderId——订单 id 由合约从事实纯函数派生（一事一单）；
  签名信封另行承诺 `triggerHookId`/`triggerStageId` 的出生线显式选择与
  `authorizationsHash`，调用方不能事后改选出生线。
- **派生域结构性隔离**：
  - outside-trigger 派生域 `triggerOrderIdFor`：
    keccak256(abi.encode(planId, sourceId, signalId, payloadHash))；
  - order-link 派生域 `orderLinkOrderIdFor`：以独立哈希域
    `keccak256("uvp.order_link.order_id.v1")` 为首 word；
  - fork 派生域 `forkOrderIdFor`：以独立哈希域
    `keccak256("uvp.fork.order_id.v1")` 为首 word。
  三个命名空间两两分离，跨域占用只能靠 keccak256 碰撞。
- **自报单号只作镜像校验**：order-link 路径请求携带的 orderId 与重算
  派生值不一致即 `InvalidOrderLinkOrderId` revert。
- **换 orderId 无限重铸与 mempool 抢注在入口处关闭**：重放同一事实恒定
  派生同一 id，按 `OrderAlreadyRegistered` 幂等拒绝。

### 1.3 历史编号考据

"0300 H-1"是设计评审期对该攻击面的编号（抢注受害者未来单号）。源码中
的检索锚：`UVPStateMachine.sol` 的 `InvalidOrderLinkOrderId` 错误声明、
`orderLinkOrderIdFor` 文档、`triggerOrderFromSignalFromModule` 内的镜像
校验注释。
