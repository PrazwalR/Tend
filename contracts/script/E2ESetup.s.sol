// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

/// Stage 1 of the end-to-end run: hook, pool, deep background liquidity and a
/// swap router. Deliberately does NOT deposit — the daemon must be watching
/// before the position is opened so it indexes PositionOpened from the live
/// stream.
contract E2ESetup is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        address manager = vm.envAddress("POOL_MANAGER");
        address rebalancer = vm.envAddress("REBALANCER_ADDRESS");
        uint64 cooldown = uint64(vm.envOr("REBALANCE_COOLDOWN_SECS", uint256(0)));

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(manager), rebalancer, cooldown);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AutopilotHook).creationCode, args);

        vm.startBroadcast();
        AutopilotHook hook = new AutopilotHook{salt: salt}(IPoolManager(manager), rebalancer, cooldown);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(msg.sender, 1e27);
        t1.mint(msg.sender, 1e27);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        PoolKey memory key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hook));
        IPoolManager(manager).initialize(key, SQRT_PRICE_1_1);

        // Background liquidity so swaps move the tick smoothly instead of
        // slamming into an empty book.
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(IPoolManager(manager));
        t0.approve(address(lp), type(uint256).max);
        t1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );

        PoolSwapTest sw = new PoolSwapTest(IPoolManager(manager));
        t0.approve(address(sw), type(uint256).max);
        t1.approve(address(sw), type(uint256).max);
        vm.stopBroadcast();

        require(address(hook) == predicted, "hook addr mismatch");
        console2.log("HOOK=%s", address(hook));
        console2.log("TOKEN0=%s", address(t0));
        console2.log("TOKEN1=%s", address(t1));
        console2.log("SWAPPER=%s", address(sw));
    }
}
