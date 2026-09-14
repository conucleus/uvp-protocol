// 签名闸门单源（治理审计 §1.1 P1-1）：合并三处已漂移的签名前校验——
// order-app injectedWallet（assertTypedDataEnvelopeMatchesProtocol）、
// zhixu-store product/wallet（validateTypedDataForSigning）、
// executor-kit product（signPreparedSignalContainer 的信封校验段）。
//
// 本模块只做判定（返回 reason），不包装错误文案：浏览器端
// TypedDataMismatchError/InjectedWalletError 与私钥端 ValidationError 等
// 宿主错误形态各自把 reason 映射为本端文案，判定语义不再分叉。
//
// 收敛的最强校验集（三处并集）：
// - primaryType 锚定 + types[primaryType] 必须是非空字段数组；
// - domain 四要素：name 恒比对、version/chainId/verifyingContract 提供预期
//   时比对（chainId 与 verifyingContract 本身必须形状合法）；
// - message 签名者字段（默认 submitter）与 expectedSubmitter 一致；
// - preparedSubmitters 数组交叉核对（防换签名对象——prepared 记录声明
//   的提交方也必须一致；undefined 条目跳过，兼容缺省字段）；
// - connectedAddress（浏览器钱包当前地址）与签名者一致（可选，兼容
//   executor-kit 私钥路径）。

/** 签名者字段在 message 中的键名；默认 "submitter"，dock permit 类信封为 "selector"。 */
export type TypedDataSignerField = "submitter" | "selector" | (string & {});

/** 签名前校验的预期集合；除 primaryType/domainName/submitter 外均可选。 */
export interface TypedDataSigningExpectation {
  /** 协议 primaryType，例如 UVPStateMachineSignal。 */
  readonly primaryType: string;
  /** EIP-712 domain.name 预期值（恒比对）。 */
  readonly domainName: string;
  /** EIP-712 domain.version 预期值；不提供时不比对。 */
  readonly domainVersion?: string;
  /** 期望的部署链 ID；提供时与 domain.chainId 比对。domain.chainId 本身必须可解析为正整数。 */
  readonly chainId?: number;
  /** 期望的部署地址；提供时与 domain.verifyingContract 比对（不区分大小写）。 */
  readonly verifyingContract?: string;
  /** 期望的签名者（message 签名者字段必须与之小写一致）。 */
  readonly submitter: string;
  /** message 中承载签名者的字段名；默认 "submitter"。 */
  readonly submitterField?: TypedDataSignerField;
  /**
   * prepared 记录里声明的 submitter（如 prepared.submitter /
   * humanSummary.submitter）。每个非 undefined 条目都必须与 message 签名者
   * 一致，防止换签名对象。
   */
  readonly preparedSubmitters?: readonly (string | undefined)[];
  /** 实际连接/实际用于签名的钱包地址（浏览器路径）；提供时参与比对。 */
  readonly connectedAddress?: string;
}

/** 拒绝原因枚举：宿主按 reason 映射本端文案，不依赖英文 detail。 */
export type TypedDataSigningMismatchReason =
  | "not-typed-data"
  | "primary-type"
  | "primary-type-fields"
  | "domain-shape"
  | "domain-name"
  | "domain-version"
  | "domain-chain-id"
  | "domain-verifying-contract"
  | "message-shape"
  | "signer-field"
  | "signer-not-connected"
  | "signer-not-expected"
  | "signer-not-prepared";

export type TypedDataSigningCheck =
  | { readonly ok: true }
  | {
      readonly ok: false;
      readonly reason: TypedDataSigningMismatchReason;
      /** 被拒时的关键事实值（原始形态，无格式承诺），仅供日志/文案拼装。 */
      readonly detail?: string;
    };

const EVM_ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/u;

/**
 * 签名前校验 typedData 信封：primaryType、domain（name/version/chainId/
 * verifyingContract）与 message 签名者必须与预期一致，任何篡改都判定为
 * 拒绝签名。只做判定不抛错——调用方负责把 reason 映射为宿主错误与文案。
 */
export function validateTypedDataForSigning(
  typedData: unknown,
  expectation: TypedDataSigningExpectation,
): TypedDataSigningCheck {
  const record = asRecord(typedData);
  if (!record) {
    return { ok: false, reason: "not-typed-data" };
  }

  if (record.primaryType !== expectation.primaryType) {
    return {
      ok: false,
      reason: "primary-type",
      detail: String(record.primaryType),
    };
  }

  const domain = asRecord(record.domain);
  if (!domain) {
    return { ok: false, reason: "domain-shape" };
  }
  if (domain.name !== expectation.domainName) {
    return { ok: false, reason: "domain-name", detail: String(domain.name) };
  }
  if (
    expectation.domainVersion !== undefined &&
    domain.version !== expectation.domainVersion
  ) {
    return {
      ok: false,
      reason: "domain-version",
      detail: String(domain.version),
    };
  }
  const chainIdNumber = parseChainId(domain.chainId);
  if (chainIdNumber === undefined) {
    return {
      ok: false,
      reason: "domain-chain-id",
      detail: String(domain.chainId),
    };
  }
  if (expectation.chainId !== undefined && chainIdNumber !== expectation.chainId) {
    return {
      ok: false,
      reason: "domain-chain-id",
      detail: String(chainIdNumber),
    };
  }
  const verifyingContract = domain.verifyingContract;
  if (typeof verifyingContract !== "string" || !EVM_ADDRESS_RE.test(verifyingContract)) {
    return {
      ok: false,
      reason: "domain-verifying-contract",
      detail: String(verifyingContract),
    };
  }
  if (
    expectation.verifyingContract !== undefined &&
    verifyingContract.toLowerCase() !==
      expectation.verifyingContract.trim().toLowerCase()
  ) {
    return {
      ok: false,
      reason: "domain-verifying-contract",
      detail: verifyingContract,
    };
  }

  // types[primaryType] 必须是非空字段数组：信封被剥离字段定义时（部分
  // 钱包/中转层会改写 types）在调钱包前拒绝。
  const types = asRecord(record.types);
  const primaryFields = types?.[expectation.primaryType];
  if (!Array.isArray(primaryFields) || primaryFields.length === 0) {
    return { ok: false, reason: "primary-type-fields" };
  }

  const message = asRecord(record.message);
  if (!message) {
    return { ok: false, reason: "message-shape" };
  }
  const signerField = expectation.submitterField ?? "submitter";
  const signer = message[signerField];
  if (typeof signer !== "string" || !EVM_ADDRESS_RE.test(signer)) {
    return {
      ok: false,
      reason: "signer-field",
      detail: String(signer),
    };
  }
  if (
    expectation.connectedAddress !== undefined &&
    signer.toLowerCase() !== expectation.connectedAddress.trim().toLowerCase()
  ) {
    return { ok: false, reason: "signer-not-connected", detail: signer };
  }
  if (signer.toLowerCase() !== expectation.submitter.trim().toLowerCase()) {
    return { ok: false, reason: "signer-not-expected", detail: signer };
  }
  for (const preparedSubmitter of expectation.preparedSubmitters ?? []) {
    if (preparedSubmitter === undefined) {
      continue;
    }
    if (signer.toLowerCase() !== preparedSubmitter.trim().toLowerCase()) {
      return {
        ok: false,
        reason: "signer-not-prepared",
        detail: preparedSubmitter,
      };
    }
  }

  return { ok: true };
}

/**
 * 钱包"用户拒绝"判定（超集统一）：EIP-1193 code 4001，或错误消息含
 * reject/denied/cancel（大小写不敏感）。三端取消文案与判定正则曾各自
 * 漂移（order-app 认 denied/cancel、zhixu-store 只认 reject），此处收敛
 * 为超集；面向用户的文案仍由宿主自定义。
 */
export function isUserRejectedRequestError(error: unknown): boolean {
  if (typeof error !== "object" || error === null) {
    return false;
  }
  const candidate = error as { readonly code?: unknown; readonly message?: unknown };
  return (
    candidate.code === 4001 ||
    /reject|denied|cancel/i.test(String(candidate.message ?? ""))
  );
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

/** domain.chainId 可能以 number 或十进制字符串到达；解析失败返回 undefined。 */
function parseChainId(value: unknown): number | undefined {
  const parsed =
    typeof value === "number"
      ? value
      : typeof value === "string" && /^\d+$/u.test(value.trim())
        ? Number(value.trim())
        : Number.NaN;
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined;
}
