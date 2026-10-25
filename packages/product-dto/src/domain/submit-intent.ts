import type {
  FulfillmentPluginKind,
  ParticipantAddOnManifestActionDTO,
  ProductTaskDTO,
} from "./index.js";

/**
 * 任务提交意图（任务推导面）：uvp-order-app taskPresentation /
 * zhixu-store workbenchSupport 消费的镜像同字面量集合，此处为唯一出处。
 * 与 {@link ProductSubmitIntent} 值域恒等、各表其义：本名供任务模型/
 * 工作台按 manifest 与插件类型推导意图，ProductSubmitIntent 锚定服务端
 * 提交契约（PrepareProductTaskSubmitInput.intent）的受理词表。
 */
export type TaskSubmitIntent = "confirm_stage" | "reject_stage";

export const submitIntentByPluginKind: Readonly<
  Record<FulfillmentPluginKind, TaskSubmitIntent>
> = {
  payment_placeholder: "confirm_stage",
  evidence_submission: "confirm_stage",
  delivery_update: "confirm_stage",
  validation_confirm: "confirm_stage",
};

/**
 * manifest 驱动路径的提交意图：动作显式声明的 intent 优先（发布者声明是
 * 权威），未声明时按能力插件类型推导——dispute_material 的未声明动作不得
 * 兜底成 confirm_stage，否则争议任务会以确认口径提交。
 */
export function taskSubmitIntentForAction(
  action: Pick<ParticipantAddOnManifestActionDTO, "intent"> | undefined,
): TaskSubmitIntent {
  return action?.intent ?? "confirm_stage";
}

/**
 * 任务的提交意图：manifest 显式声明的 submit_signal intent 优先，无声明时
 * 按能力插件类型推导。推导不得分散在两端——manifest 与插件类型不一致时
 * 会得出不同 intent，推导收敛于此单源。
 */
export function taskSubmitIntent(
  task: Pick<ProductTaskDTO, "addOnManifest">,
): TaskSubmitIntent {
  const submitActions = (task.addOnManifest?.actions ?? []).filter(
    (action) => action.actionKind === "submit_signal",
  );
  const primary =
    submitActions.find((action) => action.primary) ?? submitActions[0];
  return taskSubmitIntentForAction(primary);
}
