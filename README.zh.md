<p align="right">
  <a href="./README.md">English</a> | <strong>简体中文</strong>
</p>

# uvp-protocol

EVM 原生 UVP 方向的协议边界。

公开状态：alpha 协议核心。编译器制品、状态机语义、合约接口、ABI
fixtures、Product DTO 和 replay model 是公开主干。外部审计和生产治理加固仍未完成。

在本工作区拆分为公开仓库前，面向协议的 Product DTO 必须继续和 PRD109 的收束契约保持一致。Executor overlay 是当前已经实现的动态阶段权限机制。Product task manifest 描述 `submit_signal`、`stage_executor_patch`、`stage_resource_patch` 等 executor action。Docked Zhixu runtime 按本地/关联订单的 signal binding 建模，而不是订单层级结构。

本域负责确定性语义和公开协议接口：

- `packages/hook-core/`：Hook DSL 解析、依赖提取和本地求值。
- `packages/compiler/`：Zhixu 到链上 HookPlan 制品和 register-plan 参数生成。
- `packages/statemachine/`：离线链事件 replay oracle。
- `packages/product-dto/`：由协议投影派生的共享 Product DTO 合约。
- `contracts/uvp-contracts/`：Solidity 合约、ABI fixtures 和 Foundry tests。

## 开发拓扑

本仓库由 `uvp-eth` 作为 Git submodule 挂载。大多数 package 依赖都在本仓库内部，并由本地 `pnpm-workspace.yaml` 解析。

完整集成开发请使用 `uvp-eth` umbrella checkout，这样 pnpm 可以为 compiler、statemachine、contracts、chain services、deploy scripts 和 executor-kit 解析跨 package 的 `workspace:*` 依赖。

不要把 chain-service API 状态、产品专用 UI 状态、部署 manifest 或普通用户 app 代码放在这里。ABI、EIP-712 types、events、canonical hashes 和 artifact encodings 都是公开接口。
