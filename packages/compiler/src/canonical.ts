export type CanonicalJsonValue =
  | null
  | boolean
  | number
  | string
  | readonly CanonicalJsonValue[]
  | { readonly [key: string]: CanonicalJsonValue };

export function canonicalize(value: unknown, path = "$"): CanonicalJsonValue {
  if (value === null) {
    return null;
  }

  const valueType = typeof value;
  if (valueType === "string" || valueType === "boolean") {
    return value as string | boolean;
  }

  if (valueType === "number") {
    if (!Number.isFinite(value)) {
      throw new TypeError(`${path} must be a finite JSON number`);
    }
    if (Object.is(value, -0)) {
      return 0;
    }
    return value as number;
  }

  if (Array.isArray(value)) {
    return value.map((item, index) => canonicalize(item, `${path}[${index}]`));
  }

  if (valueType === "object") {
    const record = value as Record<string, unknown>;
    const sorted: Record<string, CanonicalJsonValue> = {};
    for (const key of Object.keys(record).sort()) {
      const child = record[key];
      if (typeof child === "undefined") {
        throw new TypeError(`${path}.${key} must not be undefined`);
      }
      sorted[key] = canonicalize(child, `${path}.${key}`);
    }
    return sorted;
  }

  throw new TypeError(`${path} contains unsupported JSON value: ${valueType}`);
}

export function canonicalStringify(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}
