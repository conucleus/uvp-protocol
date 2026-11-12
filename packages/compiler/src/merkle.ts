import { keccak256 } from "viem";
import { keccak256Hex } from "./hash.js";
import type { HexString } from "./types/index.js";

/**
 * 32-byte word 与 Merkle 基元（链轨唯一的建树/取证明实现）：叶子先排序去重，
 * 内部节点左右按字节序交换后 keccak；空树钉 keccak256("")。
 */

export const EMPTY_MERKLE_ROOT =
  "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470" as HexString;

export function keccakWord(data: string | Uint8Array): HexString {
  return keccak256Hex(data);
}

function concatWords(words: readonly HexString[]): Uint8Array {
  const out = new Uint8Array(words.length * 32);
  words.forEach((word, index) => {
    out.set(hexToBytes(word), index * 32);
  });
  return out;
}

function hexToBytes(value: HexString): Uint8Array {
  const body = value.slice(2);
  const out = new Uint8Array(body.length / 2);
  for (let index = 0; index < out.length; index += 1) {
    out[index] = Number.parseInt(body.slice(index * 2, index * 2 + 2), 16);
  }
  return out;
}

export function keccakWords(domain: string, words: readonly HexString[]): HexString {
  return keccak256(concatWords([keccakWord(domain), ...words])) as HexString;
}

export function merkleRoot(leaves: readonly HexString[]): HexString {
  if (leaves.length === 0) {
    return EMPTY_MERKLE_ROOT;
  }
  let level = [...new Set(leaves)].sort();
  while (level.length > 1) {
    const next: HexString[] = [];
    for (let index = 0; index < level.length; index += 2) {
      const left = level[index] as HexString;
      if (index + 1 === level.length) {
        next.push(left);
      } else {
        const right = level[index + 1] as HexString;
        const [first, second] = left <= right ? [left, right] : [right, left];
        next.push(keccak256(concatWords([first, second])) as HexString);
      }
    }
    level = next;
  }
  return level[0] as HexString;
}

export function merkleProof(
  leaves: readonly HexString[],
  leaf: HexString,
): HexString[] | undefined {
  if (leaves.length === 0 || !leaves.includes(leaf)) {
    return undefined;
  }
  let level = [...new Set(leaves)].sort();
  let index = level.indexOf(leaf);
  const proof: HexString[] = [];
  while (level.length > 1) {
    const next: HexString[] = [];
    for (let cursor = 0; cursor < level.length; cursor += 2) {
      const left = level[cursor] as HexString;
      if (cursor + 1 === level.length) {
        next.push(left);
        if (cursor === index) {
          index = next.length - 1;
        }
      } else {
        const right = level[cursor + 1] as HexString;
        const [first, second] = left <= right ? [left, right] : [right, left];
        next.push(keccak256(concatWords([first, second])) as HexString);
        if (cursor === index) {
          proof.push(right);
          index = next.length - 1;
        } else if (cursor + 1 === index) {
          proof.push(left);
          index = next.length - 1;
        }
      }
    }
    level = next;
  }
  return proof;
}

export function verifyMerkleProof(
  root: HexString,
  leaf: HexString,
  proof: readonly HexString[],
): boolean {
  let current = leaf;
  for (const sibling of proof) {
    const [left, right] = current <= sibling ? [current, sibling] : [sibling, current];
    current = keccak256(concatWords([left, right])) as HexString;
  }
  return current === root;
}
