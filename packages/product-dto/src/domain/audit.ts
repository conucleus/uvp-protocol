/**
 * app 审计读面 DTO 单源：只暴露白名单字段（谁在何时对哪个订单做了什么），
 * token/签名原文/联系方式/正文永不进入审计记录。
 */

export const AUDIT_ACTIONS = [
  "draft.create",
  "draft.update",
  "invite.create",
  "invite.accept",
  "invite.reject",
  "invite.revoke",
  "order.attach",
  "evidence.upload",
] as const;

export type AuditAction = (typeof AUDIT_ACTIONS)[number];

export interface AuditEventView {
  readonly eventId: string;
  readonly chainId?: number;
  readonly actorWallet: string;
  readonly action: AuditAction;
  readonly orderId?: string;
  readonly draftId?: string;
  readonly inviteId?: string;
  readonly ref?: string;
  readonly payloadHash?: string;
  readonly createdAt: string;
  readonly requestId?: string;
}
