import { canonicalStringify } from "./canonical.js";
import type { HexString } from "./types/index.js";

const MASK_64 = (1n << 64n) - 1n;
const RATE_BYTES = 136;
const OUTPUT_BYTES = 32;
const ROUND_CONSTANTS = [
  0x0000000000000001n,
  0x0000000000008082n,
  0x800000000000808an,
  0x8000000080008000n,
  0x000000000000808bn,
  0x0000000080000001n,
  0x8000000080008081n,
  0x8000000000008009n,
  0x000000000000008an,
  0x0000000000000088n,
  0x0000000080008009n,
  0x000000008000000an,
  0x000000008000808bn,
  0x800000000000008bn,
  0x8000000000008089n,
  0x8000000000008003n,
  0x8000000000008002n,
  0x8000000000000080n,
  0x000000000000800an,
  0x800000008000000an,
  0x8000000080008081n,
  0x8000000000008080n,
  0x0000000080000001n,
  0x8000000080008008n
] as const;

const RHO_OFFSETS = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14]
] as const;

const encoder = new TextEncoder();

export function keccak256Hex(data: Uint8Array | string): HexString {
  const bytes = typeof data === "string" ? encoder.encode(data) : data;
  return bytesToHex(keccak256(bytes));
}

export function hashCanonical(domain: string, payload: unknown): HexString {
  return keccak256Hex(`${domain}:${canonicalStringify(payload)}`);
}

function keccak256(data: Uint8Array): Uint8Array {
  const state = new Array<bigint>(25).fill(0n);
  let offset = 0;

  while (offset + RATE_BYTES <= data.length) {
    absorbBlock(state, data.subarray(offset, offset + RATE_BYTES));
    keccakF1600(state);
    offset += RATE_BYTES;
  }

  const finalBlock = new Uint8Array(RATE_BYTES);
  finalBlock.set(data.subarray(offset));
  finalBlock[data.length - offset] = (finalBlock[data.length - offset] ?? 0) ^ 0x01;
  finalBlock[RATE_BYTES - 1] = (finalBlock[RATE_BYTES - 1] ?? 0) ^ 0x80;
  absorbBlock(state, finalBlock);
  keccakF1600(state);

  const out = new Uint8Array(OUTPUT_BYTES);
  for (let index = 0; index < OUTPUT_BYTES; index += 1) {
    const lane = state[Math.floor(index / 8)] ?? 0n;
    out[index] = Number((lane >> BigInt((index % 8) * 8)) & 0xffn);
  }
  return out;
}

function absorbBlock(state: bigint[], block: Uint8Array): void {
  for (let index = 0; index < block.length; index += 1) {
    const laneIndex = Math.floor(index / 8);
    state[laneIndex] =
      ((state[laneIndex] ?? 0n) ^
        (BigInt(block[index] ?? 0) << BigInt((index % 8) * 8))) &
      MASK_64;
  }
}

function keccakF1600(state: bigint[]): void {
  for (const roundConstant of ROUND_CONSTANTS) {
    const c = new Array<bigint>(5).fill(0n);
    const d = new Array<bigint>(5).fill(0n);
    const b = new Array<bigint>(25).fill(0n);

    for (let x = 0; x < 5; x += 1) {
      c[x] =
        (state[x] ?? 0n) ^
        (state[x + 5] ?? 0n) ^
        (state[x + 10] ?? 0n) ^
        (state[x + 15] ?? 0n) ^
        (state[x + 20] ?? 0n);
    }

    for (let x = 0; x < 5; x += 1) {
      d[x] = (c[(x + 4) % 5] ?? 0n) ^ rotl64(c[(x + 1) % 5] ?? 0n, 1);
    }

    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) {
        const index = x + 5 * y;
        state[index] = ((state[index] ?? 0n) ^ (d[x] ?? 0n)) & MASK_64;
      }
    }

    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) {
        const destination = y + 5 * ((2 * x + 3 * y) % 5);
        b[destination] = rotl64(
          state[x + 5 * y] ?? 0n,
          RHO_OFFSETS[x]?.[y] ?? 0
        );
      }
    }

    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) {
        const index = x + 5 * y;
        state[index] =
          ((b[index] ?? 0n) ^
            (~(b[((x + 1) % 5) + 5 * y] ?? 0n) &
              (b[((x + 2) % 5) + 5 * y] ?? 0n))) &
          MASK_64;
      }
    }

    state[0] = ((state[0] ?? 0n) ^ roundConstant) & MASK_64;
  }
}

function rotl64(value: bigint, shift: number): bigint {
  if (shift === 0) {
    return value & MASK_64;
  }
  const bits = BigInt(shift);
  return ((value << bits) | (value >> (64n - bits))) & MASK_64;
}

function bytesToHex(bytes: Uint8Array): HexString {
  let hex = "0x";
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return hex as HexString;
}
