/**
 * Pure syntactic sugar that expands a Dock-style `{ from, to, signalMap }`
 * mapping into standard Hook declarations without touching `uvp-core`.
 */

export interface DockSignalMapping {
  readonly output: string;
  readonly validWhen: readonly string[];
}

export interface DockDesugarInput {
  readonly from: { readonly source: string };
  readonly to: { readonly stage: string };
  readonly signalMap: readonly DockSignalMapping[];
}

export interface DesugaredHook {
  readonly stage: string;
  readonly hookName: string;
  readonly expression: string;
}

export function desugarDockToHooks(
  input: DockDesugarInput,
): readonly DesugaredHook[] {
  const source = input.from.source.trim();
  const stage = input.to.stage.trim();
  if (source.length === 0) {
    throw new Error("desugarDockToHooks: from.source must be non-empty");
  }
  if (stage.length === 0) {
    throw new Error("desugarDockToHooks: to.stage must be non-empty");
  }
  return input.signalMap.map((entry) => {
    const hookName = entry.output.trim();
    if (hookName.length === 0) {
      throw new Error("desugarDockToHooks: signalMap[].output must be non-empty");
    }
    if (entry.validWhen.length === 0) {
      throw new Error(
        `desugarDockToHooks: signalMap[${hookName}].validWhen must not be empty`,
      );
    }
    const clauses = entry.validWhen.map((clause) => {
      const trimmed = clause.trim();
      return trimmed.includes("::") ? trimmed : `${source}::${trimmed}`;
    });
    return {
      stage,
      hookName,
      expression: clauses.length === 1 ? clauses[0]! : clauses.join(" && "),
    };
  });
}
