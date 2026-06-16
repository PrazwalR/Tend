// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

contract DeployAutopilotHookTest is Test, Deployers {
    function test_mine_and_deploy_valid_hook_address() public {
        deployFreshManagerAndRouters();

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(manager, address(0xBEEF), uint64(3600));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AutopilotHook).creationCode, args);

        AutopilotHook hook = new AutopilotHook{salt: salt}(manager, address(0xBEEF), uint64(3600));

        assertEq(address(hook), predicted);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
        assertTrue(hook.getHookPermissions().afterSwap);
        assertTrue(hook.isRebalancer(address(0xBEEF)));
        assertEq(hook.minRebalanceInterval(), 3600);
    }
}
