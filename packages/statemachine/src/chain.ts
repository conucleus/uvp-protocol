import { replayWithUvpCore } from "@uvp-eth/hook-core";

export type HexString = `0x${string}`;

export type ChainModeEvent =
  | ChainPlanRegisteredEvent
  | ChainOrderRegisteredEvent
  | ChainOrderMaterializedEvent
  | ChainOrderTriggeredEvent
  | ChainOrderLinkedEvent
  | ChainSignalSubmittedEvent
  | ChainStageMaterializedEvent
  | ChainHookStatusChangedEvent
  | ChainHookReadyEvent
  | ChainTimerPokedEvent;

export type ChainModeInputEvent =
  | ChainPlanRegisteredEvent
  | ChainOrderRegisteredEvent
  | ChainSignalSubmittedEvent
  | ChainTimerPokedEvent;

export type ChainModeExpectedEvent = ChainHookStatusChangedEvent | ChainHookReadyEvent;
export type ChainObservableHookStatus = "wait" | "cxl";
export type ChainOracleHookStatus = "init" | "wait" | "ready" | "cxl";

export interface ChainEventBase {
  readonly eventName: string;
  readonly blockNumber: number;
  readonly transactionIndex?: number;
  readonly logIndex: number;
  readonly transactionHash: `0x${string}`;
  readonly contractAddress?: `0x${string}`;
}

export interface ChainPlanRegisteredEvent extends ChainEventBase {
  readonly eventName: "PlanRegistered";
  readonly plan: ChainOraclePlan;
}

export interface ChainOraclePlan {
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly compiledHooks: readonly ChainOracleHook[];
  readonly dependencyIndex: Record<HexString, readonly HexString[]>;
}

export interface ChainOracleHook {
  readonly hookId: HexString;
  readonly stageId: HexString;
  readonly stageIdentifier: string;
  readonly hookName: string;
  /** order birth 触发种类；HookReady 发出由 emitReady 表达。 */
  readonly orderTriggerKind: "none" | "mint" | "dock";
  readonly emitReady: boolean;
  readonly instructions: readonly ChainOracleInstruction[];
}

export type ChainOracleInstruction =
  | {
      readonly op: "SIGNAL";
      readonly sourceId: HexString;
      readonly signalId: HexString;
      readonly signalKey: HexString;
    }
  | {
      readonly op: "NOT";
    }
  | {
      readonly op: "AND" | "OR";
      readonly arity: number;
    }
  | {
      readonly op: "DELAY";
      readonly delaySeconds: number;
    };

export interface ChainOrderRegisteredEvent extends ChainEventBase {
  readonly eventName: "OrderRegistered";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly registeredAt: string;
}

export interface ChainOrderMaterializedEvent extends ChainEventBase {
  readonly eventName: "OrderMaterialized";
  readonly orderId: string;
  readonly planId: HexString;
  readonly stageId: string;
}

export interface ChainOrderTriggeredEvent extends ChainEventBase {
  readonly eventName: "OrderTriggered";
  /**
   * Frozen payload (v0.10 ABI): OrderTriggered(bytes32 indexed orderId,
   * bytes32 indexed planId, bytes32 indexed triggerStageId, bytes32
   * triggerHookId, bytes32 sourceId, bytes32 signalId, address submitter).
   * triggerHookId mirrors StageMaterialized: indexers/replayers must locate
   * the birth hook's evaluation semantics without re-deriving them from the
   * plan (stageId alone is ambiguous for multi-hook stages).
   */
  readonly orderId: string;
  readonly planId: HexString;
  readonly triggerStageId: string;
  readonly triggerHookId: string;
  readonly sourceId: string;
  readonly signalId: string;
  readonly submitter: string;
}

export interface ChainOrderLinkedEvent extends ChainEventBase {
  readonly eventName: "OrderLinked";
  /**
   * Frozen payload (UVPOrderLinkModule): OrderLinked(bytes32 indexed
   * triggeredOrderId, bytes32 indexed triggerOriginOrderId, bytes32 indexed
   * triggerStageId, bytes32 planId, bytes32 originPlanId, bytes32
   * originSourceId, bytes32 originSignalId). The composite (planId, orderId)
   * identities must ride on every link event — two plans with the same
   * numeric order ids produce byte-different events only through these keys.
   */
  readonly planId: HexString;
  readonly triggeredOrderId: string;
  readonly triggerOriginOrderId: string;
  readonly originPlanId: HexString;
  readonly triggerStageId: string;
  readonly originSourceId: string;
  readonly originSignalId: string;
}

export interface ChainSignalSubmittedEvent extends ChainEventBase {
  readonly eventName: "SignalSubmitted";
  /** Frozen v0.10 identity: signal ownership is scoped by plan and order. */
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly signalKey: HexString;
  readonly senderId: string;
  readonly submittedAt: string;
  readonly source?: string;
  readonly stageIdentifier?: string;
  readonly signalName?: string;
  readonly idempotencyKey?: string;
  readonly traceId?: string;
  readonly payloadRef?: string;
}

export interface ChainStageMaterializedEvent extends ChainEventBase {
  readonly eventName: "StageMaterialized";
  readonly planId: HexString;
  readonly orderId: string;
  readonly stageId: string;
  readonly triggerHookId: string;
  readonly sourceId: string;
  readonly signalId: string;
}

export interface ChainHookStatusChangedEvent extends ChainEventBase {
  readonly eventName: "HookStatusChanged";
  /**
   * Frozen payload (v0.10 ABI): HookStatusChanged(bytes32 indexed planId,
   * bytes32 indexed orderId, bytes32 indexed hookId, uint8 previousStatus,
   * uint8 newStatus, uint64 dueAt).
   * zhixuId below is indexer enrichment joined from the order registration,
   * never part of the emitted event.
   */
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly previousStatus: ChainOracleHookStatus;
  readonly newStatus: ChainOracleHookStatus;
  readonly dueAt?: string;
}

export interface ChainHookReadyEvent extends ChainEventBase {
  readonly eventName: "HookReady";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly stageIdentifier: string;
  readonly hookName: string;
}

export interface ChainTimerPokedEvent extends ChainEventBase {
  readonly eventName: "TimerPoked";
  /**
   * Frozen payload (v0.10 ABI): TimerPoked(bytes32 indexed planId,
   * bytes32 indexed orderId, bytes32 indexed hookId, uint64 dueAt).
   * zhixuId is indexer enrichment from the order registration. pokedAt is the
   * block timestamp of the poke transaction (also enrichment); the replay
   * oracle consumes it as the evaluation clock for this tick.
   */
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly dueAt: string;
  readonly pokedAt: string;
}

export type ChainHookObservation = ChainHookReadyObservation | ChainHookStatusChangedObservation;

export interface ChainHookReadyObservation {
  readonly eventName: "HookReady";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly stageIdentifier: string;
  readonly hookName: string;
}

export interface ChainHookStatusChangedObservation {
  readonly eventName: "HookStatusChanged";
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly hookId: string;
  readonly status: ChainObservableHookStatus;
  readonly dueAt?: string;
}

export interface ChainReplayOptions {
  readonly sort?: boolean;
}

export interface ChainReplayResult {
  readonly state: ChainOracleState;
  readonly expected: readonly ChainHookObservation[];
  readonly observed: readonly ChainHookObservation[];
  readonly mismatches: readonly ChainReplayMismatch[];
}

export interface ChainOracleState {
  readonly plans: Record<string, ChainOraclePlan>;
  readonly orders: Record<string, ChainOracleOrderState>;
}

export interface ChainOracleOrderState {
  readonly planId: HexString;
  readonly zhixuId: string;
  readonly orderId: string;
  readonly signals: Record<string, ChainOracleSignalRecord>;
  readonly hookStatuses: Record<string, ChainOracleHookRuntime>;
  readonly materializedStages: Record<string, boolean>;
}

export interface ChainOracleSignalRecord {
  readonly eventId: string;
  readonly sourceId: HexString;
  readonly signalId: HexString;
  readonly signalKey: HexString;
  readonly senderId: string;
  readonly submittedAt: string;
  readonly transactionIndex?: number;
}

export interface ChainOracleHookRuntime {
  readonly status: ChainOracleHookStatus;
  readonly dueAt?: string;
  readonly readyEmitted: boolean;
}

/**
 * 原生回放（uvp-core replay）的 mismatch 载荷键为
 * hook/occurrence/reason（+ 按需 expected/observed），不含 index；
 * index 仅由需要位置编号的调用方自行附加。
 */
export interface ChainReplayMismatch {
  readonly index?: number;
  readonly reason: "missing-observed" | "unexpected-observed" | "semantic-mismatch";
  readonly expected?: ChainHookObservation;
  readonly observed?: ChainHookObservation;
}

export class ChainReplayMismatchError extends Error {
  readonly mismatches: readonly ChainReplayMismatch[];

  constructor(mismatches: readonly ChainReplayMismatch[]) {
    super(`chain replay mismatched ${mismatches.length} hook observation(s)`);
    this.name = "ChainReplayMismatchError";
    this.mismatches = mismatches;
  }
}

/**
 * The single exported replay entry point always validates strictly: any
 * mismatch between expected and observed hook observations throws
 * {@link ChainReplayMismatchError}. There is no option (and no exported
 * wrapper bypass) that yields a never-throwing replay; callers who need to
 * inspect raw mismatches can catch the error and read its `mismatches` field.
 *
 * Order-link birth facts are derived by the native oracle itself (a HookReady
 * for an order-trigger hook the oracle could not derive by evaluation is
 * accepted as the authoritative on-chain birth statement), so this wrapper
 * only projects the frozen v0.10 event shape and delegates.
 *
 * pokeTimer 合约守门镜像（UVPStateMachine.pokeTimer）：非 Wait 态 revert
 * TimerNotWaiting、未到期（dueAt 缺失或 pokedAt < dueAt）revert
 * TimerNotDue——两类交易在链上根本无法产出 TimerPoked 事件。回放喂给
 * native 层的流必须先按这两个条件过滤，否则含不可产生事件的流（历史上
 * 的 golden fixture 就携带过"已 cxl 的 hook 又被 poke"的序列）会把合约
 * 不可能的状态变迁喂进求值器。
 */
export function replayChainEvents(
  events: readonly ChainModeEvent[],
  options: ChainReplayOptions = {}
): ChainReplayResult {
  // 守门状态按事件序（options.sort 时的确定性序）跟踪；状态转移事件的
  // 缺席意味着"无法证明该 poke 合法"，按 fail-closed 过滤。
  const ordered =
    options.sort === true ? [...events].sort(compareChainEvents) : events;
  const pokeGate = new TimerPokeGate();
  const normalized: readonly OracleFeedEvent[] = ordered
    .map((event) => {
      const pokeAllowed = pokeGate.admit(event);
      if (!pokeAllowed) {
        return undefined;
      }
      pokeGate.track(event);
      return normalizeChainEventForOracle(event);
    })
    .filter((event): event is OracleFeedEvent => event !== undefined);
  const result = replayWithUvpCore({
    events: normalized,
    options: {
      ...options,
      // The native layer collects structured mismatches instead of throwing
      // its own opaque error; this wrapper converts them into an explicit
      // throw so the exported surface cannot observe a lenient replay.
      strict: false
    }
  }) as ChainReplayResult;
  if (result.mismatches.length > 0) {
    throw new ChainReplayMismatchError(result.mismatches);
  }

  return result;
}

interface TrackedHookRuntime {
  status: ChainOracleHookStatus;
  dueAt?: string;
}

/**
 * pokeTimer 守门的逐 (planId, orderId, hookId) 状态镜像：从 HookStatusChanged
 * （含被观察面过滤的 →ready/→init 转移，此处仍须消费）与 HookReady 推导
 * hook 当前状态与 dueAt。到期判据只取守门推导值（合约 pokeTimer 读的是
 * 存储里的 dueAt）：TimerPoked 只有在"当前态 = wait 且 pokedAt ≥ 守门
 * dueAt"时才可能存在于链上。事件自带的 dueAt（frozen v0.10 ABI 的非索引
 * uint64 字段；冻结前形状的喂给流可能缺省）是待核验的声称值——在场时
 * 必须与守门值逐点一致，毒事件自报更小的 dueAt 无法伪造"已到期"；缺省
 * 时不影响判定，守门值已完整覆盖 TimerNotWaiting/TimerNotDue 两道闸。
 * 无法证明合法（状态未知、守门 dueAt 缺失、声称值不一致、时间戳不可
 * 解析）一律按不可能过滤。
 */
class TimerPokeGate {
  private readonly runtimes = new Map<string, TrackedHookRuntime>();

  /** 事件是否可进入 native 喂给层（仅 TimerPoked 会被拒）。 */
  admit(event: ChainModeEvent): boolean {
    if (event.eventName !== "TimerPoked") {
      return true;
    }
    const runtime = this.runtimes.get(runtimeKey(event));
    if (runtime === undefined || runtime.status !== "wait" || runtime.dueAt === undefined) {
      return false;
    }
    const trackedDueAt = parseTimestamp(runtime.dueAt);
    const pokedAt = parseTimestamp(event.pokedAt);
    if (trackedDueAt === undefined || pokedAt === undefined) {
      return false;
    }
    if (event.dueAt !== undefined) {
      const eventDueAt = parseTimestamp(event.dueAt);
      if (eventDueAt === undefined || eventDueAt !== trackedDueAt) {
        return false;
      }
    }
    return pokedAt >= trackedDueAt;
  }

  /** 消费事件推进守门状态（对所有放行事件调用）。 */
  track(event: ChainModeEvent): void {
    switch (event.eventName) {
      case "HookStatusChanged": {
        // newStatus 已由 normalize 边界校验为 frozen v0.10 状态集；此处
        // 直接消费（→ready/→init 转移虽被观察面过滤，守门仍须感知）。
        const newStatus = event.newStatus;
        if (newStatus === undefined) {
          return;
        }
        this.runtimes.set(runtimeKey(event), {
          status: newStatus,
          ...(event.dueAt === undefined || newStatus !== "wait"
            ? {}
            : { dueAt: event.dueAt }),
        });
        return;
      }
      case "HookReady": {
        this.runtimes.set(runtimeKey(event), { status: "ready" });
        return;
      }
      default:
        return;
    }
  }
}

function runtimeKey(event: {
  readonly planId: HexString;
  readonly orderId: string;
  readonly hookId: string;
}): string {
  return `${event.planId}::${event.orderId}::${event.hookId}`;
}

function parseTimestamp(value: string | undefined): number | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const millis = Date.parse(value);
  return Number.isNaN(millis) ? undefined : millis;
}

export function chainEventId(event: ChainEventBase): string {
  return `${event.blockNumber}:${event.logIndex}:${event.transactionHash}`;
}

type ProjectedHookStatusChangedEvent = Omit<ChainHookStatusChangedEvent, "previousStatus" | "newStatus"> & {
  readonly status: "wait" | "cxl";
};

type OracleFeedEvent = ChainModeEvent | ProjectedHookStatusChangedEvent;

/**
 * The replay oracle consumes the projected observation shape (single
 * `status`), while the frozen v0.10 chain event carries
 * previousStatus/newStatus. This adapter is the formal boundary between the
 * two contracts: v0.10 events are projected onto newStatus, and
 * HookStatusChanged events with a non-observable new status ("ready"/"init")
 * are FILTERED OUT — the oracle's observed face only ever produces wait/cxl
 * status observations (ready transitions are observed through HookReady), so
 * feeding the →Ready/→Init status changes the contract emits alongside
 * HookReady would surface as guaranteed missing-observed mismatches.
 * A HookStatusChanged event without a valid newStatus — or with a status
 * value outside the frozen v0.10 set {init, wait, ready, cxl} — violates the
 * frozen contract and fails loudly instead of being silently dropped.
 */
function normalizeChainEventForOracle(event: ChainModeEvent): OracleFeedEvent | undefined {
  if (event.eventName === "HookStatusChanged") {
    if (!("newStatus" in event) || typeof event.newStatus !== "string") {
      throw new Error(
        `HookStatusChanged ${event.hookId} is missing a valid newStatus; frozen v0.10 events must carry previousStatus/newStatus`
      );
    }
    if (event.newStatus !== "wait" && event.newStatus !== "cxl") {
      if (event.newStatus === "ready" || event.newStatus === "init") {
        return undefined;
      }
      throw new Error(
        `HookStatusChanged ${event.hookId} carries unknown newStatus ${JSON.stringify(event.newStatus)}; frozen v0.10 statuses are init/wait/ready/cxl`
      );
    }
    const { previousStatus: _previousStatus, newStatus: _newStatus, ...rest } = event;
    return { ...rest, status: event.newStatus };
  }
  return { ...event };
}

export function compareChainEvents(a: ChainEventBase, b: ChainEventBase): number {
  if (a.blockNumber !== b.blockNumber) {
    return a.blockNumber - b.blockNumber;
  }
  // transactionIndex 的确定性缺席规则：缺失视为排在末位（+∞），且同维度
  // 一致应用。若只在"双方都有且不等"时才比该维度、混合有无时直接落到
  // logIndex/txHash，比较不再传递——同一事件集按不同两两比较会得出矛盾
  // 序（如 A(无 txIdx, log 5) == B(txIdx 0, log 5)、B < C(txIdx 1)、
  // A > C），排序结果依赖比较顺序。缺席映射到 +∞ 后，enrichment 缺
  // txIdx 的事件全部排在同块已 enrichment 事件之后，顺序仍然确定。
  const aTxIndex = a.transactionIndex ?? Number.POSITIVE_INFINITY;
  const bTxIndex = b.transactionIndex ?? Number.POSITIVE_INFINITY;
  if (aTxIndex !== bTxIndex) {
    return aTxIndex < bTxIndex ? -1 : 1;
  }
  if (a.logIndex !== b.logIndex) {
    return a.logIndex - b.logIndex;
  }
  // 确定性字节序平局裁决：localeCompare 依赖 ICU/locale，不得参与任何
  // 会进 canonical 产物的排序（同仓 hook-plan.ts 明文禁止）。
  return compareTxHashByCodeUnit(a.transactionHash, b.transactionHash);
}

function compareTxHashByCodeUnit(
  left: `0x${string}`,
  right: `0x${string}`,
): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
