/**
 * 写动作 EIP-712 契约的 DTO 出口：schema/字段表/typehash/构造全在
 * @uvp-eth/protocol-bindings，这里只 re-export，不保留第二份。
 */

export {
  UVP_APP_BACKEND_DOMAIN_NAME,
  UVP_APP_BACKEND_DOMAIN_VERSION,
  UVP_APP_WRITE_ACTIONS,
  UVP_APP_WRITE_PRIMARY_TYPES,
  UVP_APP_WRITE_FIELDS,
  UVP_APP_WRITE_TYPE_HASHES,
  UVP_APP_WRITE_RESOURCE_FIELDS,
  buildUVPAppBackendDomain,
  buildUVPAppWriteTypedData,
  hashAppWritePayload,
  type UvpAppWriteAction,
  type UvpAppWritePrimaryType,
  type UvpAppBackendDomain,
  type UvpAppWriteTypedData,
  type BuildUVPAppWriteTypedDataInput,
} from "@uvp-eth/protocol-bindings";

export interface WriteSignatureEnvelope {
  readonly scheme: "eip712";
  readonly signature: string;
  readonly nonce: string;
  readonly deadline: string;
}
