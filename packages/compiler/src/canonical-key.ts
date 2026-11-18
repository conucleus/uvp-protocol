import { compareByCodePoint } from "@uvp-eth/canonical-json";

export function compareCanonicalKey(left: string, right: string): number {
  const order = compareByCodePoint(left, right);
  return order < 0 ? -1 : order > 0 ? 1 : 0;
}
