import type {
  FulfillmentPluginKind,
  ParticipantAddOnManifestActionDTO,
  ProductTaskDTO,
} from "./index.js";

/**
 * 任务提交意图（写侧契约）：与 uvp-order-app taskPresentation /
 * zhixu-store workbenchSupport 的镜像同字面量集合，此处为唯一出处。
 * 与 {@link ProductSubmitIntent}（服务端 PrepareProductTaskSubmitInput.intent
 * 的权威词表）是同一联合的两个历史名字，值域恒等。
 */
export type TaskSubmitIntent =
  | "confirm_stage"
  | "reject_stage"
  | "raise_dispute"
  | "resolve_dispute";

/**
 * 无 manifest 声明时的兜底映射：争议任务（dispute_material）不得以
 * confirm_stage 提交。纯映射，两端原为逐字镜像。
 */
export const submitIntentByPluginKind: Readonly<
  Record<FulfillmentPluginKind, TaskSubmitIntent>
> = {
  payment_placeholder: "confirm_stage",
  evidence_submission: "confirm_stage",
  delivery_update: "confirm_stage",
  validation_confirm: "confirm_stage",
  dispute_material: "raise_dispute",
};

/**
 * manifest 驱动路径的提交意图：动作显式声明的 intent 优先（发布者声明是
 * 权威），未声明时按能力插件类型推导——dispute_material 的未声明动作不得
 * 兜底成 confirm_stage，否则争议任务会以确认口径提交。
 */
export function taskSubmitIntentForAction(
  action: Pick<ParticipantAddOnManifestActionDTO, "intent"> | undefined,
  task: Pick<ProductTaskDTO, "capabilityPlugin">,
): TaskSubmitIntent {
  if (action?.intent) {
    return action.intent;
  }
  const pluginKind = task.capabilityPlugin?.pluginKind;
  return pluginKind
    ? submitIntentByPluginKind[pluginKind] ?? "confirm_stage"
    : "confirm_stage";
}

/**
 * 任务的提交意图：manifest 显式声明的 submit_signal intent 优先，无声明时
 * 按能力插件类型推导。两端此前各自单源推导，manifest 与插件类型不一致时
 * 会得出不同 intent——推导收敛于此。
 */
export function taskSubmitIntent(
  task: Pick<ProductTaskDTO, "addOnManifest" | "capabilityPlugin">,
): TaskSubmitIntent {
  const submitActions = (task.addOnManifest?.actions ?? []).filter(
    (action) => action.actionKind === "submit_signal",
  );
  const primary =
    submitActions.find((action) => action.primary) ?? submitActions[0];
  return taskSubmitIntentForAction(primary, task);
}
