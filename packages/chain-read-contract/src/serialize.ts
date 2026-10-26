// Wire serialization rule for chain read payloads: every bigint field becomes
// a decimal string, arrays and plain objects are traversed, and undefined
// object members are dropped exactly as JSON.stringify would drop them.
export type Wire<T> = T extends bigint
  ? string
  : T extends readonly (infer TItem)[]
    ? readonly Wire<TItem>[]
    : T extends object
      ? { readonly [TKey in keyof T]: Wire<T[TKey]> }
      : T;

export function toWire<T>(value: T): Wire<T> {
  return wireValue(value) as Wire<T>;
}

function wireValue(value: unknown): unknown {
  if (typeof value === "bigint") {
    return value.toString();
  }
  if (Array.isArray(value)) {
    return value.map(wireValue);
  }
  if (value !== null && typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value)) {
      if (entry !== undefined) {
        result[key] = wireValue(entry);
      }
    }
    return result;
  }
  return value;
}
