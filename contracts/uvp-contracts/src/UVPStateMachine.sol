// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {UVPPlanRegistration} from "./UVPPlanRegistration.sol";
import {
    _HOOK_FLAG_ORDER_TRIGGER_MINT,
    _HOOK_FLAG_ORDER_TRIGGER_DOCK,
    _HOOK_FLAG_EMIT_READY,
    _HOOK_FLAG_ADMISSION,
    _MAX_HOOK_DELAY_SECONDS,
    _MAX_PLAN_DEPENDENCIES,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_RUNTIME_HASH_DOMAIN,
    _PLAN_ID_HASH_DOMAIN
} from "./UVPStateMachineConstants.sol";

contract UVPStateMachine {
    enum HookStatus {
        Init,
        Wait,
        Ready,
        Cancelled
    }

    // 求值指令词表（五指令闭集）：Signal=0, Not=1, And=2, Or=3,
    // Delay=4。声明顺序即协议编码值——Instruction.op 按 uint8 承载这些
    // 值，勿重排成员。
    enum InstructionOp {
        Signal,
        Not,
        And,
        Or,
        Delay
    }

    struct Instruction {
        // 按数值承载 InstructionOp 词表（ABI/EIP-712/hooksHash 编码与枚举
        // 形态逐字节一致）：词表外操作码（如扇入类 op=5）在
        // commitPlan 注册边界被 _validateHook 显式 revert
        // InvalidInstruction，而不是只依赖解码层的无名回滚。
        uint8 op;
        bytes32 sourceId;
        bytes32 signalId;
        uint16 arity;
        uint64 delaySeconds;
    }

    struct CompactHook {
        bytes32 hookId;
        bytes32 stageId;
        bytes32 hookName;
        // 位标志：1 = ORDER_TRIGGER_MINT；2 = ORDER_TRIGGER_DOCK；4 = EMIT_READY；
        // 8 = ADMISSION（发射适格面：hookId 槽 = 被发射事实的 signalKey，
        // hookName 槽 = signalId，进入 plan.admissions 而非 plan.hooks）。
        uint8 flags;
        Instruction[] instructions;
        bytes32[] dependencyKeys;
    }

    struct HookRuntime {
        HookStatus status;
        uint64 dueAt;
        bool readyEmitted;
        bool exists;
    }

    struct SignalRecord {
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        uint64 submittedAt;
        address submitter;
        bool exists;
    }

    struct SignalAuthorization {
        bytes32 sourceId;
        bytes32 signalId;
        address submitter;
        bytes32 role;
        bytes32 metadataHash;
    }

    struct TriggerOrderFromOutsideRequest {
        // 一事一单：orderId 由合约按 triggerOrderIdFor(planId, sourceId,
        // signalId, payloadHash) 纯函数派生，同一事实恒定同 id，重放幂等
        // （OrderAlreadyRegistered）。
        bytes32 planId;
        address creator;
        bytes32 triggerHookId;
        bytes32 triggerStageId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        uint256 deadline;
    }

    // trigger-origin 订单按 (originPlanId, triggerOriginOrderId) 复合键
    // 寻址：派生单与 origin 单可以分属不同 plan，跨 plan 链接必须显式声明
    // origin 的 plan。
    struct TriggerOrderFromSignalRequest {
        bytes32 orderId;
        bytes32 planId;
        address creator;
        bytes32 triggerOriginOrderId;
        bytes32 originPlanId;
        bytes32 triggerHookId;
        bytes32 triggerStageId;
        bytes32 originSourceId;
        bytes32 originSignalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        uint256 deadline;
    }

    /// 事实属主自证：声明非零 stageId 即声明"该 (sourceId, signalId) 事实
    /// 键的属主是 stageId"，必须与被提交的事实键一致且携有效 membership
    /// proof（能力叶 (stageId, sourceId, signalId, relation=0)）。键不一致
    /// 或验不过都响亮回滚（InvalidFactAttribution）——词表闸与物化门的
    /// "验过/未声明"必须对调用方可区分。stageId==0 表示不声明（词表外
    /// 事实口径）。仅 relation=0 的能力构成属主声明（编译器 E16 不变量：
    /// 同一 relation=0 键唯一属主）。
    struct FactAttribution {
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 stageId;
        bytes32[] capabilityProof;
    }

    /// fork 出生事实（UB-39 链轨形态）：每条必须与父单既有信号逐字段匹配
    /// （键 + payloadHash + idempotencyKey 一致），不匹配 revert——重放
    /// 输入只能来自父单真实历史（fail-closed，伪造事实无法借 fork 注入）。
    struct ForkBirthFact {
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
    }

    /// dock 出生入口请求（与 IUVPStateMachineCore.DockEntranceRequest 同形；
    /// 模块↔主合约 ABI 的跨栈参数收拢，UB-2 批）。
    struct DockEntranceRequest {
        bytes32 targetPlanId;
        bytes32 linkedOrderId;
        address creator;
        address relayer;
        bytes32 entranceHookId;
        bytes32 entranceStageId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        SignalAuthorization[] authorizations;
        FactAttribution entranceAttribution;
    }

    /// dock input 事实写入请求（同上收拢）。
    struct DockInputFact {
        bytes32 planId;
        bytes32 orderId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        FactAttribution attribution;
    }

    /// per-stage 信号记账（UB-2 封口）：count/末位提交者/末位时刻/同秒歧义
    /// 四字段并作一个 struct——单一 mapping 既省栈参数（EIP-170 外置库的
    /// 转发面），也让 stageSignalState 视图一次读全。
    struct StageSignalAccount {
        uint256 count;
        address lastSubmitter;
        uint64 lastAt;
        bool ambiguous;
    }

    struct PlanCommit {
        address publisher;
        bytes32 hooksHash;
        bytes32 capabilitiesRoot;
        bytes32 dockRoutesRoot;
        bytes32 dockInterfaceRoot;
        // 执行者候选集树根（UB-36②③）：叶 = keccak256(abi.encodePacked(
        // _EXECUTOR_CANDIDATE_LEAF_DOMAIN, stageId, executor))，DockMerkle
        // 同款建树；空集 = DockMerkle.EMPTY_ROOT，该形态下逐单 executor
        // patch 恒拒（不开候选集的计划没有逐单换人面，fail-closed）。
        bytes32 executorCandidatesRoot;
        // 出生授权者（10.4 复裁选 A）：outside 出生提交的唯一被授权
        // submitter，随 publisher 签名进 PlanCommit 承诺。零地址 = 该计划
        // 关闭 outside 出生通道（dock/order-link/fork 出生不受影响）。
        address birthAuthorizer;
        uint256 deadline;
    }

    /// executor 候选集条目（commitPlan 入参）：(stageId, executor) 对经
    /// 叶域哈希进候选树。creator/selector 的 patch 权不变，但 patch 目标
    /// 必须命中候选集——候选集外的任何人（含 creator 自己指定）不可成为
    /// 逐单执行者。
    struct ExecutorCandidate {
        bytes32 stageId;
        address executor;
    }

    struct StoredSignalAuthorization {
        bytes32 role;
        bytes32 metadataHash;
        bool exists;
    }

    struct StoredHook {
        bytes32 hookId;
        bytes32 stageId;
        bytes32 hookName;
        uint8 flags;
        Instruction[] instructions;
        bytes32[] dependencyKeys;
        bool exists;
    }

    /// 发射适格面（flag=8 槽位的存储形态）：按被发射事实的 signalKey
    /// 寻址（= CompactHook.hookId 槽）。只存指令——适格在提交一拍求值，
    /// 不参与 dependencyIndex 驱动的到达重评，dependencyKeys 只在注册边
    /// 界参与承诺与对拍。
    struct StoredAdmission {
        Instruction[] instructions;
        bool exists;
    }

    struct Plan {
        bytes32 planHash;
        bytes32 hooksHash;
        bytes32 capabilitiesRoot;
        bytes32 dockRoutesRoot;
        bytes32 dockInterfaceRoot;
        // 执行者候选集树根（UB-36②③）：executor patch 的 (targetStageId,
        // patch.executor) 必须携 proof 命中该树；EMPTY_ROOT = 无候选集，
        // patch 恒拒。
        bytes32 executorCandidatesRoot;
        address publisher;
        address birthAuthorizer;
        bytes32[] hookIds;
        mapping(bytes32 hookId => StoredHook hook) hooks;
        mapping(bytes32 signalKey => bytes32[] hookIds) dependencyIndex;
        mapping(bytes32 signalKey => StoredAdmission admission) admissions;
        mapping(bytes32 stageId => bool exists) stageExists;
        // 候选集的阶段投影（commit 时随建树数组落库）：assign 前置闸的
        // 免证判定材料——"该阶段是否属于逐单换人面"不再依赖调用方携
        // selector 绑定证明（不携证即放行的旧形态是时序 DoS 面），也不可
        // 能从 root 侧枚举（Merkle 存在性查询无非成员证明）。
        mapping(bytes32 stageId => bool covered) executorCandidateStages;
        bool committed;
        bool finalized;
        // 适格面在场位：与 committed/finalized 同槽打包（注册时随首条
        // admission 置位），_createOrder 把它复制进订单——外部提交路径
        // 因此只需读一个已加载槽即可判断"无适格面零成本跳过"。
        bool admissionsDeclared;
    }

    struct Order {
        // 订单的 plan 归属由 (planId, orderId) 寻址键本身保证，无法伪造。
        address relayer;
        address creator;
        // fork 血缘（同 plan 内，UB-39）：非 fork 单恒为 0。fork 单的
        // creator 承袭父单 creator（血缘连续，授权模型不因 fork 换头），
        // 发起人身份由 OrderForked 事件单独携带。
        bytes32 parentOrderId;
        mapping(bytes32 hookId => HookRuntime runtime) hookRuntimes;
        mapping(bytes32 stageId => bool materialized) materializedStages;
        bool materialized;
        bool exists;
        // plan.admissionsDeclared 的订单级快照（创建时复制）：提交卡点读
        // 的就是与 exists 同槽的布尔位，无适格面的 plan 不为适格面付任何
        // 冷读成本。
        bool admissionsDeclared;
    }

    struct ActiveStageExecutorPatch {
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
        bool exists;
    }

    struct EvalValue {
        bool value;
        bool wait;
        bool cancel;
        // dueAt 双语义槽：wait=true 时是重评期限；value=true 且 wait=false
        // 时是衰减否决位的有效期（core evaluator 的 expires_at——链上无
        // 调度器，到期不自动重评，该值只在本次求值内随 AND/OR 传递，落库
        // 前由 _evaluateHook 归零）。
        uint64 dueAt;
        uint64 anchorAt;
    }

    error EmptyPlan();
    error ExpiredSignalSignature(uint256 deadline);
    error ExpiredPlanSignature(uint256 deadline);
    error HookAlreadyRegistered();
    error HookDelayTooLong(uint256 delaySeconds);
    error CrossStageDependency(bytes32 signalKey);
    /// 出生通道键查重（U2）：同一出生键不得跨通道（mint∪dock）共用，也
    /// 不得被两条 dock entrance（按 route 钉死的键）共用——任一侧出生事务
    /// 会把另一侧的出生线一并推 Ready 并物化幻影阶段。注册边界按臂分界：
    /// mint∪dock / dock∪dock 与 Rust 校验同口径拒绝；mint∪mint 扇出
    /// （一事实多条 mint 出生线 / 同 stage 双 mint 钩，customs 基准 plan
    /// 的现行形态）本闸放行——Rust 编译期拒绝该臂（一事一单在编译期收
    /// 口，严于链上），是登记在案的分叉现状（constraints 注册表
    /// birth-channel-key-union-uniqueness 同 stage 臂；运行期单数云 N 单
    /// /链 1 单）。报错键即重复的 signalKey。
    error DuplicateBirthChannelKey(bytes32 signalKey);
    /// dependencyKeys 必须与 hook 指令集的 SIGNAL 原子键逐点一致：
    /// 未声明的 SIGNAL 键不进 dependencyIndex，该事实到达永不触发求值，
    /// hook 永久 Init 且零告警；多声明的键只是死索引。注册边界拒绝。
    error HookDependencyKeyMismatch(bytes32 hookId);
    error TooManyDependencies();
    /// 单依赖键挂靠 hook 数超过 _MAX_HOOKS_PER_DEPENDENCY_KEY：该键每次
    /// 事实提交全量循环求值，扇出必须注册期封顶。
    error TooManyHooksPerDependencyKey(bytes32 signalKey);
    error InvalidSignalSignature(address expectedSigner, address recoveredSigner);
    error InvalidSignalSignatureLength(uint256 length);
    error InvalidSignalCapability(bytes32 planId, bytes32 sourceId, bytes32 signalId);
    /// 提交方声明了属主阶段（attribution.stageId != 0）但携带的 membership
    /// proof 验不过：属主声明是"该事实键在本 plan 能力词表内"的自证，声明
    /// 即必须携有效证明——无效证明响亮回滚而不是静默降级为"无归属"，
    /// 否则词表闸与物化门的验与不验对调用方不可区分。
    error InvalidFactAttribution(bytes32 planId, bytes32 sourceId, bytes32 signalId, bytes32 claimedStageId);
    error InvalidInstruction();
    error InvalidHook();
    error InvalidModuleAddress();
    /// Dock child order IDs use a reserved namespace. Public MINT and
    /// trigger-origin paths must not be able to front-run a deterministic
    /// linkedOrderId.
    error InvalidDockOrderNamespace(bytes32 orderId);
    error InvalidPlanSignature(address expectedSigner, address recoveredSigner);
    error IncompleteModuleConfiguration();
    error InvalidTriggerHook(bytes32 hookId);
    /// order-link 派生单号不可自报：声明值必须等于按 link 事实重算的
    /// 派生值（0300 H-1，攻击推演见 docs/design-notes.md §1）。
    error InvalidOrderLinkOrderId(bytes32 declared, bytes32 derived);
    error InvalidTriggerOrderSignature(address expectedSigner, address recoveredSigner);
    error ModulesAlreadyFrozen();
    error ModulesFrozen();
    error ModulesNotFrozen();
    error NotOwner();
    error OrderAlreadyRegistered();
    error PlanAlreadyRegistered();
    // commitPlan 幂等重放（已 committed）与 finalizePlan 二次调用（已
    // finalized）是两个不同的拒绝点——复用 PlanAlreadyRegistered 会让
    // relayer 无法区分"重复提交 hooks"与"重复 finalize 元数据"。
    error PlanAlreadyFinalized();
    error HooksHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    /// commitPlan 从 calldata 候选数组重算的 root 与签名承诺不一致：候选
    /// 数组是被签名钉死的材料，不是可替换的提交参数。
    error ExecutorCandidatesRootMismatch(bytes32 expectedRoot, bytes32 actualRoot);
    error PlanNotCommitted();
    error PlanNotFinalized();
    error SignalAlreadyExists();
    /// 发射适格拒绝（外部提交卡点，适格三态非 Ready）：携带信号身份——
    /// 对发送方响亮的类型化业务错误，对事实流静默（零事实行/零钩子行，
    /// 整笔回滚不留 marker）。
    error SignalAdmissionRejected(bytes32 orderId, bytes32 sourceId, bytes32 signalId);
    /// 同一 (stageId, signalKey) 适格面重复声明：注册边界拒绝（编译器
    /// D031 的链上镜像）。
    error AdmissionAlreadyRegistered(bytes32 signalKey);
    error SignalSubmitterAlreadyAuthorized(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    /// HookReady 三线口径统一：order-trigger hook 必须携带 EMIT_READY。编译器
    /// 产物恒为 trigger|EMIT_READY（mint=5 / dock=6）；`_evaluateHook` 对
    /// order-trigger 无条件置 readyEmitted 并发 HookReady——缺 EMIT_READY 的
    /// "沉默 trigger" 会让链下 oracle 的 skip 口径与链上分叉。该形态在注册
    /// 边界直接拒绝（编译器是第一道防线，这里是注册边界）。
    error SilentOrderTriggerHook(bytes32 hookId);
    error StageExecutorNotAssigned(bytes32 orderId, bytes32 targetStageId);
    error StageNotMaterializable(bytes32 stageId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error TimerNotDue();
    error TimerNotWaiting();
    // trigger link 建立需要 origin 侧同意：submitter 与 relayer 都不在
    // origin 订单的同意集合（创建者 / origin 源阶段执行器 / origin 事实的
    // 授权提交者）内时拒绝。
    error UnauthorizedTriggerOrigin(bytes32 originPlanId, bytes32 originOrderId, address submitter);
    error UnauthorizedSignalSubmitter(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    error UnauthorizedStateMachineModule(address caller);
    error UnauthorizedStageExecutor(bytes32 orderId, bytes32 targetStageId, address submitter, address executor);
    error UnknownHook();
    error UnknownOrder();
    error UnknownPlan();
    // fork 出生通道（UB-39）：
    /// fork 授权裁决信号在父单不存在（或零字键）——裁决信号必须是父单
    /// 真实历史里的事实，存在性-only 的空授权不可用。
    error ForkApprovalSignalUnknown(
        bytes32 planId, bytes32 parentOrderId, bytes32 approvalSourceId, bytes32 approvalSignalId
    );
    /// fork 发起人不在授权集合（父单 creator / 裁决信号提交者）内——绑
    /// 身份，消化"存在性-only 授权"缺口。
    error UnauthorizedOrderFork(bytes32 planId, bytes32 parentOrderId, address initiator);
    /// fork 出生事实与父单既有信号逐字段不匹配（键 + payloadHash +
    /// idempotencyKey）——重放输入只能来自父单真实历史。
    error InvalidForkBirthFact(bytes32 parentOrderId, bytes32 sourceId, bytes32 signalId);
    /// fork 出生事实数超上限（gas 防护：每条事实都要回读父单信号并重放
    /// 求值，无上限的 birthFacts 会把单笔 fork 推出 block gas limit 之外
    /// 的 DoS 面）。
    error TooManyForkBirthFacts(uint256 count);
    error ZeroOrderCreator();
    error ZeroOrderId();
    error ZeroPatchHash();
    error ZeroOwner();
    error ZeroPlanPublisher();
    error ZeroSignalId();
    error ZeroSourceId();
    error UnauthorizedBirthSubmitter(address submitter);
    error ZeroStageExecutor();
    error ZeroSubmitter();
    error ZeroTargetStageId();

    address public owner;
    address public stagePatchModule;
    address public derivedSignalModule;
    address public dockingModule;

    function planMetadataModule() external view returns (address) {
        return _s.planMetadataModule;
    }

    address public orderLinkModule;
    address public lens;
    bool public modulesFrozen;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_ORIGIN = 1;

    // hook 标志与上限取自 UVPStateMachineConstants.sol 文件级单一声明点；
    // public 形态保持拆分前的 ABI getter 签名。
    uint8 public constant HOOK_FLAG_ORDER_TRIGGER_MINT = _HOOK_FLAG_ORDER_TRIGGER_MINT;
    uint8 public constant HOOK_FLAG_ORDER_TRIGGER_DOCK = _HOOK_FLAG_ORDER_TRIGGER_DOCK;
    uint8 public constant HOOK_FLAG_EMIT_READY = _HOOK_FLAG_EMIT_READY;
    uint8 public constant HOOK_FLAG_ADMISSION = _HOOK_FLAG_ADMISSION;
    uint64 public constant MAX_HOOK_DELAY_SECONDS = _MAX_HOOK_DELAY_SECONDS;
    uint256 public constant MAX_PLAN_DEPENDENCIES = _MAX_PLAN_DEPENDENCIES;
    // fork 出生事实数上限（UB-39）：每条事实要回读父单信号并重放求值，
    // 无上限的 birthFacts 是单笔交易 gas 失控面。
    uint256 public constant MAX_FORK_BIRTH_FACTS = 256;

    // fork 派生订单号的独立哈希域：与 outside-trigger（triggerOrderIdFor）、
    // order-link（orderLinkOrderIdFor）派生域结构性隔离，跨域占用只能靠
    // keccak256 碰撞。
    bytes32 private constant _FORK_ORDER_ID_DOMAIN = keccak256("uvp.fork.order_id.v1");

    // order-link 派生订单号的独立哈希域：与 outside-trigger 派生域
    // (triggerOrderIdFor) 结构性隔离，跨域占用只能靠 keccak256 碰撞。
    bytes32 private constant _ORDER_LINK_ORDER_ID_DOMAIN = keccak256("uvp.order_link.order_id.v1");
    bytes32 public constant DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes32 private constant _SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        // signal 提交摘要绑定 (planId, orderId)。
        "UVPStateMachineSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant _TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        // 一事一单：订单 id 由合约从事实纯函数派生，签名不背书调用方
        // 选择的订单号（mempool 抢注推演见 docs/design-notes.md §1）。
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    /// 订单/计划运行时状态锚（EIP-170 外置库的单参数存储访问面）：全部
    /// 运行时 mapping 并作一个 storage 结构体，UVPPlanRegistration 的订单
    /// 运行时副本以 `SMState storage _s` 单参数携带全部存储根——storage
    /// 指针是运行期值、占真实栈位（与合约内隐式槽常量的免费再生物化
    /// 不同），逐参数传递会撞 via_ir 深栈上限。破坏性批内全新部署，
    /// 存储布局随锚点重排，无迁移负担。
    struct SMState {
        mapping(bytes32 => Plan) plans;
        mapping(bytes32 => mapping(bytes32 => Order)) orders;
        mapping(bytes32 => mapping(bytes32 => mapping(bytes32 => SignalRecord))) signals;
        mapping(
            bytes32 planId
                => mapping(
                bytes32 orderId
                    => mapping(
                    bytes32 signalKey => mapping(address submitter => StoredSignalAuthorization authorization)
                )
            )
        ) signalAuthorizations;
        mapping(
            bytes32 planId
                => mapping(bytes32 orderId => mapping(bytes32 targetStageId => ActiveStageExecutorPatch patch))
        ) activeStageExecutorPatches;
        mapping(
            bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 sourceId => SourceSignalAccount account))
        ) sourceSignalAccounts;
        mapping(
            bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 stageId => StageSignalAccount account))
        ) stageSignalAccounts;
        address planMetadataModule;
    }

    SMState private _s;

    // planMetadataModule 随锚点入 struct（外置库单参数可达）；显式 getter
    // 保持原 public 变量的 ABI 选择子面。

    // 订单及全部 per-order 状态按 (planId, orderId) 复合键存储：不同 plan
    // 各自拥有同一 orderId 的订单时互不可见、互不干扰；同一 plan 内同一
    // orderId 保持创建幂等（OrderAlreadyRegistered），"同 plan 同事实同单"
    // 的重放语义不变。订单 id 派生公式必须在链下并入 planId 域，使派生单号
    // 天然绑定 plan。
    /// 源级事实记账（count/末位提交者并作一个 struct）：显式 getter 保持
    /// 原 public mapping 的 ABI 选择子面（sourceSignalCount / lastSignalSubmitter
    /// 的签名不变），单一 mapping 同时省 EIP-170 外置库的转发栈位。
    struct SourceSignalAccount {
        uint256 count;
        address lastSubmitter;
    }

    function sourceSignalCount(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (uint256) {
        return _s.sourceSignalAccounts[planId][orderId][sourceId].count;
    }

    function lastSignalSubmitter(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (address) {
        return _s.sourceSignalAccounts[planId][orderId][sourceId].lastSubmitter;
    }
    // 合约原生 per-stage 信号计数（UB-2 封口）：事实归属 stage = 提交方
    // 携证声明的属主 stageId；未声明时按 source==stage 回退（sourceId 是
    // 本 plan 已注册 stage id 时归属该 stage）。stage patch 模块的
    // ASSIGN/HANDOFF 时序闸改读本计数——不依赖调用方携证供表，
    // "省证绕计数"的口子在各写入口
    // 的词表闸（_resolveSourceStage：有词表的 plan 事实必须携有效
    // attribution 才能落库）封死。同秒歧义（最高 submittedAt 并列且提交者
    // 不同）由 _stageSignalAmbiguous 标记，HANDOFF 回退链 fail-closed。

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event StateMachineModuleSet(bytes32 indexed moduleId, address indexed previousModule, address indexed newModule);
    event StateMachineModulesFrozen(bytes32 indexed moduleSetHash);
    event PlanCommitted(
        bytes32 indexed planId,
        bytes32 indexed planHash,
        address indexed publisher,
        bytes32 hooksHash,
        bytes32 capabilitiesRoot,
        uint256 hookCount,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot,
        // 执行者候选集树根（UB-36②③）：第六承诺域随事件广播，索引器/回放
        // 方不必反查 plan 存储即可重建 patch 候选面。
        bytes32 executorCandidatesRoot,
        // 出生授权人（B-03）：outside 出生闸的授权地址随事件广播，授权面
        // 全量重建不必反查 planBirthAuthorizer view。
        address birthAuthorizer
    );
    event PlanFinalized(bytes32 indexed planId, bytes32 indexed planHash, bytes32 capabilitiesRoot);
    event PlanRegistered(bytes32 indexed planId, bytes32 planHash, uint256 hookCount);
    event PlanPublisherRecorded(bytes32 indexed planId, address indexed publisher);
    event OrderRegistered(bytes32 indexed orderId, bytes32 indexed planId);
    event OrderMaterialized(bytes32 indexed orderId, bytes32 indexed planId, bytes32 indexed stageId);
    event OrderRelayerRecorded(bytes32 indexed planId, bytes32 orderId, address indexed relayer, address creator);
    event SignalSubmitterAuthorized(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 signalId,
        address submitter,
        bytes32 role,
        bytes32 metadataHash
    );
    event SignalSubmitted(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        // 事实归属阶段（B-03）：per-stage 归属（0 = 词表外事实）随事件广播，
        // 索引器重建 per-stage 计数不必反查 stageSignalState view。
        bytes32 factStageId
    );
    event StageMaterialized(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed stageId,
        bytes32 triggerHookId,
        bytes32 sourceId,
        bytes32 signalId
    );
    event OrderTriggered(
        bytes32 indexed orderId,
        bytes32 indexed planId,
        bytes32 indexed triggerStageId,
        // triggerHookId 让索引器/回放方不必反查 plan 即可定位出生 hook
        // 定义（多 hook 阶段下 stageId 不足以定位求值语义）。
        bytes32 triggerHookId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    );
    event StageExecutorActivated(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        address executor,
        bytes32 role,
        bytes32 metadataHash,
        uint256 patchNonce,
        string metadataURI
    );
    event HookStatusChanged(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed hookId,
        HookStatus previousStatus,
        HookStatus newStatus,
        uint64 dueAt
    );
    event HookReady(
        bytes32 indexed planId, bytes32 indexed orderId, bytes32 indexed hookId, bytes32 stageId, bytes32 hookName
    );
    event TimerPoked(bytes32 indexed planId, bytes32 indexed orderId, bytes32 indexed hookId, uint64 dueAt);
    // fork 出生血缘（UB-39 链轨形态）：fork 单号由 forkOrderIdFor 从
    // (planId, parentOrderId, forkPayloadHash) 纯函数派生；裁决信号
    // (approvalSourceId, approvalSignalId) 必须存在于父单且 initiator 在
    // 父单 creator / 裁决信号提交者集合内。事实重放沿用 SignalSubmitted
    // 事件口径（对拍友好：索引器把 fork 单当作普通单从事件重建，血缘只读
    // 本事件）。
    event OrderForked(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed parentOrderId,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        address initiator,
        // fork 单号派生载荷（B-03）：forkedOrderId =
        // forkOrderIdFor(planId, parentOrderId, forkPayloadHash)，血缘链
        // 重算/校验不必反查 view。
        bytes32 forkPayloadHash,
        // 重放事实键清单（B-03）：keccak256(abi.encode(sourceId, signalId))
        //（与 _signalKey 同式），fork 重放事实与新生事实凭本清单区分——
        // 清单内键的 SignalSubmitted 是父单事实重放，清单外是 fork 单新生。
        bytes32[] replayedFactKeys
    );

    bytes32 public constant STAGE_PATCH_MODULE_ID = keccak256("uvp.module.stage_patch.v1");
    bytes32 public constant DERIVED_SIGNAL_MODULE_ID = keccak256("uvp.module.derived_signal.v1");
    bytes32 public constant DOCKING_MODULE_ID = keccak256("uvp.module.docking.v1");
    bytes32 public constant PLAN_METADATA_MODULE_ID = keccak256("uvp.module.plan_metadata.v1");
    bytes32 public constant ORDER_LINK_MODULE_ID = keccak256("uvp.module.order_link.v1");
    bytes32 public constant LENS_MODULE_ID = keccak256("uvp.module.lens.v1");

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert ZeroOwner();
        }
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    function setStagePatchModule(address moduleAddress) external onlyOwner {
        stagePatchModule = _setModule(STAGE_PATCH_MODULE_ID, stagePatchModule, moduleAddress);
    }

    function setDerivedSignalModule(address moduleAddress) external onlyOwner {
        derivedSignalModule = _setModule(DERIVED_SIGNAL_MODULE_ID, derivedSignalModule, moduleAddress);
    }

    function setDockingModule(address moduleAddress) external onlyOwner {
        dockingModule = _setModule(DOCKING_MODULE_ID, dockingModule, moduleAddress);
    }

    function setPlanMetadataModule(address moduleAddress) external onlyOwner {
        _s.planMetadataModule = _setModule(PLAN_METADATA_MODULE_ID, _s.planMetadataModule, moduleAddress);
    }

    function setOrderLinkModule(address moduleAddress) external onlyOwner {
        orderLinkModule = _setModule(ORDER_LINK_MODULE_ID, orderLinkModule, moduleAddress);
    }

    function setLens(address moduleAddress) external onlyOwner {
        lens = _setModule(LENS_MODULE_ID, lens, moduleAddress);
    }

    function freezeModules() external onlyOwner {
        if (modulesFrozen) {
            revert ModulesAlreadyFrozen();
        }
        if (
            stagePatchModule == address(0) || derivedSignalModule == address(0) || dockingModule == address(0)
                || _s.planMetadataModule == address(0) || orderLinkModule == address(0) || lens == address(0)
        ) {
            revert IncompleteModuleConfiguration();
        }

        modulesFrozen = true;
        emit StateMachineModulesFrozen(moduleSetHash());
    }

    function moduleSetHash() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                stagePatchModule, derivedSignalModule, dockingModule, _s.planMetadataModule, orderLinkModule, lens
            )
        );
    }

    function _setModule(bytes32 moduleId, address previousModule, address moduleAddress) private returns (address) {
        if (modulesFrozen) {
            revert ModulesFrozen();
        }
        if (moduleAddress == address(0) || moduleAddress == address(this)) {
            revert InvalidModuleAddress();
        }
        // 模块槽必须指向有代码的地址（extcodesize）：指 EOA 会让该模块面
        // 永久哑火，freeze 前后都无对冲。
        if (moduleAddress.code.length == 0) {
            revert InvalidModuleAddress();
        }
        emit StateMachineModuleSet(moduleId, previousModule, moduleAddress);
        return moduleAddress;
    }

    // commitPlan/finalizePlan 主体外置 UVPPlanRegistration 链接库（EIP-170
    // 瘦身）：DELEGATECALL 下状态写入本合约、address(this) 不变，签名域与
    // 事件 emitter 保持。函数签名、返回值名与事件口径与外置前逐字节一致。
    function commitPlan(
        PlanCommit calldata commit,
        CompactHook[] calldata hooks,
        // 执行者候选集（UB-36②③）：(stageId, executor) 对按
        // _EXECUTOR_CANDIDATE_LEAF_DOMAIN 叶公式建 DockMerkle 树，root 进
        // PlanCommit 承诺（publisher 签名覆盖）；空集 = EMPTY_ROOT，该形态
        // 下逐单 executor patch 恒拒。
        ExecutorCandidate[] calldata executorCandidates,
        bytes calldata signature
    ) external returns (bytes32 planId) {
        planId = UVPPlanRegistration.commitPlan(_s.plans, modulesFrozen, commit, hooks, executorCandidates, signature);
    }

    /// finalize 与表规模脱钩：能力表/绑定表已随 capabilitiesRoot 在 commit
    /// 时被 publisher 签名承诺，本步只翻转 finalized 并把 roots 落进
    /// metadata 模块，任意调用者可完成（无权限门）。
    function finalizePlan(bytes32 planId) external {
        UVPPlanRegistration.finalizePlan(_s.plans, _s.planMetadataModule, planId);
    }

    function planRuntimeHash(
        bytes32 hooksHash,
        bytes32 capabilitiesRoot,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot,
        bytes32 executorCandidatesRoot
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _PLAN_RUNTIME_HASH_DOMAIN,
                hooksHash,
                capabilitiesRoot,
                dockRoutesRoot,
                dockInterfaceRoot,
                executorCandidatesRoot
            )
        );
    }

    function planIdFor(address publisher, bytes32 runtimePlanHash) public pure returns (bytes32) {
        return keccak256(abi.encode(_PLAN_ID_HASH_DOMAIN, publisher, runtimePlanHash));
    }

    /// outside 触发出生入口（执行体外置 UVPPlanRegistration——EIP-170 瘦身，
    /// DELEGATECALL 下状态/事件/EIP-712 域全部保持主合约上下文；语义文档
    /// 见库内 triggerOrderFromOutside）。
    function triggerOrderFromOutsideFor(
        TriggerOrderFromOutsideRequest calldata trigger,
        SignalAuthorization[] calldata authorizations,
        bytes calldata signature,
        FactAttribution calldata birthFactAttribution
    ) external {
        UVPPlanRegistration.triggerOrderFromOutside(_s, trigger, authorizations, signature, birthFactAttribution);
    }

    /// @notice Outside 触发订单 id 的权威派生公式（一事一单）：
    ///         keccak256(abi.encode(planId, sourceId, signalId, payloadHash))。
    ///         消费方（BFF/indexer/bootstrap）必须镜像此公式预计算订单号。
    function triggerOrderIdFor(bytes32 planId, bytes32 sourceId, bytes32 signalId, bytes32 payloadHash)
        public
        pure
        returns (bytes32)
    {
        // dock 子单号恒置最高位（DOCK_ORDER_NAMESPACE_MASK），出生订单派生
        // id 恒清该位——两个命名空间结构性分离；确定性不受影响（同一事实
        // 恒定派生同一 id）。
        return bytes32(
            uint256(keccak256(abi.encode(planId, sourceId, signalId, payloadHash)))
                & ~uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    /// @notice order-link 派生订单 id 的权威派生公式（一事一单）：以 link
    ///         事实（origin 复合身份 + origin 事实 + payload）为 preimage 的
    ///         独立哈希域，且恒清 dock 命名空间位。自报 orderId 与派生值不
    ///         一致即 revert（0300 H-1，攻击推演见 docs/design-notes.md §1）。
    ///         重放同一 link 事实恒定派生同一 id，按
    ///         OrderAlreadyRegistered 幂等拒绝。
    function orderLinkOrderIdFor(
        bytes32 planId,
        bytes32 originPlanId,
        bytes32 triggerOriginOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        bytes32 payloadHash
    ) public pure returns (bytes32) {
        return bytes32(
            uint256(
                keccak256(
                    abi.encode(
                        _ORDER_LINK_ORDER_ID_DOMAIN,
                        planId,
                        originPlanId,
                        triggerOriginOrderId,
                        originSourceId,
                        originSignalId,
                        payloadHash
                    )
                )
            ) & ~uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    /// @notice fork 派生订单 id 的权威派生公式（UB-39 链轨 ABI 批形态）：
    ///         keccak256(abi.encode(_FORK_ORDER_ID_DOMAIN, planId,
    ///         parentOrderId, forkPayloadHash))，恒清 dock 命名空间位。
    ///         forkPayloadHash 是调用方对 fork 载荷（重放事实集选择、业务
    ///         分叉理由等内容）的内容哈希——同参重试恒定同单号（OrderAlreadyRegistered
    ///         幂等吸收，对齐既有出生通道语义），不同载荷自然分叉出不同单。
    ///         消费方（BFF/indexer）必须镜像此公式预计算 fork 单号。
    function forkOrderIdFor(bytes32 planId, bytes32 parentOrderId, bytes32 forkPayloadHash)
        public
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(keccak256(abi.encode(_FORK_ORDER_ID_DOMAIN, planId, parentOrderId, forkPayloadHash)))
                & ~uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    /// fork 出生通道（UB-39；执行体分段外置 UVPPlanRegistration——EIP-170
    /// 瘦身 + via_ir 深栈拆段：门/建单段（forkOrderGate）与重放段
    ///（forkOrderReplay）同一事务内顺序执行，语义文档见库内）。
    function forkOrder(
        bytes32 planId,
        bytes32 parentOrderId,
        bytes32 forkPayloadHash,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        ForkBirthFact[] calldata birthFacts,
        SignalAuthorization[] calldata authorizations
    ) external returns (bytes32 forkedOrderId) {
        forkedOrderId = UVPPlanRegistration.forkOrderGate(
            _s, planId, parentOrderId, forkPayloadHash, approvalSourceId, approvalSignalId, birthFacts, authorizations
        );
        UVPPlanRegistration.forkOrderReplay(_s, planId, parentOrderId, forkedOrderId, birthFacts);
    }

    /// trigger-origin 出生入口（仅 order-link 模块；执行体外置
    /// UVPPlanRegistration——EIP-170 瘦身，语义文档见库内 triggerOrderFromSignal）。
    function triggerOrderFromSignalFromModule(
        TriggerOrderFromSignalRequest calldata trigger,
        SignalAuthorization[] calldata authorizations,
        address relayer,
        FactAttribution[] calldata originFactAttributions
    ) external {
        if (msg.sender != orderLinkModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        UVPPlanRegistration.triggerOrderFromSignal(_s, trigger, authorizations, relayer, originFactAttributions);
    }

    function _createOrder(bytes32 planId, bytes32 orderId, address creator, address relayer) private {
        if (orderId == bytes32(0)) {
            revert ZeroOrderId();
        }
        if (creator == address(0)) {
            revert ZeroOrderCreator();
        }
        Plan storage plan = _s.plans[planId];
        if (!plan.finalized) {
            revert PlanNotFinalized();
        }
        Order storage order = _s.orders[planId][orderId];
        if (order.exists) {
            revert OrderAlreadyRegistered();
        }
        order.relayer = relayer;
        order.creator = creator;
        order.exists = true;
        // plan 的适格面在场位复制进订单（与 exists 同槽）：提交卡点凭订单
        // 级位短路，无适格面的 plan 不为适格面付冷读成本。
        order.admissionsDeclared = plan.admissionsDeclared;

        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (_isOrderTrigger(hook.flags)) {
                _initializeHookRuntime(order, hook.hookId);
            }
        }

        emit OrderRegistered(orderId, planId);
        emit OrderRelayerRecorded(planId, orderId, relayer, creator);
    }

    function _authorizeSignalSubmitters(bytes32 planId, bytes32 orderId, SignalAuthorization[] calldata authorizations)
        private
    {
        for (uint256 i = 0; i < authorizations.length; i++) {
            _authorizeSignalSubmitter(planId, orderId, authorizations[i]);
        }
    }

    function _authorizeSignalSubmitter(bytes32 planId, bytes32 orderId, SignalAuthorization calldata authorization)
        private
    {
        if (authorization.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        // sourceId==0 的事实键在能力词表内恒无成员资格，属主门永远不
        // 绑定，等于发布者签出一扇豁免门；注册期直接拒绝。
        if (authorization.sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (authorization.submitter == address(0)) {
            revert ZeroSubmitter();
        }

        bytes32 key = _signalKey(authorization.sourceId, authorization.signalId);
        StoredSignalAuthorization storage stored =
            _s.signalAuthorizations[planId][orderId][key][authorization.submitter];
        if (stored.exists) {
            revert SignalSubmitterAlreadyAuthorized(
                orderId, authorization.sourceId, authorization.signalId, authorization.submitter
            );
        }

        stored.role = authorization.role;
        stored.metadataHash = authorization.metadataHash;
        stored.exists = true;

        emit SignalSubmitterAuthorized(
            planId,
            orderId,
            authorization.sourceId,
            authorization.signalId,
            authorization.submitter,
            authorization.role,
            authorization.metadataHash
        );
    }

    /// 事实属主归属由提交方携 proof 声明（FactAttribution）：声明非零阶段
    /// 即必须验过该阶段对 (sourceId, signalId, relation=0) 的成员资格；
    /// 有词表的 plan 不声明即拒绝（词表闸与出生/dock output 通道同口径，
    /// 免证事实无法证明词表成员资格），零词表的手工 plan 按 source==stage
    /// 回退解析属主。
    function submitSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        FactAttribution calldata attribution
    ) external {
        _submitSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, msg.sender, attribution);
    }

    function submitSignalFor(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint256 deadline,
        bytes calldata signature,
        FactAttribution calldata attribution
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredSignalSignature(deadline);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }

        address recoveredSigner = _recoverSignalSubmitter(
            _signalSubmissionDigest(
                planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, deadline
            ),
            signature
        );
        if (recoveredSigner != submitter) {
            revert InvalidSignalSignature(submitter, recoveredSigner);
        }

        _submitSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, attribution);
    }

    function activateStageExecutorFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        address executor,
        bytes32 role,
        bytes32 executorMetadataHash,
        bytes32 patchHash,
        uint256 patchNonce,
        string calldata metadataURI
    ) external {
        if (msg.sender != stagePatchModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (executor == address(0)) {
            revert ZeroStageExecutor();
        }
        if (targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (!_isPlanStage(planId, targetStageId)) {
            revert UnknownHook();
        }
        ActiveStageExecutorPatch storage activePatch = _s.activeStageExecutorPatches[planId][orderId][targetStageId];
        if (patchNonce <= activePatch.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(orderId, targetStageId, activePatch.patchNonce, patchNonce);
        }

        activePatch.executor = executor;
        activePatch.role = role;
        activePatch.executorMetadataHash = executorMetadataHash;
        activePatch.patchHash = patchHash;
        activePatch.patchNonce = patchNonce;
        activePatch.metadataURI = metadataURI;
        activePatch.exists = true;

        emit StageExecutorActivated(
            planId, orderId, targetStageId, executor, role, executorMetadataHash, patchNonce, metadataURI
        );
    }

    /// 仅 stage patch 模块可调用（UB-36①）。
    /// executor patch 生效时把新城执行者的显式订单级授权集写入本合约——
    /// 授权来源 = selector 的 patch EIP-712 签名（authorizationsHash 进
    /// patch digest，签名覆盖授权集，provenance 可审计），写入经
    /// _authorizeSignalSubmitters 与出生通道同口径校验/同事件口径广播。
    function authorizeSignalSubmittersFromModule(
        bytes32 planId,
        bytes32 orderId,
        SignalAuthorization[] calldata authorizations
    ) external {
        if (msg.sender != stagePatchModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        // patch 重复授予吸收：executor 已持有的显式授权先到先得（不可被
        /// patch 撤销/改写），同键重复授予按幂等吸收——handoff 到已持授权
        /// 的执行者是常规业务形态，不得因此 revert。
        for (uint256 i = 0; i < authorizations.length; i++) {
            SignalAuthorization calldata authorization = authorizations[i];
            if (_s.signalAuthorizations[planId][orderId][_signalKey(
                        authorization.sourceId, authorization.signalId
                    )][authorization.submitter].exists) {
                continue;
            }
            _authorizeSignalSubmitter(planId, orderId, authorization);
        }
    }

    /// 仅 docking module 可调用。target plan publisher 对 dock 子单的显式
    /// 订单级信号授权入口（publisher 身份门在 docking module 的授权腿）：
    /// 写入经 _authorizeSignalSubmitters 与出生通道同口径校验/同事件广播。
    function authorizeDockedSignalsFromModule(
        bytes32 planId,
        bytes32 orderId,
        SignalAuthorization[] calldata authorizations
    ) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        _authorizeSignalSubmitters(planId, orderId, authorizations);
    }

    /// 仅 docking module 可调用。创建独立 linkedOrderId 子订单、
    /// 授权子订单信号提交者、写入 entrance canonical fact（绕过源阶段
    /// materialization 检查——该事实正是出生事实），entrance hook
    /// （ORDER_TRIGGER_DOCK）在出生事务内求值落 Ready 并物化目标
    /// stage——求值未落 Ready 整笔回滚。
    /// entrance 事实的属主阶段由 keeper 携 proof 声明（UB-2：dock 出生
    /// 通道与提交/镜像通道同口径——有词表的 plan 词表内事实必须携有效
    /// attribution，省证事实无法落库绕过 per-stage 计数）。
    function createDockedOrderFromModule(DockEntranceRequest calldata request) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        // 与其余 FromModule 信号写入口同口径：submitter==0 会把
        // lastSignalSubmitter 写成 0，污染 dock output 通道与 HANDOFF
        // 签名门的"上一提交者"判定。
        if (request.submitter == address(0)) {
            revert ZeroSubmitter();
        }
        // 出生事实零字键与其余写入口同口径拒绝（triggerOrderFromOutsideFor /
        // _authorizeSignalSubmitter）：sourceId==0 在能力词表内恒无成员资格，
        // 是 stage 物化与 executor 门的永久豁免键。
        // dependencyKeys 是不透明哈希，注册边界无法从键反查零字——入口
        // 必须自拒。
        if (request.sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (request.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        if (!_isDockOrderId(request.linkedOrderId)) {
            revert InvalidDockOrderNamespace(request.linkedOrderId);
        }
        // entrance 事实属主解析与提交通道同口径（词表闸 fail-closed +
        // source==stage 回退），解析结果进 per-stage 计数。
        bytes32 entranceFactStageId =
            _resolveSourceStage(request.targetPlanId, request.sourceId, request.signalId, request.entranceAttribution);
        _createOrder(request.targetPlanId, request.linkedOrderId, request.creator, request.relayer);
        _authorizeSignalSubmitters(request.targetPlanId, request.linkedOrderId, request.authorizations);
        // dock entrance 出生事务写入：entrance hook（ORDER_TRIGGER_DOCK）的
        // Ready/物化由出生事务内求值驱动，_requireDockTriggerHookReady 断言
        // 求值已落 Ready——未落（Cancelled/Init/Wait）整笔回滚。
        _recordSignal(
            request.targetPlanId,
            request.linkedOrderId,
            request.sourceId,
            request.signalId,
            request.payloadHash,
            request.idempotencyKey,
            request.submitter,
            true,
            entranceFactStageId
        );
        _requireDockTriggerHookReady(request.targetPlanId, request.linkedOrderId, request.entranceHookId, request.entranceStageId);
    }

    /// 非 entrance 的 dock input 事实写入（kind: signal 端口）。
    /// 目标内部 hook 正常求值；模块不得直接把 hook 标为 Ready。
    /// input 事实的属主阶段由 keeper 携 proof 声明（UB-2 词表闸同口径：
    /// 有词表的 plan 必须携有效 attribution，计数不可被省证绕过）。
    function recordDockedInputFromModule(DockInputFact calldata fact) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        // 同 createDockedOrderFromModule：submitter==0 污染
        // lastSignalSubmitter（dock output 通道 / HANDOFF 签名门）。
        if (fact.submitter == address(0)) {
            revert ZeroSubmitter();
        }
        // 同 createDockedOrderFromModule：零字事实键是 stage 物化与
        // executor 门的永久豁免键，入口自拒。
        if (fact.sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (fact.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        bytes32 factStageId = _resolveSourceStage(fact.planId, fact.sourceId, fact.signalId, fact.attribution);
        _recordSignal(
            fact.planId,
            fact.orderId,
            fact.sourceId,
            fact.signalId,
            fact.payloadHash,
            fact.idempotencyKey,
            fact.submitter,
            false,
            factStageId
        );
    }

    function planHookFlags(bytes32 planId, bytes32 hookId) external view returns (uint8) {
        StoredHook storage hook = _s.plans[planId].hooks[hookId];
        return hook.exists ? hook.flags : 0;
    }

    function planHookStageId(bytes32 planId, bytes32 hookId) external view returns (bytes32) {
        StoredHook storage hook = _s.plans[planId].hooks[hookId];
        return hook.stageId;
    }

    function planBirthAuthorizer(bytes32 planId) external view returns (address) {
        return _s.plans[planId].birthAuthorizer;
    }

    /// @notice hook 是否声明依赖事实 (sourceId, signalId)——plan 的 receive
    ///         词表投影（compiledHooks 的 dependencyKeys）。docking 模块用它
    ///         把 dock 出生锚事实键钉在目标 mailbox hook 的 SIGNAL 原子上。
    function planHookDependsOn(bytes32 planId, bytes32 hookId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool)
    {
        bytes32[] storage dependents = _s.plans[planId].dependencyIndex[_signalKey(sourceId, signalId)];
        for (uint256 i = 0; i < dependents.length; i++) {
            if (dependents[i] == hookId) {
                return true;
            }
        }
        return false;
    }

    /// @notice 阶段是否挂有 order-trigger（mint/dock）hook。出生/订阅阶段
    ///         的执行者终生不可变（云侧已强制）——stage patch
    ///         模块读本视图拒绝出生阶段的逐单 executor patch；资源补丁
    ///         （fileResources-only）不受此门，资源可替换。
    function stageHasOrderTriggerHook(bytes32 planId, bytes32 stageId) external view returns (bool) {
        Plan storage plan = _s.plans[planId];
        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (hook.stageId == stageId && _isOrderTrigger(hook.flags)) {
                return true;
            }
        }
        return false;
    }

    function planDockRoots(bytes32 planId) external view returns (bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot) {
        Plan storage plan = _s.plans[planId];
        return (plan.dockRoutesRoot, plan.dockInterfaceRoot);
    }

    /// 仅 docking module 可调用（dock output 镜像回写父单）。词表闸与
    /// 物化门的属主归属由 keeper 携 proof 声明——证明材料是公开产物，
    /// keeper 无特权。
    function submitSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        FactAttribution calldata attribution
    ) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }
        // 零字事实键与其余写入口同口径拒绝（dependencyKeys 不透明，词表
        // 闸对零字键恒放行，必须在写入口封死永久豁免键）。
        if (sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        // dock output 通道镜像 mint 词表闸：本地映射事实键必须在本 plan
        // 的能力词表内（编译器 D006：signalMap 键 ∈ sendSignals），成员
        // 资格由 attribution 携 proof 自证；无任何 capability 声明的手工
        // plan 放行（与 mint 同口径）。
        bool factKnown = _verifiedFactOwner(planId, sourceId, signalId, attribution) != bytes32(0);
        if (!factKnown && _hasCapabilityVocabulary(planId)) {
            revert InvalidSignalCapability(planId, sourceId, signalId);
        }
        bytes32 sourceStageId = _resolveSourceStage(planId, sourceId, signalId, attribution);
        _requireSourceStageReady(planId, orderId, sourceStageId);
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
    }

    /// Derived signals write a fact to a target order while the capability's
    /// stage belongs to the producing (from) path. The from identities ride
    /// the call so the executor leg binds to the producing order's stage, not
    /// the target order's——relation=1 的 from-执行者路径与派生模块的模块门
    /// （from 侧在任执行者）必须同口径放行，否则该路径过模块门后在 SM 层
    /// 恒 UnauthorizedStageExecutor（fail-closed 不可用）。relation 由派生
    /// 模块判定并显式传入：relation=0 的能力成员资格（即 fromStageId 是
    /// 该事实键的属主）已在模块入口经 proof 验证。
    function submitDerivedSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 fromPlanId,
        bytes32 fromOrderId,
        bytes32 stageId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) external {
        if (msg.sender != derivedSignalModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }
        // 执行者腿（两维度独立）：目标单显式 order 级授权豁免（与普通
        // submitSignal 同口径——显式授权独立于执行者委任）；否则绑 from
        // 单该阶段的在任执行者。
        if (!_hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter)) {
            _requireActiveStageExecutorByStage(fromPlanId, fromOrderId, stageId, submitter);
        }
        // relation=0（from==target 本单生产事实）与普通 submitSignal 同口径
        // 过物化门 + assign 前置门——否则显式授权者可在 assign 前写入生产
        // 事实，StageAlreadyHasSignal 把 assign 永久顶死；relation=1 回写
        // 不经两门（origin 订单无需物化 from 侧阶段），也不进 per-stage 计数
        //（事实不归属本单阶段——计数口径与物化门口径一致）。模块侧
        // targetOrderRelation 的 relation=0 判据就是 from==target 复合键，
        // 此处按同式重导，两口径不可能分叉。
        bool currentOrderFact = fromPlanId == planId && fromOrderId == orderId;
        bytes32 sourceStageId = currentOrderFact ? stageId : bytes32(0);
        _requireSourceStageReady(planId, orderId, sourceStageId);
        // 幂等吸收（与普通 submitSignal 的 first-win 同口径）：已落库的重复
        // 派生提交直接吸收返回，at-least-once 重试不得裸 revert
        // SignalAlreadyExists。授权与阶段门保持在吸收之前（与普通提交的
        // 闸序一致）。
        if (_hasSignal(planId, orderId, sourceId, signalId)) {
            return;
        }
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
    }

    function _submitSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        FactAttribution calldata attribution
    ) private {
        // 零字事实键与出生/授权入口同口径拒绝（triggerOrderFromOutsideFor /
        // _authorizeSignalSubmitter）：显式授权虽在注册期已拒零字键，普通
        // 提交路径仍须自拒——零字键是 stage 物化与 executor 门的永久豁免键。
        if (sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }

        if (!_isSignalSubmitterAuthorized(planId, orderId, sourceId, signalId, submitter)) {
            revert UnauthorizedSignalSubmitter(orderId, sourceId, signalId, submitter);
        }
        // 在任执行者门（UB-36①）：普通提交路径的
        // 授权唯一来源是显式订单级授权（出生通道写入或 patch 生效时对新城
        // 执行者写入的 executorAuthorizations）——显式授权独立于执行者委任
        // 且不可被后续 patch 撤销，故本路径不再有按事实键的执行者新鲜度
        // 校验；executor 委任面只经 submitDerivedSignalFromModule 的
        // _requireActiveStageExecutorByStage 绑定。

        // 属主阶段解析统一走 _resolveSourceStage：免证落库会按词表外口径
        // 绕过属主阶段物化门，随后诚实 ASSIGN patch 永久 StageAlreadyHasSignal。
        bytes32 sourceStageId = _resolveSourceStage(planId, sourceId, signalId, attribution);
        _requireSourceStageReady(planId, orderId, sourceStageId);
        // ① 幂等吸收（外部提交路径的 first-win 语义）：已落库的重复提交
        // 直接吸收返回、不再过适格——at-least-once 重试不得被过期窗口
        // revert（_recordSignal 保留 SignalAlreadyExists 给内部写入口，
        // 它们自带存在性预检，冲突即数据流事故）。
        if (_hasSignal(planId, orderId, sourceId, signalId)) {
            return;
        }
        // ② 发射适格面（仅外部提交过筛；内部生产者调用卡点以下层级）。
        _requireSignalAdmission(planId, orderId, sourceId, signalId);
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
    }

    /// 发射适格面卡点：(stage, signal) 声明了 validWhen 时按 block.timestamp
    /// 对 pre-state（不含本发）求值指令集，admit-iff-Ready（value && !wait
    /// && !cancel），非 Ready revert SignalAdmissionRejected。无适格声明的
    /// plan 由订单级 admissionsDeclared 位短路——该位读的是与 exists 同槽
    /// 的布尔字（提交路径必读），无适格面的 plan 零额外冷读。
    function _requireSignalAdmission(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId) private view {
        if (!_s.orders[planId][orderId].admissionsDeclared) {
            return;
        }
        StoredAdmission storage admission = _s.plans[planId].admissions[_signalKey(sourceId, signalId)];
        if (!admission.exists) {
            return;
        }
        EvalValue memory result = _evaluateInstructions(planId, orderId, admission.instructions);
        if (!result.value || result.wait || result.cancel) {
            revert SignalAdmissionRejected(orderId, sourceId, signalId);
        }
    }

    /// 属主阶段（提交方携 proof 自证或 source==stage 回退）的就绪门：阶段
    /// 已物化且（若在候选集换人面内）已有执行者。0 属主 = 词表外事实，
    /// 两门均不绑定（旧口径一致）。
    function _requireSourceStageReady(bytes32 planId, bytes32 orderId, bytes32 sourceStageId) private view {
        if (sourceStageId == bytes32(0)) {
            return;
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.materializedStages[sourceStageId]) {
            revert UnknownHook();
        }
        _requireStageExecutorAssigned(planId, orderId, sourceStageId);
    }

    /// 属主就绪门与物化检查都在入口完成；此处只写入事实、记账并驱动受
    /// 影响 hook 求值。factStageId 是入口按统一口径解析出的事实归属阶段
    ///（携证属主优先，零词表 plan 回退 source==stage；0 = 词表外事实，
    /// 不进 per-stage 计数）——ASSIGN/HANDOFF 时序闸的原生计数真源。
    function _recordSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        // 出生通道写入（outside 触发的出生事实 / dock entrance 出生事实）是
        // order-trigger hook 唯一允许的普通求值入口；见 _evaluateAffectedHooks。
        bool evaluateOrderTriggerHooks,
        bytes32 factStageId
    ) private {
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        bytes32 key = _signalKey(sourceId, signalId);
        SignalRecord storage signal = _s.signals[planId][orderId][key];
        if (signal.exists) {
            revert SignalAlreadyExists();
        }

        signal.sourceId = sourceId;
        signal.signalId = signalId;
        signal.payloadHash = payloadHash;
        signal.idempotencyKey = idempotencyKey;
        signal.submittedAt = uint64(block.timestamp);
        signal.submitter = submitter;
        signal.exists = true;
        _recordSourceSignal(planId, orderId, sourceId, submitter);
        // per-stage 原生计数（UB-2）：时序闸（ASSIGN 要求计数为 0；HANDOFF
        // 无 active patch 时回退末位提交者）的真源，记账收进独立函数以压
        // _recordSignal 的 via_ir 深栈。
        if (factStageId != bytes32(0)) {
            _recordStageSignal(planId, orderId, factStageId, submitter);
        }

        emit SignalSubmitted(
            planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, factStageId
        );
        _evaluateAffectedHooks(planId, orderId, key, sourceId, signalId, evaluateOrderTriggerHooks);
    }

    function _recordSourceSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, address submitter) private {
        SourceSignalAccount storage sourceAccount = _s.sourceSignalAccounts[planId][orderId][sourceId];
        sourceAccount.count += 1;
        sourceAccount.lastSubmitter = submitter;
    }

    /// per-stage 记账：更大的时间戳重置判定，同秒不同提交者标歧义
    ///（消费者 fail-closed，不得按数组枚举序静默取值）。
    function _recordStageSignal(bytes32 planId, bytes32 orderId, bytes32 factStageId, address submitter) private {
        StageSignalAccount storage account = _s.stageSignalAccounts[planId][orderId][factStageId];
        account.count += 1;
        uint64 submittedAt = uint64(block.timestamp);
        if (submittedAt > account.lastAt) {
            account.lastAt = submittedAt;
            account.lastSubmitter = submitter;
            account.ambiguous = false;
        } else if (submittedAt == account.lastAt && submitter != account.lastSubmitter) {
            account.ambiguous = true;
        }
    }

    function pokeTimer(bytes32 planId, bytes32 orderId, bytes32 hookId) external {
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }

        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            revert UnknownHook();
        }
        if (runtime.status != HookStatus.Wait) {
            revert TimerNotWaiting();
        }
        if (runtime.dueAt == 0 || block.timestamp < runtime.dueAt) {
            revert TimerNotDue();
        }

        uint64 dueAt = runtime.dueAt;
        emit TimerPoked(planId, orderId, hookId, dueAt);
        _evaluateHook(planId, orderId, hookId, bytes32(0), bytes32(0));
    }

    function planExists(bytes32 planId) external view returns (bool) {
        // 语义口径：名称是 exists，返回值是"存在且已定稿"（两步注册
        // commit→finalize 的中间态返回 false）。ABI 冻结不改名——消费方
        // （docking/order-link/metadata 模块）以"可开单/可派生"为判定，
        // 未定稿 plan 恰应返回 false。
        return _s.plans[planId].finalized;
    }

    function planCommitted(bytes32 planId) external view returns (bool) {
        return _s.plans[planId].committed;
    }

    function planFinalized(bytes32 planId) external view returns (bool) {
        return _s.plans[planId].finalized;
    }

    function planHash(bytes32 planId) external view returns (bytes32) {
        return _s.plans[planId].planHash;
    }

    function orderExists(bytes32 planId, bytes32 orderId) external view returns (bool) {
        return _s.orders[planId][orderId].exists;
    }

    function planPublisher(bytes32 planId) external view returns (address) {
        return _s.plans[planId].publisher;
    }

    function orderRelayer(bytes32 planId, bytes32 orderId) external view returns (address) {
        return _s.orders[planId][orderId].relayer;
    }

    function orderCreator(bytes32 planId, bytes32 orderId) external view returns (address) {
        return _s.orders[planId][orderId].creator;
    }

    function getHookStatus(bytes32 planId, bytes32 orderId, bytes32 hookId)
        external
        view
        returns (HookStatus status, uint64 dueAt, bool readyEmitted)
    {
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            revert UnknownHook();
        }
        return (runtime.status, runtime.dueAt, runtime.readyEmitted);
    }

    function getSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter)
    {
        SignalRecord storage signal = _s.signals[planId][orderId][_signalKey(sourceId, signalId)];
        return (signal.exists, signal.payloadHash, signal.idempotencyKey, signal.submittedAt, signal.submitter);
    }

    function hasSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool)
    {
        return _hasSignal(planId, orderId, sourceId, signalId);
    }

    function hasSourceSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (bool) {
        return _s.sourceSignalAccounts[planId][orderId][sourceId].count != 0;
    }

    /// @notice 合约原生 per-stage 信号计数真源（UB-2 封口）：ASSIGN/HANDOFF
    ///         时序闸的判定材料。count = 事实归属该 stage 的已落库事实数
    ///        （归属口径：携证属主优先，零词表 plan 回退 source==stage）；
    ///         lastSubmitter/lastAt = 最高 submittedAt 的提交者与时刻；
    ///         ambiguous = 最高 submittedAt 并列且提交者不同（同秒歧义，
    ///         消费者 fail-closed）。
    function stageSignalState(bytes32 planId, bytes32 orderId, bytes32 stageId)
        external
        view
        returns (uint256 count, address lastSubmitter, uint64 lastAt, bool ambiguous)
    {
        StageSignalAccount storage account = _s.stageSignalAccounts[planId][orderId][stageId];
        return (account.count, account.lastSubmitter, account.lastAt, account.ambiguous);
    }

    /// @notice 订单的 fork 血缘（同 plan 内，UB-39）：非 fork 单恒为 0。
    function orderParent(bytes32 planId, bytes32 orderId) external view returns (bytes32) {
        return _s.orders[planId][orderId].parentOrderId;
    }

    /// @notice plan 的执行者候选集树根（UB-36②③）：EMPTY_ROOT = 无候选集，
    ///         逐单 executor patch 恒拒。
    function planExecutorCandidatesRoot(bytes32 planId) external view returns (bytes32) {
        return _s.plans[planId].executorCandidatesRoot;
    }

    function isSignalSubmitterAuthorized(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool) {
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            return false;
        }
        return _isSignalSubmitterAuthorized(planId, orderId, sourceId, signalId, submitter);
    }

    function hasExplicitSignalAuthorization(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool) {
        return _hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter);
    }

    function getSignalAuthorization(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool exists, bytes32 role, bytes32 metadataHash) {
        StoredSignalAuthorization storage authorization =
            _s.signalAuthorizations[planId][orderId][_signalKey(sourceId, signalId)][submitter];
        if (authorization.exists) {
            return (true, authorization.role, authorization.metadataHash);
        }
        return (false, bytes32(0), bytes32(0));
    }

    function activeStageExecutor(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (address)
    {
        return _s.activeStageExecutorPatches[planId][orderId][targetStageId].executor;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _signalSubmissionDigest(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _SIGNAL_SUBMISSION_TYPEHASH,
                planId,
                orderId,
                sourceId,
                signalId,
                payloadHash,
                idempotencyKey,
                submitter,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    /// 授权集哈希公式（公共单一出处，UB-36①）：trigger 出生请求与
    /// executor patch 的 EIP-712 摘要都以本公式把授权集折叠进签名——
    /// stage patch 模块对 patch.executorAuthorizations 复算时必须与
    /// triggerOrderFromOutsideFor 的 authorizationsHash 逐字节一致。
    function signalAuthorizationsHash(SignalAuthorization[] calldata authorizations) public pure returns (bytes32) {
        bytes32 rollingHash = keccak256(abi.encode(authorizations.length));
        for (uint256 i = 0; i < authorizations.length; i++) {
            SignalAuthorization calldata authorization = authorizations[i];
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    authorization.sourceId,
                    authorization.signalId,
                    authorization.submitter,
                    authorization.role,
                    authorization.metadataHash
                )
            );
        }
        return rollingHash;
    }

    function _signalKey(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function _isOrderTrigger(uint8 flags) private pure returns (bool) {
        return flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK) != 0;
    }

    function _isDockOrderId(bytes32 orderId) private pure returns (bool) {
        return uint256(orderId) & uint256(DOCK_ORDER_NAMESPACE_MASK) != 0;
    }

    /// origin 侧同意判定。
    ///
    /// 同意集合（party 持有 origin 订单上的任一身份即算同意）：
    /// 1. origin 订单创建者——订单级权威；
    /// 2. origin 事实 (originSourceId, originSignalId) 的显式授权提交者
    ///   （UB-36①，收紧方向）；
    /// 3. origin 源阶段的 active stage executor——执行者 overlay 下唯一的
    ///    阶段发言方。
    ///
    /// 语义：能够对 origin 订单说出（或被 origin 订单授权说出）该事实的一
    /// 方，才允许把它作为 trigger-origin 消费、在任意 plan 上派生新订单。
    /// 外部 plan 镜像公开 capability 声明不构成同意，capability 镜像攻击链
    /// （镜像 plan → 镜像 link → 派生单回写注入）在 link 建立刻被拒绝。
    /// 属主阶段由查询方携 proof 声明（originAttribution）：有词表的 plan
    /// 不携证即回滚（InvalidSignalCapability，与提交/出生路径同口径）；
    /// 零词表 plan 不携证时执行者一腿不可判定、按不存在处理——同意集合
    /// 只可能收紧（fail-closed）。
    function hasTriggerOriginConsent(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party,
        FactAttribution calldata originAttribution
    ) public view returns (bool) {
        if (party == address(0)) {
            return false;
        }
        bytes32 originStageId = _resolveSourceStage(originPlanId, originSourceId, originSignalId, originAttribution);
        return _triggerOriginConsent(originPlanId, originOrderId, originSourceId, originSignalId, party, originStageId);
    }

    function _triggerOriginConsent(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party,
        bytes32 originStageId
    ) private view returns (bool) {
        if (party == address(0)) {
            return false;
        }
        Order storage originOrder = _s.orders[originPlanId][originOrderId];
        if (!originOrder.exists) {
            return false;
        }
        if (originOrder.creator == party) {
            return true;
        }
        // An active executor patch must not revoke an explicit order-level
        // authorization. Explicit grants are independent business
        // authorization and remain valid throughout executor handoffs.
        if (_hasExplicitSignalAuthorization(originPlanId, originOrderId, originSourceId, originSignalId, party)) {
            return true;
        }
        ActiveStageExecutorPatch storage activePatch =
            _s.activeStageExecutorPatches[originPlanId][originOrderId][originStageId];
        if (originStageId != bytes32(0) && activePatch.exists) {
            return activePatch.executor == party;
        }
        // 三腿穷尽：创建者 / 显式 order 级授权 / origin 源阶段在任执行者。
        // 历史末位兜底只是显式授权的重查（此处必为假），与库孪生
        // L_triggerOriginConsent 对齐，直接 fail-closed。
        return false;
    }

    function _isPlanStage(bytes32 planId, bytes32 stageId) private view returns (bool) {
        if (stageId == bytes32(0)) {
            return false;
        }
        return _s.plans[planId].stageExists[stageId];
    }

    /// selector 绑定目标的 assign 前置闸（法条「指派先于信号」）：阶段在
    /// 候选集换人面内（executorCandidateStages，commit 时随候选数组落库）
    /// 且尚无 active patch 时，外部信号提交恒拒——判定不依赖调用方携证
    /// （不携证即放行的旧形态下，订单级显式授权提交者可在 ASSIGN 前写入
    /// 首个事实，StageAlreadyHasSignal 把该阶段的 ASSIGN 永久顶死，时序
    /// DoS）。已 assign（patch 存在）放行；目标阶段计数非零也放行——能
    /// 绕过本门的内部生产者（出生/dock entrance/dock input/fork 重放）已
    /// 把该阶段的 assign 面消耗为事实史，此时再拦外部信号只会饿死同阶段
    /// 的其余 watcher，不保护任何残余的 assign 机会。
    function _requireStageExecutorAssigned(bytes32 planId, bytes32 orderId, bytes32 targetStageId) private view {
        if (_s.activeStageExecutorPatches[planId][orderId][targetStageId].exists) {
            return;
        }
        if (!_s.plans[planId].executorCandidateStages[targetStageId]) {
            return;
        }
        if (_s.stageSignalAccounts[planId][orderId][targetStageId].count != 0) {
            return;
        }
        revert StageExecutorNotAssigned(orderId, targetStageId);
    }

    function _evaluateAffectedHooks(
        bytes32 planId,
        bytes32 orderId,
        bytes32 dependencyKey,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId,
        bool evaluateOrderTriggerHooks
    ) private {
        Plan storage plan = _s.plans[planId];
        Order storage order = _s.orders[planId][orderId];
        bytes32[] storage hookIds = plan.dependencyIndex[dependencyKey];
        // 出生锚订单归属（文法 §7.2：出生事实到达只应服务于铸造唯一订单）：
        // order-trigger（mint/dock）hook 的 Ready 与阶段物化只允许由出生
        // 通道驱动——outside 触发在出生事务内对出生事实求值（求值即出生
        // 闸 _requireTriggerHookReady 的就绪来源），dock entrance 求值后由
        // _requireDockTriggerHookReady 断言。普通信号提交（含 dock output
        // 回写、派生写回）不再求值 order-trigger hook：否则订单 Y（由事实
        // K2 铸出）内提交另一出生线事实 K1 会把 Y 的 K1-mint 钩子推 Ready
        // 并物化 Y 并未由此出生的阶段——每条出生线的阶段只在其自己铸出的
        // 订单上物化。
        if (evaluateOrderTriggerHooks) {
            for (uint256 i = 0; i < hookIds.length; i++) {
                StoredHook storage hook = plan.hooks[hookIds[i]];
                if (_isOrderTrigger(hook.flags)) {
                    _evaluateHook(planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
                }
            }
        }
        for (uint256 i = 0; i < hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[hookIds[i]];
            if (!_isOrderTrigger(hook.flags)) {
                // 纯 flags=0 watcher 且其阶段未物化时跳过而不是 revert（不
                // brick 模块写事实路径）——与回放 oracle 的 skip 语义对齐。
                // 该形态正常不可达（编译器拒绝不可物化阶段挂
                // receive hook），本分支是防御纵深；EMIT_READY hook 仍照常
                // 求值（executor dispatch 边允许先于阶段物化初始化）。
                if (hook.flags & HOOK_FLAG_EMIT_READY == 0 && !order.materializedStages[hook.stageId]) {
                    continue;
                }
                _evaluateHook(planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
            }
        }
    }

    function _validatedOrderTriggerHook(
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        uint8 requiredFlag
    ) private view returns (StoredHook storage hook) {
        Plan storage plan = _s.plans[planId];
        if (!plan.finalized) {
            revert UnknownPlan();
        }

        hook = plan.hooks[triggerHookId];
        if (!hook.exists || hook.flags & requiredFlag == 0 || hook.stageId != triggerStageId) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _validatedDockTriggerHook(bytes32 planId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
        returns (StoredHook storage hook)
    {
        hook = _validatedOrderTriggerHook(planId, triggerHookId, triggerStageId, HOOK_FLAG_ORDER_TRIGGER_DOCK);
    }

    /// 断言式出生闸（dock 路径；镜像库 L_requireTriggerHookReady）：出生
    /// 事务内 _recordSignal 已先对 entrance hook 求值（evaluateOrderTriggerHooks
    /// =true），order-trigger hook 落 Ready 必已 readyEmitted/物化——本函数
    /// 只断言求值结果，不写任何状态。求值未落 Ready（矛盾条件推 Cancelled、
    /// 多原子触发线部分交付停在 Init/Wait）一律整笔回滚，不把未就绪覆写
    /// 成 Ready 物化幻影阶段；与 outside 出生路径同判。
    function _requireDockTriggerHookReady(bytes32 planId, bytes32 orderId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
    {
        _validatedDockTriggerHook(planId, triggerHookId, triggerStageId);
        HookRuntime storage runtime = _s.orders[planId][orderId].hookRuntimes[triggerHookId];
        if (!runtime.exists || runtime.status != HookStatus.Ready || !runtime.readyEmitted) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _evaluateHook(
        bytes32 planId,
        bytes32 orderId,
        bytes32 hookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Plan storage plan = _s.plans[planId];
        StoredHook storage hook = plan.hooks[hookId];
        if (!hook.exists) {
            revert UnknownHook();
        }

        Order storage order = _s.orders[planId][orderId];
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            // 出生 hook（mint/dock）在任何时刻可初始化；EMIT_READY hook 是
            // executor dispatch 边，其 runtime 允许先于阶段
            // materialization 初始化——Ready 时会物化自身阶段。
            if (
                !_isOrderTrigger(hook.flags) && hook.flags & HOOK_FLAG_EMIT_READY == 0
                    && !order.materializedStages[hook.stageId]
            ) {
                revert UnknownHook();
            }
            _initializeHookRuntime(order, hookId);
        }
        if (runtime.status == HookStatus.Cancelled || runtime.status == HookStatus.Ready) {
            return;
        }

        HookStatus previousStatus = runtime.status;
        uint64 previousDueAt = runtime.dueAt;
        EvalValue memory result = _evaluateInstructions(planId, orderId, hook.instructions);
        HookStatus nextStatus = HookStatus.Init;
        uint64 nextDueAt;
        if (result.cancel) {
            nextStatus = HookStatus.Cancelled;
        } else if (result.wait) {
            nextStatus = HookStatus.Wait;
            nextDueAt = result.dueAt;
        } else if (result.value) {
            nextStatus = HookStatus.Ready;
        }

        runtime.status = nextStatus;
        runtime.dueAt = nextDueAt;

        if (previousStatus != nextStatus || previousDueAt != nextDueAt) {
            emit HookStatusChanged(planId, orderId, hookId, previousStatus, nextStatus, nextDueAt);
        }

        if (nextStatus == HookStatus.Ready && !runtime.readyEmitted) {
            if (_isOrderTrigger(hook.flags)) {
                runtime.readyEmitted = true;
                _materializeStage(planId, orderId, hook.stageId, hookId, triggerSourceId, triggerSignalId);
                emit HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
            } else if (hook.flags & HOOK_FLAG_EMIT_READY != 0) {
                // EMIT_READY 只决定"发可消费事件"，不授予订单创建能力；
                // 阶段物化仍发生（executor 激活面），出生 API 仍单独检查
                // order-trigger flag。
                runtime.readyEmitted = true;
                _materializeStage(planId, orderId, hook.stageId, hookId, triggerSourceId, triggerSignalId);
                emit HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
            }
        }
    }

    function _initializeHookRuntime(Order storage order, bytes32 hookId) private {
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (runtime.exists) {
            return;
        }
        runtime.status = HookStatus.Init;
        runtime.dueAt = 0;
        runtime.readyEmitted = false;
        runtime.exists = true;
    }

    function _materializeStage(
        bytes32 planId,
        bytes32 orderId,
        bytes32 stageId,
        bytes32 triggerHookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Order storage order = _s.orders[planId][orderId];
        if (!order.materialized) {
            order.materialized = true;
            emit OrderMaterialized(orderId, planId, stageId);
        }
        if (order.materializedStages[stageId]) {
            return;
        }
        order.materializedStages[stageId] = true;

        Plan storage plan = _s.plans[planId];
        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (hook.stageId == stageId) {
                _initializeHookRuntime(order, hook.hookId);
            }
        }

        emit StageMaterialized(planId, orderId, stageId, triggerHookId, triggerSourceId, triggerSignalId);
    }

    function _evaluateInstructions(bytes32 planId, bytes32 orderId, Instruction[] storage instructions)
        private
        view
        returns (EvalValue memory)
    {
        EvalValue[] memory stack = new EvalValue[](instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < instructions.length; i++) {
            Instruction storage instruction = instructions[i];
            if (instruction.op == uint8(InstructionOp.Signal)) {
                stack[stackDepth++] = _signalValue(planId, orderId, instruction.sourceId, instruction.signalId);
            } else if (instruction.op == uint8(InstructionOp.Not)) {
                stack[stackDepth - 1] = _notValue(stack[stackDepth - 1]);
            } else if (instruction.op == uint8(InstructionOp.Delay)) {
                stack[stackDepth - 1] = _delayValue(stack[stackDepth - 1], instruction.delaySeconds);
            } else if (instruction.op == uint8(InstructionOp.And)) {
                EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _andValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else if (instruction.op == uint8(InstructionOp.Or)) {
                EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _orValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else {
                // 存储侧只经 _validateHook 词表门写入，此处为词表外值的
                // 兜底拒绝（uint8 承载后不可再依赖类型层穷尽性）。
                revert InvalidInstruction();
            }
        }
        return stack[0];
    }

    function _signalValue(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (EvalValue memory)
    {
        SignalRecord storage signal = _s.signals[planId][orderId][_signalKey(sourceId, signalId)];
        if (!signal.exists) {
            return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: signal.submittedAt});
    }

    function _notValue(EvalValue memory value) private pure returns (EvalValue memory) {
        if (value.value) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        // 衰减否决位（合取直接子项上的 ~(A+duration)，_validateHook 位置门
        // 保证唯一合法形态）：内层在案未熟 → 本项此刻成立，dueAt 携带有效
        // 期至成熟时刻（与 core evaluator 的 Not(Wait{ready_at}) →
        // Ready{expires_at} 同义）。同一求值内 now 恒定，wait 分支的 dueAt
        // 必严格晚于 block.timestamp——core 侧的"已过期防御臂"在此按构造
        // 不可达，不设镜像。
        if (value.wait) {
            return EvalValue({value: true, wait: false, cancel: false, dueAt: value.dueAt, anchorAt: 0});
        }
        if (value.cancel) {
            return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _delayValue(EvalValue memory value, uint64 delaySeconds) private view returns (EvalValue memory) {
        if (value.cancel || !value.value) {
            return value;
        }
        // 无锚永不放行（UB-1 防御纵深，与 Rust 权威 uvp-hook-dsl
        // evaluation/mod.rs eval_expr 的 Delay 臂对齐：Ready 且 anchors 为
        // 空时返回 NeedsMore，而不是把 anchorAt=0 当 0 时刻起算——后者
        // 会让 dueAt=delaySeconds 落在过去而立即放行，外层延时锚到过去）。
        // 返回三 false 的中性值（钩子档映射回 Init/未决）。
        if (value.anchorAt == 0) {
            return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        uint64 dueAt = value.anchorAt + delaySeconds;
        if (block.timestamp < dueAt) {
            return EvalValue({value: false, wait: true, cancel: false, dueAt: dueAt, anchorAt: value.anchorAt});
        }
        // Anchor advancement (semantic 0.5 chained-delay ruling): the maturity
        // moment becomes the new anchor so `(A + 1s) + 5s` counts the outer
        // delay from A+1s, matching the core evaluator and replay oracle.
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: dueAt});
    }

    function _andValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {
        if (left.cancel || right.cancel) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        if (left.value && right.value) {
            return EvalValue({
                value: true,
                wait: false,
                cancel: false,
                // 衰减有效期取成员最紧者（_minDue 的 0=无限语义：无限不放宽
                // 有限期）——任一成员到期即整体不再成立，与 core evaluator
                // 的 min_expires 同义。
                dueAt: _minDue(left.dueAt, right.dueAt),
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if ((left.wait && (right.value || right.wait)) || (right.wait && (left.value || left.wait))) {
            return EvalValue({
                value: false,
                wait: true,
                cancel: false,
                // 等待期限只由等待成员贡献：就绪成员的 dueAt 是衰减有效期而
                // 非等待期限，不得混入 max（core evaluator 的 And 只收集
                // Wait 成员的 ready_at）。
                dueAt: _maxDue(left.wait ? left.dueAt : 0, right.wait ? right.dueAt : 0),
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _orValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {
        // Arrival-time causality (semantic 0.5): OR keeps the EARLIEST
        // received signal as the cause so trailing delays anchor on first
        // arrival, matching the core evaluator and replay oracle.
        if (left.value || right.value) {
            // Winner selection mirrors the Rust authority (uvp-hook-dsl
            // evaluation/mod.rs Expr::Or + branch_maturity)：incumbent=左，
            // candidate=右只在严格更好时替换（candidate < incumbent）。
            // 右胜仅当「右有锚而左无锚」（(None, Some)）或「双方有锚且右
            // 严格更早」；四格全表：(0,0) 双无锚保左（(None, None) => 不
            // 替换）、(t,0) 保左（(None, _) => false）、(0,t) 右胜、(t,t)
            // 取早者且平局保先到（左）分支。
            // 胜者载荷逐字透传（含衰减否决位有效期 dueAt）：胜者自身的
            // 有效性不随分支竞争收紧。
            bool leftWins;
            if (left.value && !right.value) {
                leftWins = true;
            } else if (!left.value && right.value) {
                leftWins = false;
            } else {
                // 平票矩阵四格同表：右支仅在严格更早（或有锚对无锚）时
                // 出线——含双无锚的 (0,0) 格在内，平局一律保持左支。
                leftWins = !(right.anchorAt != 0 && (left.anchorAt == 0 || right.anchorAt < left.anchorAt));
            }
            return EvalValue({
                value: true,
                wait: false,
                cancel: false,
                dueAt: leftWins ? left.dueAt : right.dueAt,
                anchorAt: leftWins ? left.anchorAt : right.anchorAt
            });
        }
        if (left.wait || right.wait) {
            // 等待期限取等待成员的最早就绪时刻（Rust: waits.min()；
            // _minDue 的 0=无限语义：非等待成员的 dueAt 不约束）。
            // anchorAt 经 _minAnchor 折叠（0=无锚不约束 min）——OR 等待态
            // 的锚点在 Rust 侧整体丢弃（anchors: Vec::new()），此处保留仅
            // 为求值栈内的保守载荷；注册边界已禁嵌套延时，该值不会再被
            // Delay 消费，也不参与根位判定（_evaluateHook 只读
            // cancel/wait/value/dueAt）。
            return EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: _minDue(left.wait ? left.dueAt : 0, right.wait ? right.dueAt : 0),
                anchorAt: _minAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if (left.cancel && right.cancel) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _hasSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (bool)
    {
        return _s.signals[planId][orderId][_signalKey(sourceId, signalId)].exists;
    }

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function _isSignalSubmitterAuthorized(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) private view returns (bool) {
        if (signalId == bytes32(0) || submitter == address(0)) {
            return false;
        }
        return _hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter);
    }

    function _hasExplicitSignalAuthorization(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) private view returns (bool) {
        if (signalId == bytes32(0) || submitter == address(0)) {
            return false;
        }
        return _s.signalAuthorizations[planId][orderId][_signalKey(sourceId, signalId)][submitter].exists;
    }

    function _requireActiveStageExecutorByStage(bytes32 planId, bytes32 orderId, bytes32 stageId, address submitter)
        private
        view
    {
        if (stageId == bytes32(0)) {
            return;
        }
        ActiveStageExecutorPatch storage activePatch = _s.activeStageExecutorPatches[planId][orderId][stageId];
        if (activePatch.exists && submitter != activePatch.executor) {
            revert UnauthorizedStageExecutor(orderId, stageId, submitter, activePatch.executor);
        }
    }

    /// 属主自证验证：声明非零阶段即必须与被查事实键一致、且验过能力叶
    /// (stageId, sourceId, signalId, relation=0) 在本 plan 能力树内的成员
    /// 资格。键不一致或证明验不过都响亮回滚（InvalidFactAttribution），
    /// 不静默降级——词表闸与物化门的"验过/未声明"必须对调用方可区分。
    /// 未声明（stageId == 0）返回 0。仅 relation=0 的能力是事实键的属主
    /// 声明（编译器 E16 不变量：同一 relation=0 键唯一属主）。
    function _verifiedFactOwner(
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId,
        FactAttribution calldata attribution
    ) private view returns (bytes32 stageId) {
        if (attribution.stageId == bytes32(0)) {
            return bytes32(0);
        }
        if (attribution.sourceId != sourceId || attribution.signalId != signalId) {
            revert InvalidFactAttribution(planId, sourceId, signalId, attribution.stageId);
        }
        if (!IUVPPlanMetadataModule(_s.planMetadataModule)
                .verifySignalCapability(
                    planId,
                    attribution.stageId,
                    sourceId,
                    signalId,
                    SIGNAL_TARGET_CURRENT_ORDER,
                    attribution.capabilityProof
                )) {
            revert InvalidFactAttribution(planId, sourceId, signalId, attribution.stageId);
        }
        return attribution.stageId;
    }

    /// 属主阶段解析：携证属主优先；无证时仅零词表 plan 允许 source==stage
    /// 回退（sourceId 本身是 plan 阶段时以阶段自居——手工 plan 的口径）。
    /// 有词表的 plan 事实未携证即响亮回滚（InvalidSignalCapability，与提交/
    /// 出生路径同口径）：词表内撞名的源/阶段不能借回退免证自证属主，否则
    /// 同意链的 origin 阶段执行者腿可被加宽（UVP-08 同意门绕过）。
    /// 零词表回退后仍无阶段则 0（不绑定物化/executor 门）。
    function _resolveSourceStage(
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId,
        FactAttribution calldata attribution
    ) private view returns (bytes32 stageId) {
        stageId = _verifiedFactOwner(planId, sourceId, signalId, attribution);
        if (stageId != bytes32(0)) {
            return stageId;
        }
        if (_hasCapabilityVocabulary(planId)) {
            revert InvalidSignalCapability(planId, sourceId, signalId);
        }
        if (_isPlanStage(planId, sourceId)) {
            stageId = sourceId;
        }
    }

    /// plan 是否声明了任何能力词表（非空能力树）。零 capability 的手工/
    /// 触发型 plan 词表闸全线放行。
    function _hasCapabilityVocabulary(bytes32 planId) private view returns (bool) {
        if (_s.planMetadataModule == address(0)) {
            return false;
        }
        return IUVPPlanMetadataModule(_s.planMetadataModule).hasCapabilityVocabulary(planId);
    }

    function _recoverSignalSubmitter(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidSignalSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }

    function _minDue(uint64 left, uint64 right) private pure returns (uint64) {
        if (left == 0) {
            return right;
        }
        if (right == 0 || left < right) {
            return left;
        }
        return right;
    }

    function _maxDue(uint64 left, uint64 right) private pure returns (uint64) {
        return left > right ? left : right;
    }

    function _maxAnchor(uint64 left, uint64 right) private pure returns (uint64) {
        return left > right ? left : right;
    }

    function _minAnchor(uint64 left, uint64 right) private pure returns (uint64) {
        if (left == 0) {
            return right;
        }
        if (right == 0 || left < right) {
            return left;
        }
        return right;
    }
}
