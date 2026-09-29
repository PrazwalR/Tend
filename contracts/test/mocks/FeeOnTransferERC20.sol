// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Takes a cut on transfer, like PAXG or a USDT with `basisPointsRate`
///         switched on.
contract FeeOnTransferERC20 is MockERC20 {
    uint256 public feeBps = 50;

    constructor() MockERC20("FoT", "FOT", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        super.transferFrom(from, address(0xdead), fee);
        return super.transferFrom(from, to, amount - fee);
    }
}
