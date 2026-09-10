# Zhixu Dock v2 word 布局规格（链轨内部，冻结）

链轨哈希层的唯一权威规格。全部公式冻结于 `UVPDockingModule` abiVersion 4.0，
实现 = 本包 `src/dock.ts`（TS 权威），Solidity（`DockMerkle` /
`UVPDockingModule`）与 Foundry `DockManifestParity.t.sol` 逐字节对拍钉死。
golden 向量由 `pnpm --filter @uvp-eth/compiler generate:dock-fixtures` 生成
（`fixtures/dock/v1/manifest.json`），任何一侧分叉都在对拍测试暴露。

## 1. 通用规则

- **word** = 32 字节；hex 形态小写 `0x` + 64 hex。
- 所有 commitment = `keccak256(keccak256(domain) ‖ w1 ‖ … ‖ wn)`，等价于
  Solidity `keccak256(abi.encode(keccak256(domain), …))`。全部字段 word
  化，禁 `encodePacked`、禁动态类型。
- **Merkle**：叶子排序去重（字节升序）后逐层
  `keccak256(min(a,b) ‖ max(a,b))`；奇数尾叶直接提升（不与自身合并）；
  空集合 root = `keccak256("")` =
  `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`。
- **字符串 word**：一律 `keccak256(utf8(s))`（uid、接口名、端口名、hook
  引用、canonical signal、order 引用同规则）。
- **整数 word**：uint256 大端左补零。u8 word 只有末字节非零。
- **地址 word**：左补 12 字节零，hex 小写。
- **canonical JSON 域**（`uvp:` 前缀族）：
  `keccak256(domain + ":" + canonical_json)`，canonical JSON 键按码点排序
  （= Rust BTreeMap 字节序）、无空白。数字词表封闭为整数：一切浮点形态
  （分数、整值浮点、指数写法）与负零 `-0` 三线一致响亮拒绝（Rust 权威
  按 f64 载荷拒绝，TS 同口径见 `canonical.ts`）；整数按十进制整型输出，
  超出 JS 安全整数范围（|x| > 2^53-1）的整值在 TS 线无法精确表示、一律
  响亮拒绝（大整数载荷必须以 string/hex word 携带，不得走 canonical JSON
  数字面量）。

## 2. 冻结域串（keccak 的第一 word 输入）

| 常量 | 值 |
| --- | --- |
| DEFINITION_UID_DOMAIN | `uvp:definition-uid:v1` |
| DOMAIN_DEFINITION_REF | `UVP_DEFINITION_REF_V1` |
| DOMAIN_INTERFACE | `UVP_DOCK_INTERFACE_V2` |
| DOMAIN_INTERFACE_INPUT | `UVP_DOCK_INTERFACE_INPUT_V2` |
| DOMAIN_INTERFACE_OUTPUT | `UVP_DOCK_INTERFACE_OUTPUT_V2` |
| DOMAIN_ROUTE_ID | `UVP_DOCK_ROUTE_ID_V1` |
| DOMAIN_INPUT_BINDING | `UVP_DOCK_INPUT_BINDING_V2` |
| DOMAIN_OUTPUT_BINDING | `UVP_DOCK_OUTPUT_BINDING_V2` |
| DOMAIN_ROUTE | `UVP_DOCK_ROUTE_V2` |
| DOMAIN_DOCK_INSTANCE | `UVP_DOCK_INSTANCE_V2` |
| DOMAIN_DOCK_ORDER | `UVP_DOCK_ORDER_V1` |
| DOMAIN_RUNTIME_EIP155 | `UVP_RUNTIME_EIP155_V1` |
| DOMAIN_RUNTIME_CLOUD | `UVP_RUNTIME_CLOUD_V1` |
| DOMAIN_INPUT_PAYLOAD | `UVP_DOCK_INPUT_PAYLOAD_V1` |
| DOMAIN_INPUT_IDEMPOTENCY | `UVP_DOCK_INPUT_IDEMPOTENCY_V1` |
| DOMAIN_OUTPUT_IDEMPOTENCY | `UVP_DOCK_OUTPUT_IDEMPOTENCY_V1` |
| DOMAIN_SOURCE_FACT_SET | `UVP_DOCK_SOURCE_FACT_SET_V1` |
| HOOK_PLAN_ID_DOMAIN | `uvp:hook-plan-id:v1`（canonical JSON 域） |
| HOOK_PLAN_HASH_DOMAIN | `uvp:hook-plan-artifact:v1`（canonical JSON 域） |

闭集常量：order mode `new`/`existing`；`MAX_DOCK_INPUTS=8`、
`MAX_DOCK_OUTPUTS=16`、`MAX_DOCK_DEPTH=8`、`MAX_PORT_NAME_BYTES=32`
（端口名与接口名同规则 `^[a-z][a-z0-9_]{0,31}$`）。

## 3. 枚举 word

- route modeWord：`new=0`、`existing=1`（u8 word）。
- 接口 orderModesWord：u8 位掩码，bit0=new（1）、bit1=existing（2）；
  空集/未知取值/重复项非法（响亮拒绝，不落零 word）。
- linkedOrderId 最高位（`1 << 255`）是 dock 派生子单 namespace 标记；
  普通 MINT/trigger-order 路径必须拒绝该 namespace。

## 4. 身份与承诺 preimage（逐 word 顺序）

以下 `H(D; …)` 表示 §1 的 commitment 形态。

### 4.1 定义身份（canonical 域）

```
digest = keccak256("uvp:definition-uid:v1:" + canonical_json(定义剔除 metadata.annotations))
uid    = "zx-" + digest_hex[0..32]
definitionRefHash = H("UVP_DEFINITION_REF_V1"; keccak(uid))
```

### 4.2 接口承诺（目标侧）

```
inputPortLeaf_v2  = H(UVP_DOCK_INTERFACE_INPUT_V2;  keccak(uid), keccak(interfaceName),
                      keccak(portName), keccak(hookRef))
outputPortLeaf_v2 = H(UVP_DOCK_INTERFACE_OUTPUT_V2; keccak(uid), keccak(interfaceName),
                      keccak(portName), keccak(canonicalSignal))
inputsRoot/outputsRoot = merkle(leaf…)
interfaceLeaf_v2  = H(UVP_DOCK_INTERFACE_V2; keccak(uid), keccak(interfaceName),
                      orderModesWord, inputsRoot, outputsRoot)
dockInterfaceRoot = merkle(interfaces[].interfaceLeaf)
```

`hookRef` = `<task>.<stage>#<receiveHookName>` 原文；`canonicalSignal` =
`<source>::<task>.<stage>.<signal>` 原文。sourceId（`keccak(source)`）/
signalId（`keccak(task.stage.signal)`）是运行期寻址数据，随产物携带但不入叶。

### 4.3 route 承诺（调用方侧）

```
routeId = H(UVP_DOCK_ROUTE_ID_V1; localDefinitionRefHash, stageKey)
stageKey = keccak(stageIdentifier)

inputBindingHash_v2 = H(UVP_DOCK_INPUT_BINDING_V2; routeId, keccak(interfaceName),
                        keccak("<task>.<stage>#<channel>"), keccak(portName),
                        targetSourceId, targetSignalId)
outputBindingHash_v2 = H(UVP_DOCK_OUTPUT_BINDING_V2; routeId, keccak(interfaceName),
                        localSourceId, localSignalId, keccak(portName),
                        targetSourceId, targetSignalId)
localSourceId = keccak(localStage.source)
localSignalId = keccak("<stageIdentifier>.<localSignalName>")

inputBindingsRoot/outputBindingsRoot = merkle(bindingHash…)   // 绑定按哈希字节序
routeHash_v2 = H(UVP_DOCK_ROUTE_V2; localDefinitionRefHash, targetDefinitionRefHash,
                keccak(interfaceName), modeWord,
                inputBindingsRoot, outputBindingsRoot)        // 6 word
dockRoutesRoot = merkle(routes[].routeHash)
```

目标运行期身份（artifactHash/evmPlanId/cloudArtifactId）由 resolution
manifest（链轨发布面）携带，不进 routeHash preimage。

### 4.4 运行时域与实例身份

```
evmRuntimeDomain  = H(UVP_RUNTIME_EIP155_V1; u256(chainId), addressWord(stateMachine))
cloudRuntimeDomain = H(UVP_RUNTIME_CLOUD_V1; keccak(deploymentId), keccak(securityDomain))
localOrderKey = keccak(orderId)
targetOrderRefKey = keccak(orderRef)

dockInstanceId_v2 = H(UVP_DOCK_INSTANCE_V2; runtimeDomain, localPlanId,
                     localDefinitionRefHash, localOrderKey, routeId, routeHash,
                     modeWord, keccak(interfaceName), targetPlanId
                     [, targetOrderRefKey])   // new 恰 9 word；existing 追加第 10 word
linkedOrderId = H(UVP_DOCK_ORDER_V1; dockInstanceId, targetDefinitionRefHash)
                 | (1 << 255)
```

`localPlanId` 与产物 `planId` 同源（route 的 `local.planId` 承诺字段）。
第 9 word `targetPlanId` 是对接目标 plan 的派生 planId（resolution manifest
的 `evmPlanId`）：接口承诺 word 可被第三方复制进自建 plan，实例/子单身份
必须与对接目标 plan 绑定。

`localOrderKey` 的双轨口径（三条实现两形态，规格显式钉死）：
- **字符串 order id 轨**（TS 承诺层 `localOrderKey()`、云轨 Go）：order id
  是任意 slug 字符串，先 `keccak` 成 word 再进 preimage——本节公式即该轨。
  TS golden 向量（`fixtures/dock/v1`）与云轨 `order-fixture-001` 类 id 按此。
- **word 原值轨**（EVM 合约 `UVPDockingModule`）：EVM 轨的 order id 本身就是
  bytes32 word，`openDockedOrder` 身份推导直接取 word 原值、**不再 keccak**。
- 因此同一逻辑订单在两轨只能各自成立：字符串 id 不产生合法的 EVM word
  身份，word id 过 TS `keccakWord()` 会得到不同实例。跨轨对接的订单 id 形
  态约束（EVM 轨要求 id 即 word、云轨要求 slug）由部署面保证，本规格不为
  其定义换算。

### 4.5 envelope / 幂等键

```
sourceFactSetHash = H(UVP_DOCK_SOURCE_FACT_SET_V1; u64(n), w1..wn)   // fact word 升序
inputPayloadHash_v1 = H(UVP_DOCK_INPUT_PAYLOAD_V1; dockInstanceId, routeHash,
                       localPlanId, localOrderKey, localStageKey, localHookKey,
                       targetPlanId, linkedOrderId, keccak(targetPort),
                       targetSignalId, u64(sequence), ZERO_WORD)
inputIdempotencyKey  = H(UVP_DOCK_INPUT_IDEMPOTENCY_V1;  dockInstanceId,
                         inputBindingHash, u64(occurrence))
outputIdempotencyKey = H(UVP_DOCK_OUTPUT_IDEMPOTENCY_V1; dockInstanceId,
                         outputBindingHash, targetFactId)
targetFactId = keccak256(abi.encode(sourceId, signalId))    // 64 字节拼接，无域
ZERO_WORD = 0x00…00（32 字节；sourceFactSetHash 槽位，与合约对齐）
```

### 4.6 planId / planHash（canonical JSON 域）

```
planId = keccak256("uvp:hook-plan-id:v1:" + canonical_json({
  compiler: { name: "uvp-eth-compiler", version: "0.1.0" },
  platform, zhixuId, zhixuName }))

planHash = keccak256("uvp:hook-plan-artifact:v1:" + canonical_json(制品载荷))
```

planHash 载荷 = 最终制品全部字段 + `source`（canonical 化的定义快照，剔除
`metadata.annotations`）。`source` 是制品必携必填字段（`HookPlanArtifact.source`）：
制品边界对其缺失/非 canonical 形态响亮拒绝并按携带字段重算 planHash——
"同一 plan 唯一字节数组形态"的承诺以它随制品下发为前提。
`uvp:onchain-hook-plan-artifact:v1`
（onchain 制品 planHash）与 `uvp.plan.runtime.v2`（PlanCommit 五域运行时
哈希，`keccak256(abi.encode(...))` 形态）见 `onchain-hook-plan.ts`。

### 4.7 EIP-712 entrance permit（V2 typehash）

```
typehash = UVPDockEntrancePermitV2(bytes32 targetPlanId,bytes32 targetEntrancePortId,
          bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,
          bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,
          uint256 nonce,uint256 deadline)
domain = { name: "UVPDockingModule", version: "4", chainId, verifyingContract }
```

EIP-712 的 structHash/typehash/domain 编码按规范
`keccak256(concat(...))`（**无** domain word 前缀，与 §1 不同）；
feeLimit 恒 0。

`nonce` 序列**从 1 起**：合约按 `usedEntrancePermitNonce`（storage 缺省 0）
做单调下界判定，nonce=0 恒被拒且不消耗——签发方与 TS builder
（`eip712PermitDigest`）都不得产出 nonce=0 的 permit。

## 5. 数值锚点（对拍基准）

以下向量跨实现必须逐字节一致（golden 样本 `friction_wheel_production`
定义；完整向量集见 `fixtures/dock/v1/manifest.json`）：

```
EMPTY_MERKLE_ROOT      = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
targetUid              = zx-459b6f6c0e1fe47ace72be19ef0fad4d
targetDefinitionRefHash= 0x3085d8ba890395b08454591df427faf64ab6af3c8c343386915c873eff3192b4
targetPlanId           = 0xa217a05f605edc13ae024f9e3baf15de239735c634a398cd9b77be86da3fb545
targetArtifactHash     = 0x2fd5ff69d18d371012cb2890f3a3089bb5b4099abe0aeb71f9dd1968b83caca5
production_service.interfaceRoot = 0x6606c6ba39b2e413e9debf9dad029ce23f47c6e410e6730c25a1570ae77b556b
targetDockInterfaceRoot= 0x427c26899f67f4b2dd8d23f6d3ff37faa682449cfd79236104ac89a8e98341ff
evmRuntimeDomain(31337, 0x5FbDB2315678afecb367f032d93F642f64180aa3)
                       = 0xa94a0dfb7ca902548259fc0032f6f1cbf654f1f291c31b748af22732e6c7001e
cloudRuntimeDomain("uvp-cloud-deployment-fixture", "uvp-cloud-security-fixture")
                       = 0xf9747a82566e7d832a4c9f925a41141970614a89f796997fde9e2796a4f0d820
```

route/实例/信封向量依赖调用方定义内容（v2 起父定义 target 按 name 引用），
以 golden manifest 为准，不在本文重复内联。
