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
    // Code-point key order (= UTF-8 byte order), matching the Rust authority
    // (serde_json BTreeMap / str Ord). The default Array#sort compares UTF-16
    // code units, which orders astral-plane keys (surrogate pairs) BEFORE
    // high-BMP keys like U+FFFD — a different canonical byte stream for the
    // same value and therefore a different hash.
    for (const key of Object.keys(record).sort(compareByCodePoint)) {
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

export function compareByCodePoint(left: string, right: string): number {
  const leftPoints = Array.from(left);
  const rightPoints = Array.from(right);
  const length = Math.min(leftPoints.length, rightPoints.length);
  for (let index = 0; index < length; index += 1) {
    const comparison =
      (leftPoints[index] as string).codePointAt(0)! - (rightPoints[index] as string).codePointAt(0)!;
    if (comparison !== 0) {
      return comparison;
    }
  }
  return leftPoints.length - rightPoints.length;
}

export function canonicalStringify(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}
