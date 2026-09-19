// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

/// Stage 2: open a narrow position the daemon will have to rebalance. The
/// owner envelope is deliberately wide so the rebalancer has room to move.
contract E2EDeposit is Script {
    function run() external {
        AutopilotHook hook = AutopilotHook(vm.envAddress("HOOK"));
        MockERC20 t0 = MockERC20(vm.envAddress("TOKEN0"));
        MockERC20 t1 = MockERC20(vm.envAddress("TOKEN1"));
        int24 lower = int24(int256(vm.envOr("TICK_LOWER", int256(-600))));
        int24 upper = int24(int256(vm.envOr("TICK_UPPER", int256(600))));

        vm.startBroadcast();
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        PoolKey memory key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hook));
        bytes32 positionId =
            hook.deposit(key, lower, upper, 1e18, TickMath.minUsableTick(60), TickMath.maxUsableTick(60));
        vm.stopBroadcast();

        console2.log("POSITION=%s", vm.toString(positionId));
    }
}
