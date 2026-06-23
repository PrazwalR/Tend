// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

contract DepositOnly is Script {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        address hookAddr = vm.envAddress("HOOK");
        address manager = vm.envAddress("POOL_MANAGER");
        AutopilotHook hook = AutopilotHook(hookAddr);

        vm.startBroadcast();
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(msg.sender, 1e24);
        t1.mint(msg.sender, 1e24);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        PoolKey memory key =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hook));
        IPoolManager(manager).initialize(key, SQRT_PRICE_1_1);
        bytes32 positionId = hook.deposit(key, -600, 600, 1e18, -1200, 1200);
        vm.stopBroadcast();

        console2.log("POSITION");
        console2.logBytes32(positionId);
    }
}
