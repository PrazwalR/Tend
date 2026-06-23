// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

contract E2EFixture is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        address manager = vm.envAddress("POOL_MANAGER");
        address rebalancer = vm.envAddress("REBALANCER_ADDRESS");
        uint64 cooldown = 3600;

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(manager), rebalancer, cooldown);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AutopilotHook).creationCode, args);

        vm.startBroadcast();
        AutopilotHook hook = new AutopilotHook{salt: salt}(IPoolManager(manager), rebalancer, cooldown);

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

        require(address(hook) == predicted, "hook addr mismatch");
        console2.log("HOOK", address(hook));
        console2.log("POSITION");
        console2.logBytes32(positionId);
    }
}
