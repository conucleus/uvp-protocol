import {
  type OrderPermissionTableEntryDTO,
  type ParticipantAddOnManifestDTO,
  type ParticipantDTO,
  type ProductCatalogDTO,
  type ProductOrderDTO,
  type ProductResourceAccessPolicyDTO,
  type ProductResourceManifestDTO,
  type ProductResourceRequirementDTO,
  type ProductTaskDTO,
  type RoleSlotDTO,
  type SlotCapabilityPluginDTO,
  type StoreProductSchemaDTO,
  type ZhixuDetailDTO,
  type ZhixuStageDTO
} from "../domain/index.js";

export const PHASE2_CUSTOMS_ZHIXU_ID = "phase2-customs-completion";
export const PHASE2_CUSTOMS_ORDER_ID = "order-phase2-customs-001";

export const phase2CustomsStageIds = {
  buyerSelectCustomsExecutor: "buyer.select-customs-executor",
  buyerPublishCustomsResources: "buyer.publish-customs-resources",
  customsComplete: "customs-complete"
} as const;

export const phase2CustomsRoleSlotIds = {
  buyerSelector: "buyer-selector",
  buyerResourceController: "buyer-resource-controller",
  customsExecutor: "customs-executor"
} as const;

export const phase2CustomsActionIds = {
  applyExecutorPatch: "buyer-selector.apply-executor-patch",
  applyResourcePatch: "buyer-resource-controller.apply-resource-patch",
  submitCustomsComplete: "customs-executor.submit-customs-complete"
} as const;

export const phase2CustomsResourceKeys = {
  customsDeclarationPdf: "customs_declaration_pdf"
} as const;

export const phase2CustomsSignalIds = {
  orderRegistered: "registered",
  executorSelected: "buyer.select-customs-executor.executor_selected",
  resourcesPublished: "buyer.publish-customs-resources.resources_published",
  customsCompleteConfirmed: "customs-complete.confirm_stage"
} as const;

export const phase2CustomsInitialTriggerSource = "order";

export const phase2CustomsWallets = {
  buyer: "0x1111111111111111111111111111111111111111",
  customsExecutor: "0x2222222222222222222222222222222222222222"
} as const;

export const phase2CustomsPlanIds = {
  planId: "0x336d9b556f7ffa00c83f49600554819055a4a3b300f82abca70b401f6b161ddc",
  planHash: "0xa8f20f1927a1e34dad69907abccba2e7a1556dd77e9cc5bf4bbfa0df305275ef",
  artifactHash: "0x7f663c7ffaf55f72f4e17cfe0368f3b7d2a982e39b992ea9c78d80a065f8067d"
} as const;

export const phase2CustomsResourceManifest: ProductResourceManifestDTO = {
  schemaVersion: "uvp-resource-manifest-v1",
  orderId: PHASE2_CUSTOMS_ORDER_ID,
  targetStageId: phase2CustomsStageIds.customsComplete,
  resourceKey: phase2CustomsResourceKeys.customsDeclarationPdf,
  visibility: "protected",
  manifestURI: "uvp-resource://phase2/customs-declaration-pdf/v1",
  manifestHash: "0xdac56fa990b9253da7a5773a657adbe3d170f1b428169858b3f2545b2d562405",
  policyHash: "0xc7ff3c7a9a1d12181aba887281be556416beedb1e600e132e57e1cfddf78e490",
  ciphertextHash: "0x3cf67bf9b98b52d4ba6c00f6d26f0541098fca706ff68707a7c59c7284dd64b5",
  storageCID: "bafyuvpphase2customsdeclarationpdfciphertext",
  recipientEnvelopeRoot: "0xf4d441f65f7ef2b91f664d4bd0c14c980f35e5f0e5f481f678d5f7e59a43d071",
  createdBy: phase2CustomsWallets.buyer,
  createdAt: "2026-05-01T00:00:00.000Z"
};

const phase2CustomsResourcePolicy: ProductResourceAccessPolicyDTO = {
  visibility: "protected",
  readers: [
    { kind: "role", label: "买家", value: phase2CustomsRoleSlotIds.buyerResourceController },
    { kind: "role", label: "报关履约者", value: phase2CustomsRoleSlotIds.customsExecutor }
  ],
  writers: [
    { kind: "role", label: "买家资源请求方", value: phase2CustomsRoleSlotIds.buyerResourceController }
  ],
  controllers: [
    { kind: "wallet", label: "买家钱包", value: phase2CustomsWallets.buyer }
  ],
  policyHash: phase2CustomsResourceManifest.policyHash
};

export const phase2CustomsResourceRequirements: readonly ProductResourceRequirementDTO[] = [
  {
    resourceId: "phase2-customs-declaration-pdf",
    resourceKey: phase2CustomsResourceKeys.customsDeclarationPdf,
    label: "报关单 PDF",
    required: true,
    source: "resource_patch",
    resourceType: "document",
    visibility: "protected",
    sourceStageId: phase2CustomsStageIds.customsComplete,
    description: "报关单以加密内容寻址清单和指纹形式提供，文件原文不写入链上。",
    manifestURI: phase2CustomsResourceManifest.manifestURI,
    manifestHash: phase2CustomsResourceManifest.manifestHash,
    manifest: phase2CustomsResourceManifest,
    accessPolicy: phase2CustomsResourcePolicy,
    accessStatus: {
      state: "available",
      label: "授权参与方可核对资源清单",
      canRead: true,
      canWrite: true,
      canControl: true
    },
    proofRows: [
      { label: "链上事件", value: "StageResourcePatchApplied" },
      { label: "Resource Key", value: phase2CustomsResourceKeys.customsDeclarationPdf },
      { label: "Manifest Hash", value: phase2CustomsResourceManifest.manifestHash },
      { label: "Policy Hash", value: phase2CustomsResourceManifest.policyHash }
    ]
  }
];

export const phase2CustomsStages: readonly ZhixuStageDTO[] = [
  {
    stageId: phase2CustomsStageIds.buyerSelectCustomsExecutor,
    index: 1,
    name: "选择报关履约者",
    evidence: ["履约者元数据指纹"],
    ownerRole: "买家",
    status: "done",
    updatedAt: "2026-05-01T00:05:00.000Z",
    stageKind: "control",
    executorAssignment: "static",
    staticExecutorRoleSlotId: phase2CustomsRoleSlotIds.buyerSelector,
    selectedStageTargets: [phase2CustomsStageIds.customsComplete],
    addOnKind: "stage_executor_patch"
  },
  {
    stageId: phase2CustomsStageIds.buyerPublishCustomsResources,
    index: 2,
    name: "发布报关资源清单",
    evidence: ["资源清单 URI", "资源清单指纹", "访问策略指纹"],
    ownerRole: "买家",
    status: "done",
    updatedAt: "2026-05-01T00:08:00.000Z",
    stageKind: "control",
    executorAssignment: "static",
    staticExecutorRoleSlotId: phase2CustomsRoleSlotIds.buyerResourceController,
    selectedStageTargets: [phase2CustomsStageIds.customsComplete],
    addOnKind: "stage_resource_patch",
    resourceRequirements: phase2CustomsResourceRequirements
  },
  {
    stageId: phase2CustomsStageIds.customsComplete,
    index: 3,
    name: "报关完成",
    evidence: ["报关完成凭证引用", "报关单 PDF 资源清单"],
    ownerRole: "报关履约者",
    status: "done",
    updatedAt: "2026-05-01T00:20:00.000Z",
    stageKind: "business",
    executorAssignment: "selected",
    addOnKind: "submit_signal",
    resourceRequirements: phase2CustomsResourceRequirements
  }
];

const buyerSelectorPlugin = {
  pluginKind: "evidence_submission",
  source: "explicit",
  stageIds: [phase2CustomsStageIds.buyerSelectCustomsExecutor],
  title: "选择报关履约者",
  summary: "买家通过钱包签名为报关完成阶段指定履约者。",
  primaryActionLabel: "选择报关履约者",
  requiredEvidence: ["履约者元数据指纹"]
} satisfies SlotCapabilityPluginDTO;

const buyerResourceControllerPlugin = {
  pluginKind: "evidence_submission",
  source: "explicit",
  stageIds: [phase2CustomsStageIds.buyerPublishCustomsResources],
  title: "发布报关资源清单",
  summary: "买家发布资源清单 URI、清单指纹和访问策略指纹。",
  primaryActionLabel: "发布资源清单",
  requiredEvidence: ["资源清单指纹", "访问策略指纹"]
} satisfies SlotCapabilityPluginDTO;

const customsExecutorPlugin = {
  pluginKind: "delivery_update",
  source: "explicit",
  stageIds: [phase2CustomsStageIds.customsComplete],
  title: "提交报关完成",
  summary: "被选中的报关履约者提交钱包绑定的报关完成信号。",
  primaryActionLabel: "提交报关完成",
  requiredEvidence: ["报关完成凭证引用", "报关单 PDF 资源清单"]
} satisfies SlotCapabilityPluginDTO;

export const phase2BuyerSelectorManifest: ParticipantAddOnManifestDTO = {
  schemaVersion: "participant-addon-manifest.v1",
  manifestId: "phase2:buyer-selector:v1",
  roleSlotId: phase2CustomsRoleSlotIds.buyerSelector,
  addOnKind: "stage_executor_patch",
  title: "选择报关履约者",
  summary: "为报关完成阶段指定可提交完成信号的钱包。",
  stageBindings: [phase2CustomsStageIds.customsComplete],
  pages: [
    {
      pageId: "executor-selection",
      title: "履约者选择",
      sections: [
        {
          sectionId: "executor-patch",
          title: "选择设置",
          components: [
            { componentId: "target-stage", componentKind: "stage_select", inputId: "buyerSelector.targetStageId", label: "目标阶段", required: true, defaultValue: phase2CustomsStageIds.customsComplete },
            { componentId: "mode", componentKind: "select", inputId: "buyerSelector.mode", label: "补丁模式", required: true, defaultValue: "assign", options: [{ value: "assign", label: "指定履约者" }] },
            { componentId: "selector-wallet", componentKind: "wallet", inputId: "buyerSelector.selectorWallet", label: "买家钱包", required: true, defaultValue: phase2CustomsWallets.buyer },
            { componentId: "executor-wallet", componentKind: "wallet", inputId: "buyerSelector.executorWallet", label: "报关履约者钱包", required: true, defaultValue: phase2CustomsWallets.customsExecutor },
            { componentId: "executor-metadata-hash", componentKind: "hash", inputId: "buyerSelector.executorMetadataHash", label: "履约者元数据指纹", required: true, defaultValue: "0x7e702e1a2c4cb9b7f56fbac26f9efe34345de47460f2dd05d7462e9117ac5fd2" },
            { componentId: "metadata-uri", componentKind: "uri", inputId: "buyerSelector.metadataURI", label: "履约者元数据 URI", required: true, defaultValue: "uvp-resource://phase2/customs-executor-metadata/v1" },
            { componentId: "executor-reference", componentKind: "text", inputId: "buyerSelector.executorReference", label: "履约者参考" },
            { componentId: "proof", componentKind: "proof_rows", label: "证明" }
          ]
        }
      ]
    }
  ],
  actions: [
    {
      actionId: phase2CustomsActionIds.applyExecutorPatch,
      actionKind: "stage_executor_patch",
      label: "选择报关履约者",
      primary: true,
      inputBindings: {
        selectorWallet: "buyerSelector.selectorWallet",
        targetStageId: "buyerSelector.targetStageId",
        mode: "buyerSelector.mode",
        executorWallet: "buyerSelector.executorWallet",
        executorMetadataHash: "buyerSelector.executorMetadataHash",
        metadataURI: "buyerSelector.metadataURI"
      }
    }
  ]
};

export const phase2BuyerResourceControllerManifest: ParticipantAddOnManifestDTO = {
  schemaVersion: "participant-addon-manifest.v1",
  manifestId: "phase2:buyer-resource-controller:v1",
  roleSlotId: phase2CustomsRoleSlotIds.buyerResourceController,
  addOnKind: "stage_resource_patch",
  title: "发布报关资源清单",
  summary: "为报关完成阶段发布内容寻址的资源清单和访问策略指纹。",
  stageBindings: [phase2CustomsStageIds.customsComplete],
  pages: [
    {
      pageId: "resource-manifest",
      title: "资源清单",
      sections: [
        {
          sectionId: "resource-patch",
          title: "资源补丁",
          components: [
            { componentId: "selector-wallet", componentKind: "wallet", inputId: "buyerResourceController.selectorWallet", label: "买家钱包", required: true, defaultValue: phase2CustomsWallets.buyer },
            { componentId: "target-stage", componentKind: "stage_select", inputId: "buyerResourceController.targetStageId", label: "目标阶段", required: true, defaultValue: phase2CustomsStageIds.customsComplete },
            { componentId: "resource-key", componentKind: "text", inputId: "buyerResourceController.resourceKey", label: "资源键", required: true, defaultValue: phase2CustomsResourceKeys.customsDeclarationPdf },
            { componentId: "manifest-uri", componentKind: "uri", inputId: "buyerResourceController.manifestURI", label: "资源清单 URI", required: true, defaultValue: phase2CustomsResourceManifest.manifestURI },
            { componentId: "manifest-hash", componentKind: "hash", inputId: "buyerResourceController.manifestHash", label: "资源清单指纹", required: true, defaultValue: phase2CustomsResourceManifest.manifestHash },
            { componentId: "policy-hash", componentKind: "hash", inputId: "buyerResourceController.policyHash", label: "访问策略指纹", required: true, defaultValue: phase2CustomsResourceManifest.policyHash },
            { componentId: "requirements", componentKind: "resource_requirements", label: "资源要求" },
            { componentId: "proof", componentKind: "proof_rows", label: "证明" }
          ]
        }
      ]
    }
  ],
  actions: [
    {
      actionId: phase2CustomsActionIds.applyResourcePatch,
      actionKind: "stage_resource_patch",
      label: "发布资源清单",
      primary: true,
      inputBindings: {
        selectorWallet: "buyerResourceController.selectorWallet",
        targetStageId: "buyerResourceController.targetStageId",
        resourceKey: "buyerResourceController.resourceKey",
        manifestURI: "buyerResourceController.manifestURI",
        manifestHash: "buyerResourceController.manifestHash",
        policyHash: "buyerResourceController.policyHash"
      }
    }
  ]
};

export const phase2CustomsExecutorManifest: ParticipantAddOnManifestDTO = {
  schemaVersion: "participant-addon-manifest.v1",
  manifestId: "phase2:customs-executor:v1",
  roleSlotId: phase2CustomsRoleSlotIds.customsExecutor,
  addOnKind: "submit_signal",
  title: "提交报关完成",
  summary: "被选中的报关履约者提交报关完成信号和凭证引用。",
  stageBindings: [phase2CustomsStageIds.customsComplete],
  pages: [
    {
      pageId: "customs-complete",
      title: "报关完成",
      sections: [
        {
          sectionId: "executor-signal",
          title: "完成提交",
          components: [
            { componentId: "wallet", componentKind: "wallet", inputId: "customsExecutor.walletAddress", label: "报关履约者钱包", required: true, defaultValue: phase2CustomsWallets.customsExecutor },
            { componentId: "requirements", componentKind: "resource_requirements", label: "资源要求" },
            { componentId: "evidence", componentKind: "evidence_refs", inputId: "customsExecutor.evidenceIds", label: "凭证引用", required: true },
            { componentId: "confirmation", componentKind: "confirmation", inputId: "customsExecutor.confirmation", label: "确认报关已完成", required: true },
            { componentId: "proof", componentKind: "proof_rows", label: "证明" }
          ]
        }
      ]
    }
  ],
  actions: [
    {
      actionId: phase2CustomsActionIds.submitCustomsComplete,
      actionKind: "submit_signal",
      label: "提交报关完成",
      primary: true,
      intent: "confirm_stage",
      inputBindings: {
        walletAddress: "customsExecutor.walletAddress",
        evidenceIds: "customsExecutor.evidenceIds",
        confirmation: "customsExecutor.confirmation"
      }
    }
  ]
};

export const phase2CustomsRoleSlots: readonly RoleSlotDTO[] = [
  {
    slotId: phase2CustomsRoleSlotIds.buyerSelector,
    title: "买家选择方",
    label: "买家",
    duty: "选择报关履约者并签名提交执行者补丁。",
    evidence: ["履约者元数据指纹"],
    status: "required",
    tone: "info",
    required: true,
    performanceSlotLabel: "买家选择方",
    businessPersonaLabels: ["买家"],
    capabilityPlugins: [buyerSelectorPlugin],
    addOnManifest: phase2BuyerSelectorManifest
  },
  {
    slotId: phase2CustomsRoleSlotIds.buyerResourceController,
    title: "买家资源请求方",
    label: "买家",
    duty: "发布报关资源清单和访问策略指纹。",
    evidence: ["资源清单指纹", "访问策略指纹"],
    status: "required",
    tone: "info",
    required: true,
    performanceSlotLabel: "买家资源请求方",
    businessPersonaLabels: ["买家"],
    capabilityPlugins: [buyerResourceControllerPlugin],
    addOnManifest: phase2BuyerResourceControllerManifest
  },
  {
    slotId: phase2CustomsRoleSlotIds.customsExecutor,
    title: "报关履约者",
    label: "报关行",
    duty: "读取授权资源清单并提交报关完成信号。",
    evidence: ["报关完成凭证引用", "报关单 PDF 资源清单"],
    status: "required",
    tone: "warn",
    required: true,
    performanceSlotLabel: "报关履约者",
    businessPersonaLabels: ["报关行", "关务服务商"],
    capabilityPlugins: [customsExecutorPlugin],
    addOnManifest: phase2CustomsExecutorManifest
  }
];

export const phase2CustomsOrderPermissionTable: readonly OrderPermissionTableEntryDTO[] = [
  {
    permissionId: "phase2.customs.executor-patch",
    roleSlotId: phase2CustomsRoleSlotIds.buyerSelector,
    stageId: phase2CustomsStageIds.buyerSelectCustomsExecutor,
    source: "buyer",
    signalName: phase2CustomsSignalIds.executorSelected,
    payloadPolicy: "required",
    requiredEvidence: ["履约者元数据指纹"]
  },
  {
    permissionId: "phase2.customs.resource-patch",
    roleSlotId: phase2CustomsRoleSlotIds.buyerResourceController,
    stageId: phase2CustomsStageIds.buyerPublishCustomsResources,
    source: "buyer",
    signalName: phase2CustomsSignalIds.resourcesPublished,
    payloadPolicy: "required",
    requiredEvidence: ["资源清单指纹", "访问策略指纹"]
  },
  {
    permissionId: "phase2.customs.executor-signal",
    roleSlotId: phase2CustomsRoleSlotIds.customsExecutor,
    stageId: phase2CustomsStageIds.customsComplete,
    source: "customs",
    signalName: phase2CustomsSignalIds.customsCompleteConfirmed,
    payloadPolicy: "required",
    requiredEvidence: ["报关完成凭证引用"]
  }
];

export const phase2CustomsZhixuDetail: ZhixuDetailDTO = {
  zhixuId: PHASE2_CUSTOMS_ZHIXU_ID,
  title: "Phase 2 报关完成秩序",
  subtitle: "买家选择报关履约者、发布资源清单，报关履约者提交链上完成信号。",
  reviewStatus: "approved",
  reviewLabel: "Phase 2 fixture",
  riskLevel: "测试闭环",
  applicableBusiness: ["跨境报关", "出口单证"],
  excludedBusiness: ["文件原文上链", "未授权履约者代签"],
  stageCount: phase2CustomsStages.length,
  roleSlotCount: phase2CustomsRoleSlots.length,
  supportedPaymentMethods: ["无资金动作"],
  maintainer: "共同秩序",
  updatedAt: "2026-05-01",
  chainAttestation: {
    status: "not_found",
    label: "等待官方域链上背书",
    domainLabel: "共同秩序官方审核",
    planId: phase2CustomsPlanIds.planId,
    planHash: phase2CustomsPlanIds.planHash,
    artifactHash: phase2CustomsPlanIds.artifactHash
  },
  roleSlots: phase2CustomsRoleSlots,
  dockableModules: [],
  stages: phase2CustomsStages,
  orderPermissionTable: phase2CustomsOrderPermissionTable,
  createOrderTrigger: {
    source: phase2CustomsInitialTriggerSource,
    signalName: phase2CustomsSignalIds.orderRegistered,
    triggerHookId: "0x4625d43b26ce487427096279b6f54b8bf51a479e9ff90e52c0e71bcc0cba42a2",
    triggerStageId: "0xc670b506d61c646291c5d7ad8521d23188993447ada564c84d6be83599107cca"
  },
  proofRows: [
    { label: "Plan ID", value: phase2CustomsPlanIds.planId },
    { label: "Plan Hash", value: phase2CustomsPlanIds.planHash },
    { label: "Selector Binding", value: `${phase2CustomsStageIds.buyerSelectCustomsExecutor}->${phase2CustomsStageIds.customsComplete}` },
    { label: "Resource Key", value: phase2CustomsResourceKeys.customsDeclarationPdf }
  ],
  createOrderHint: "创建订单时预授权买家控制动作和已知报关履约者的完成信号。"
};

const phase2Participants: readonly ParticipantDTO[] = [
  {
    participantId: "buyer",
    role: "买家",
    duty: "选择报关履约者并发布资源清单",
    evidence: ["履约者元数据指纹", "资源清单指纹"],
    status: "joined",
    tone: "ok",
    addOnKind: "stage_executor_patch"
  },
  {
    participantId: "customs-executor",
    role: "报关履约者",
    duty: "提交报关完成信号",
    evidence: ["报关完成凭证引用"],
    status: "joined",
    tone: "ok",
    addOnKind: "submit_signal"
  }
];

export const phase2CustomsOrder: ProductOrderDTO = {
  orderId: PHASE2_CUSTOMS_ORDER_ID,
  zhixuId: PHASE2_CUSTOMS_ZHIXU_ID,
  title: "Phase 2 报关闭环订单",
  status: "completed",
  statusLabel: "报关完成",
  totalAmount: {
    amount: "0",
    currency: "USDC",
    display: "0 USDC"
  },
  fundingStatus: "无资金动作",
  currentStageId: phase2CustomsStageIds.customsComplete,
  currentStageName: "报关完成",
  currentTaskId: "task-phase2-customs-executor",
  currentTaskTitle: "报关完成信号已提交",
  currentTaskSummary: "选择履约者、资源清单发布、报关完成三个动作均已有链上证明。",
  stages: phase2CustomsStages,
  resourceRequirements: {
    [phase2CustomsStageIds.customsComplete]: phase2CustomsResourceRequirements
  },
  participants: phase2Participants,
  recentEvents: [
    { eventId: "evt-phase2-executor", text: "StageExecutorActivated customs-complete", time: "2026-05-01T00:05:00.000Z" },
    { eventId: "evt-phase2-resource", text: "StageResourcePatchApplied customs_declaration_pdf", time: "2026-05-01T00:08:00.000Z" },
    { eventId: "evt-phase2-signal", text: "SignalSubmitted customs-complete.confirm_stage", time: "2026-05-01T00:20:00.000Z" }
  ],
  proofRows: [
    { label: "Executor Event", value: "StageExecutorActivated" },
    { label: "Resource Event", value: "StageResourcePatchApplied" },
    { label: "Signal Event", value: "SignalSubmitted" },
    { label: "Active Executor", value: phase2CustomsWallets.customsExecutor }
  ]
};

export const phase2CustomsSelectorTask: ProductTaskDTO = {
  taskId: "task-phase2-buyer-selector",
  orderId: PHASE2_CUSTOMS_ORDER_ID,
  orderTitle: phase2CustomsOrder.title,
  zhixuId: PHASE2_CUSTOMS_ZHIXU_ID,
  title: "选择报关履约者",
  subtitle: "买家签名指定报关完成阶段的履约者钱包。",
  assigneeRole: "买家",
  assigneeWallet: phase2CustomsWallets.buyer,
  stageId: phase2CustomsStageIds.buyerSelectCustomsExecutor,
  stageName: "选择报关履约者",
  deadline: "2026-05-01 23:59",
  fundingImpact: "无资金动作",
  requiredEvidence: ["履约者元数据指纹"],
  status: "done",
  addOnKind: "stage_executor_patch",
  addOnManifest: phase2BuyerSelectorManifest,
  primaryActionLabel: "选择报关履约者",
  participantRoleLabel: "买家",
  participantWallet: phase2CustomsWallets.buyer,
  canSubmit: false,
  responsibilityStatements: [],
  proofRows: [
    { label: "链上事件", value: "StageExecutorActivated" },
    { label: "Target Stage", value: phase2CustomsStageIds.customsComplete },
    { label: "Executor", value: phase2CustomsWallets.customsExecutor }
  ]
};

export const phase2CustomsResourceControllerTask: ProductTaskDTO = {
  taskId: "task-phase2-buyer-resource-controller",
  orderId: PHASE2_CUSTOMS_ORDER_ID,
  orderTitle: phase2CustomsOrder.title,
  zhixuId: PHASE2_CUSTOMS_ZHIXU_ID,
  title: "发布报关资源清单",
  subtitle: "买家签名发布报关单 PDF 的内容寻址清单和访问策略指纹。",
  assigneeRole: "买家",
  assigneeWallet: phase2CustomsWallets.buyer,
  stageId: phase2CustomsStageIds.buyerPublishCustomsResources,
  stageName: "发布报关资源清单",
  deadline: "2026-05-01 23:59",
  fundingImpact: "无资金动作",
  requiredEvidence: ["资源清单指纹", "访问策略指纹"],
  status: "done",
  addOnKind: "stage_resource_patch",
  addOnManifest: phase2BuyerResourceControllerManifest,
  resourceRequirements: phase2CustomsResourceRequirements,
  primaryActionLabel: "发布资源清单",
  participantRoleLabel: "买家",
  participantWallet: phase2CustomsWallets.buyer,
  canSubmit: false,
  responsibilityStatements: [],
  proofRows: [
    { label: "链上事件", value: "StageResourcePatchApplied" },
    { label: "Manifest Hash", value: phase2CustomsResourceManifest.manifestHash },
    { label: "Policy Hash", value: phase2CustomsResourceManifest.policyHash }
  ]
};

export const phase2CustomsExecutorTask: ProductTaskDTO = {
  taskId: "task-phase2-customs-executor",
  orderId: PHASE2_CUSTOMS_ORDER_ID,
  orderTitle: phase2CustomsOrder.title,
  zhixuId: PHASE2_CUSTOMS_ZHIXU_ID,
  title: "提交报关完成",
  subtitle: "报关履约者提交完成信号和凭证引用。",
  assigneeRole: "报关履约者",
  assigneeWallet: phase2CustomsWallets.customsExecutor,
  stageId: phase2CustomsStageIds.customsComplete,
  stageName: "报关完成",
  deadline: "2026-05-01 23:59",
  fundingImpact: "无资金动作",
  requiredEvidence: ["报关完成凭证引用", "报关单 PDF 资源清单"],
  status: "done",
  addOnKind: "submit_signal",
  addOnManifest: phase2CustomsExecutorManifest,
  resourceRequirements: phase2CustomsResourceRequirements,
  fulfillmentKind: "delivery_update",
  performanceSlotId: phase2CustomsRoleSlotIds.customsExecutor,
  performanceSlotLabel: "报关履约者",
  businessPersonaLabels: ["报关行", "关务服务商"],
  capabilityPlugin: {
    ...customsExecutorPlugin,
    roleSlotId: phase2CustomsRoleSlotIds.customsExecutor
  },
  primaryActionLabel: "提交报关完成",
  participantRoleLabel: "报关履约者",
  participantWallet: phase2CustomsWallets.customsExecutor,
  canSubmit: false,
  responsibilityStatements: [],
  proofRows: [
    { label: "链上事件", value: "SignalSubmitted" },
    { label: "HookReady", value: phase2CustomsStageIds.customsComplete },
    { label: "Submitter", value: phase2CustomsWallets.customsExecutor }
  ]
};

export const phase2CustomsProductCatalog: ProductCatalogDTO = {
  zhixus: [phase2CustomsZhixuDetail],
  orders: [phase2CustomsOrder],
  tasks: [phase2CustomsSelectorTask, phase2CustomsResourceControllerTask, phase2CustomsExecutorTask]
};

export const phase2CustomsOnchainHookPlanArtifact = {
  schemaVersion: "uvp.onchainHookPlan.v1",
  planId: phase2CustomsPlanIds.planId,
  zhixuId: PHASE2_CUSTOMS_ZHIXU_ID,
  version: "1",
  zhixuName: "Phase 2 Customs Completion",
  platform: {
    type: "blockchain",
    provider: "eth"
  },
  sourcePlanHash: "0xb53f5c9b4952031d4cfd3117cb453c357ea51edad8920723f64acadc6b26d178",
  compiledHooks: [
    {
      hookId: "0x4625d43b26ce487427096279b6f54b8bf51a479e9ff90e52c0e71bcc0cba42a2",
      stageId: "0xc670b506d61c646291c5d7ad8521d23188993447ada564c84d6be83599107cca",
      stageIdentifier: phase2CustomsStageIds.buyerPublishCustomsResources,
      hookName: "resource_controller_task_ready",
      kind: "receive",
      isTrigger: true,
      instructions: [
        {
          op: "SIGNAL",
          source: "order",
          signalName: "registered",
          sourceId: "0x21c0107378acb490e7190da71596effe409c128f08adcc5467b293f1f3a66431",
          signalId: "0xbe9532cecf48a73f784c5d193f0596e1b631c224802ec00a45840ad110d37000",
          signalKey: "0xae9800a26b8d4a30b264881580350b79eae03733cbcaedc2f84d673af81d83c7"
        }
      ],
      dependencies: [
        {
          kind: "positive",
          source: "order",
          signalName: "registered",
          sourceId: "0x21c0107378acb490e7190da71596effe409c128f08adcc5467b293f1f3a66431",
          signalId: "0xbe9532cecf48a73f784c5d193f0596e1b631c224802ec00a45840ad110d37000",
          signalKey: "0xae9800a26b8d4a30b264881580350b79eae03733cbcaedc2f84d673af81d83c7"
        }
      ],
      routeRef: {
        routeId: "0x9963f771afc5aaa6fabb6af0a7625a6c51011bc02fb39d5d5146ee79440bac3f",
        stageId: "0xc670b506d61c646291c5d7ad8521d23188993447ada564c84d6be83599107cca",
        routeHash: "0xaa0698c451e6e8eca83fa242e475f9a763f4d544db920e544b12d050fa25c80f"
      }
    },
    {
      hookId: "0xb433d86c98d77f20be226022a4378e73a8705b394f8e5c434a5f06362f3d2309",
      stageId: "0x301c76d30a738a103f1a948d5edd57e97fa2e17d80ddffff275c32daa56e6047",
      stageIdentifier: phase2CustomsStageIds.buyerSelectCustomsExecutor,
      hookName: "selector_task_ready",
      kind: "receive",
      isTrigger: true,
      instructions: [
        {
          op: "SIGNAL",
          source: "order",
          signalName: "registered",
          sourceId: "0x21c0107378acb490e7190da71596effe409c128f08adcc5467b293f1f3a66431",
          signalId: "0xbe9532cecf48a73f784c5d193f0596e1b631c224802ec00a45840ad110d37000",
          signalKey: "0xae9800a26b8d4a30b264881580350b79eae03733cbcaedc2f84d673af81d83c7"
        }
      ],
      dependencies: [
        {
          kind: "positive",
          source: "order",
          signalName: "registered",
          sourceId: "0x21c0107378acb490e7190da71596effe409c128f08adcc5467b293f1f3a66431",
          signalId: "0xbe9532cecf48a73f784c5d193f0596e1b631c224802ec00a45840ad110d37000",
          signalKey: "0xae9800a26b8d4a30b264881580350b79eae03733cbcaedc2f84d673af81d83c7"
        }
      ],
      routeRef: {
        routeId: "0x169a72a4d6908a7fd8eda5bbabaa54ee05d4de02e40ec40f9cb97f33e60f441a",
        stageId: "0x301c76d30a738a103f1a948d5edd57e97fa2e17d80ddffff275c32daa56e6047",
        routeHash: "0xcccad2de7aa9ead401a511ba06c3fccbbe50233b80076678ca4910046b648395"
      }
    },
    {
      hookId: "0xd4132edae6b1386373b5f41f6dbb3f0d4fed0010334fc82af26f8a176584ab8e",
      stageId: "0x447a9daf9645ca8aba6e1de3cb6a4b890bee3339aba2c795a3d25ba43805b70b",
      stageIdentifier: phase2CustomsStageIds.customsComplete,
      hookName: "customs_ready",
      kind: "receive",
      isTrigger: true,
      instructions: [
        {
          op: "SIGNAL",
          source: "buyer",
          signalName: phase2CustomsSignalIds.executorSelected,
          sourceId: "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
          signalId: "0xfb0d805fe29ea621f07ef3f01b091cfc965b8e8c0d26adce08a77091c93fbe35",
          signalKey: "0x035281ae069893d2e81fcd219397530de02deff08d6502c4d566e6dd4de7b51f"
        },
        {
          op: "SIGNAL",
          source: "buyer",
          signalName: phase2CustomsSignalIds.resourcesPublished,
          sourceId: "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
          signalId: "0x568b5d2b0707e6dfb5616cbaf29ce6fc97b0f720bc5b59a402c4c7dc9ef53465",
          signalKey: "0xfbde4dc6ebe7605fba9485da0533f0fa56527e6134e300d50a86073ec08ca583"
        },
        {
          op: "AND",
          arity: 2
        }
      ],
      dependencies: [
        {
          kind: "positive",
          source: "buyer",
          signalName: phase2CustomsSignalIds.executorSelected,
          sourceId: "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
          signalId: "0xfb0d805fe29ea621f07ef3f01b091cfc965b8e8c0d26adce08a77091c93fbe35",
          signalKey: "0x035281ae069893d2e81fcd219397530de02deff08d6502c4d566e6dd4de7b51f"
        },
        {
          kind: "positive",
          source: "buyer",
          signalName: phase2CustomsSignalIds.resourcesPublished,
          sourceId: "0x9c1bfc34ea7e295ac684c026c6d4de765734cb6b37fa07330bcfc241743ebbaf",
          signalId: "0x568b5d2b0707e6dfb5616cbaf29ce6fc97b0f720bc5b59a402c4c7dc9ef53465",
          signalKey: "0xfbde4dc6ebe7605fba9485da0533f0fa56527e6134e300d50a86073ec08ca583"
        }
      ]
    }
  ],
  dependencyIndex: {
    "0x035281ae069893d2e81fcd219397530de02deff08d6502c4d566e6dd4de7b51f": [
      "0xd4132edae6b1386373b5f41f6dbb3f0d4fed0010334fc82af26f8a176584ab8e"
    ],
    "0xae9800a26b8d4a30b264881580350b79eae03733cbcaedc2f84d673af81d83c7": [
      "0x4625d43b26ce487427096279b6f54b8bf51a479e9ff90e52c0e71bcc0cba42a2",
      "0xb433d86c98d77f20be226022a4378e73a8705b394f8e5c434a5f06362f3d2309"
    ],
    "0xfbde4dc6ebe7605fba9485da0533f0fa56527e6134e300d50a86073ec08ca583": [
      "0xd4132edae6b1386373b5f41f6dbb3f0d4fed0010334fc82af26f8a176584ab8e"
    ]
  },
  executorRoutes: [
    {
      routeId: "0x9963f771afc5aaa6fabb6af0a7625a6c51011bc02fb39d5d5146ee79440bac3f",
      stageId: "0xc670b506d61c646291c5d7ad8521d23188993447ada564c84d6be83599107cca",
      stageIdentifier: phase2CustomsStageIds.buyerPublishCustomsResources,
      executorType: "wallet",
      executorId: "buyer",
      routeHash: "0xaa0698c451e6e8eca83fa242e475f9a763f4d544db920e544b12d050fa25c80f"
    },
    {
      routeId: "0x169a72a4d6908a7fd8eda5bbabaa54ee05d4de02e40ec40f9cb97f33e60f441a",
      stageId: "0x301c76d30a738a103f1a948d5edd57e97fa2e17d80ddffff275c32daa56e6047",
      stageIdentifier: phase2CustomsStageIds.buyerSelectCustomsExecutor,
      executorType: "wallet",
      executorId: "buyer",
      routeHash: "0xcccad2de7aa9ead401a511ba06c3fccbbe50233b80076678ca4910046b648395"
    }
  ],
  selectorBindings: [
    {
      selectorStageIdentifier: phase2CustomsStageIds.buyerSelectCustomsExecutor,
      targetStageIdentifier: phase2CustomsStageIds.customsComplete,
      selectorStageId: "0x301c76d30a738a103f1a948d5edd57e97fa2e17d80ddffff275c32daa56e6047",
      targetStageId: "0x447a9daf9645ca8aba6e1de3cb6a4b890bee3339aba2c795a3d25ba43805b70b",
      bindingHash: "0x8b75cde323adb3d01db51594d16640f1d0610cecd73716fec05d2a05f4d9936f"
    },
    {
      selectorStageIdentifier: phase2CustomsStageIds.buyerPublishCustomsResources,
      targetStageIdentifier: phase2CustomsStageIds.customsComplete,
      selectorStageId: "0xc670b506d61c646291c5d7ad8521d23188993447ada564c84d6be83599107cca",
      targetStageId: "0x447a9daf9645ca8aba6e1de3cb6a4b890bee3339aba2c795a3d25ba43805b70b",
      bindingHash: "0x6b6b2c0e1c5c37b978ae6fdbe08ec02aefbb40d213b250cbed9de70f1c4238c8"
    }
  ],
  signalCapabilities: [],
  planHash: phase2CustomsPlanIds.planHash
} as const;

export const phase2CustomsStoreProductSchema: StoreProductSchemaDTO = {
  schemaVersion: "store-product-schema.v1",
  version: 1,
  zhixuId: PHASE2_CUSTOMS_ZHIXU_ID,
  title: phase2CustomsZhixuDetail.title,
  maintainer: phase2CustomsZhixuDetail.maintainer,
  planId: phase2CustomsPlanIds.planId,
  planHash: phase2CustomsPlanIds.planHash,
  artifactHash: phase2CustomsPlanIds.artifactHash,
  onchainHookPlanArtifact: phase2CustomsOnchainHookPlanArtifact,
  createOrderTrigger: {
    source: phase2CustomsInitialTriggerSource,
    signalName: phase2CustomsSignalIds.orderRegistered,
    triggerHookId: "0x4625d43b26ce487427096279b6f54b8bf51a479e9ff90e52c0e71bcc0cba42a2",
    triggerStageId: "0xc670b506d61c646291c5d7ad8521d23188993447ada564c84d6be83599107cca"
  },
  roleSlots: phase2CustomsRoleSlots,
  orderPermissionTable: phase2CustomsOrderPermissionTable,
  capabilityPlugins: phase2CustomsRoleSlots.flatMap((slot) => slot.capabilityPlugins ?? []),
  businessPersonaLabels: ["买家", "报关行", "关务服务商"],
  stages: phase2CustomsStages,
  selectorBindings: phase2CustomsOnchainHookPlanArtifact.selectorBindings,
  schemaHash: "0x911a922c4325d2385401a78756abe2ceda423b4c51749f275f9c1e6e37c8d69d",
  validation: {
    ok: true,
    status: "explicit",
    issues: []
  },
  createdAt: "2026-05-01T00:00:00.000Z",
  updatedAt: "2026-05-01T00:00:00.000Z"
};
