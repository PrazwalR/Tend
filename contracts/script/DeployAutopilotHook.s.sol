// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

contract DeployAutopilotHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (AutopilotHook hook) {
        address manager = vm.envAddress("POOL_MANAGER");
        address rebalancer = vm.envAddress("REBALANCER_ADDRESS");
        uint64 cooldown = uint64(vm.envOr("REBALANCE_COOLDOWN_SECS", uint256(3600)));

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(manager), rebalancer, cooldown);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AutopilotHook).creationCode, args);

        vm.startBroadcast();
        hook = new AutopilotHook{salt: salt}(IPoolManager(manager), rebalancer, cooldown);
        vm.stopBroadcast();

        require(address(hook) == predicted, "hook address mismatch");
        console2.log("AutopilotHook deployed at", address(hook));
    }
}
