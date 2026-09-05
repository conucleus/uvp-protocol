// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Zhixu Dock Merkle 原语
/// @dev 与 Rust `uvp-compiler::dock`、TS `compiler/src/dock.ts` 逐字节一致：
///      叶子列表先按字节升序去重排序；配对合并
///      `keccak256(min(a,b) ‖ max(a,b))`；奇数尾叶直接提升；
///      空集合 root = `keccak256("")`。
library DockMerkle {
    bytes32 public constant EMPTY_ROOT = keccak256("");

    /// @notice 就地排序（去重）后逐层建树。仅用于测试与 calldata 一致性
    ///         校验（叶子数 ≤ MAX_DOCK_OUTPUTS，无界输入禁止调用）。
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 0) {
            return EMPTY_ROOT;
        }
        sortUnique(leaves);
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 nextLength = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLength);
            uint256 cursor;
            for (uint256 i = 0; i + 1 < level.length; i += 2) {
                next[cursor++] = pair(level[i], level[i + 1]);
            }
            if (level.length % 2 == 1) {
                next[cursor] = level[level.length - 1];
            }
            level = next;
        }
        return level[0];
    }

    function pair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        if (left <= right) {
            return keccak256(abi.encodePacked(left, right));
        }
        return keccak256(abi.encodePacked(right, left));
    }

    function verify(bytes32 rootValue, bytes32 leaf, bytes32[] memory proof) internal pure returns (bool) {
        bytes32 current = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            current = pair(current, proof[i]);
        }
        return current == rootValue;
    }

    function sortUnique(bytes32[] memory leaves) private pure {
        uint256 length = leaves.length;
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = i + 1; j < length; j++) {
                if (leaves[j] < leaves[i]) {
                    bytes32 tmp = leaves[i];
                    leaves[i] = leaves[j];
                    leaves[j] = tmp;
                } else if (leaves[j] == leaves[i]) {
                    // 去重：把重复项交换到尾部并收缩有效长度。
                    leaves[j] = leaves[length - 1];
                    length -= 1;
                    j -= 1;
                }
            }
        }
        assembly {
            mstore(leaves, length)
        }
    }
}
