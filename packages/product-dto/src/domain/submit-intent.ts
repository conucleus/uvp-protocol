import type {
  FulfillmentPluginKind,
  ParticipantAddOnManifestActionDTO,
  ProductTaskDTO,
} from "./index.js";

export type TaskSubmitIntent = "confirm_stage" | "reject_stage";

export const submitIntentByPluginKind: Readonly<
  Record<FulfillmentPluginKind, TaskSubmitIntent>
> = {
  payment_placeholder: "confirm_stage",
  evidence_submission: "confirm_stage",
  delivery_update: "confirm_stage",
  validation_confirm: "confirm_stage",
};

export function taskSubmitIntentForAction(
  action: Pick<ParticipantAddOnManifestActionDTO, "intent"> | undefined,
): TaskSubmitIntent {
  return action?.intent ?? "confirm_stage";
}

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
