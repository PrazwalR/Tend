// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

interface ITokenReceiverHook {
    function onTokenTransfer(address from, uint256 amount) external;
}

/// @notice Audit mock combining the token behaviours the hook must survive:
///         issuer pause (USDC/USDT), blacklist (USDC/USDT), an ERC777-style
///         post-transfer callback to opted-in recipients, and an issuer-side
///         negative rebase (`slash`) standing in for a rebasing token.
contract WeirdERC20 is MockERC20 {
    bool public paused;
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public hooked;

    constructor(string memory name) MockERC20(name, name, 18) {}

    function setPaused(bool p) external {
        paused = p;
    }

    function setBlacklisted(address who, bool b) external {
        blacklisted[who] = b;
    }

    function setHooked(address who, bool b) external {
        hooked[who] = b;
    }

    /// Negative rebase of one holder's balance (e.g. a slashing event on stETH).
    function slash(address who, uint256 amount) external {
        balanceOf[who] -= amount;
        totalSupply -= amount;
    }

    function _check(address from, address to) internal view {
        require(!paused, "WeirdERC20: paused");
        require(!blacklisted[from] && !blacklisted[to] && !blacklisted[msg.sender], "WeirdERC20: blacklisted");
    }

    function transfer(address to, uint256 amount) public override returns (bool ok) {
        _check(msg.sender, to);
        ok = super.transfer(to, amount);
        if (hooked[to]) ITokenReceiverHook(to).onTokenTransfer(msg.sender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool ok) {
        _check(from, to);
        ok = super.transferFrom(from, to, amount);
        if (hooked[to]) ITokenReceiverHook(to).onTokenTransfer(from, amount);
    }
}
