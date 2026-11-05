// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// authorizer 直接入口 harness：只把 calldata 原样转发给 stateMachine。
contract BirthAuthorizerForwarder {
    address public immutable stateMachine;

    constructor(address stateMachineAddress) {
        stateMachine = stateMachineAddress;
    }

    fallback() external {
        (bool ok, bytes memory data) = stateMachine.call(msg.data);
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
        assembly {
            return(add(data, 0x20), mload(data))
        }
    }
}
