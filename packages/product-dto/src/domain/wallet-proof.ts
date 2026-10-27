/**
 * 钱包证明（wallet proof）wire DTO 单源：身份=钱包，一次 personal_sign 换短时效
 * token；没有账户/登录/地址锚定字段。
 */

export const WALLET_PROOF_SESSION_HEADER = "x-uvp-store-session";

export interface WalletProofChallengeView {
  readonly nonce: string;
  readonly wallet: string;
  readonly message: string;
  readonly issuedAt: string;
  readonly expiresAt: string;
}

export interface WalletSessionView {
  readonly wallet: string;
  readonly expiresAt: string;
}

export interface WalletProofVerifyResult {
  readonly token: string;
  readonly session: WalletSessionView;
}
