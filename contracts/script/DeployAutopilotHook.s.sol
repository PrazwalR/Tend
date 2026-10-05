// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

interface IFeedDescription {
    function description() external view returns (string memory);
}

/// Deploys and configures the hook in one run, whoever ends up owning it.
///
/// The hook is always deployed with the broadcaster as owner, configured, and
/// only then handed to `HOOK_OWNER` through Ownable2Step. Configuring under the
/// final owner instead skipped every configuration call whenever that owner was
/// a multisig, or whenever Foundry could not infer the signer (keystore, ledger),
/// and reported success anyway (re-audit TK-1).
contract DeployAutopilotHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    string constant SEQUENCER_FEED_DESCRIPTION = "L2 Sequencer Uptime Status Feed";
    /// Chainlink's L2 sequencer uptime feed on Base (verified on-chain: its
    /// description() is SEQUENCER_FEED_DESCRIPTION and it answers 0 = up).
    address constant BASE_SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint256 constant BASE_CHAIN_ID = 8453;

    function run() external returns (AutopilotHook hook) {
        address manager = vm.envAddress("POOL_MANAGER");
        address rebalancer = vm.envAddress("REBALANCER_ADDRESS");
        uint64 cooldown = uint64(vm.envOr("REBALANCE_COOLDOWN_SECS", uint256(3600)));
        // The pool this deployment accepts. With none given the allowlist is
        // still enforced, so deposits fail closed until the owner lists one.
        address token0 = vm.envOr("ALLOWED_POOL_TOKEN0", address(0));
        address token1 = vm.envOr("ALLOWED_POOL_TOKEN1", address(0));
        uint24 fee = uint24(vm.envOr("ALLOWED_POOL_FEE", uint256(0)));
        int24 spacing = int24(int256(vm.envOr("ALLOWED_POOL_TICK_SPACING", uint256(0))));
        // Chainlink L2 sequencer uptime feed; leave unset on L1.
        address seqFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));
        // On Base the feed is required and pinned. A description check alone
        // accepted any contract returning the right string, whose owner could
        // then report "up" forever (full audit GV-1); and a Base deploy with no
        // feed silently had no post-outage grace period.
        if (block.chainid == BASE_CHAIN_ID) {
            if (seqFeed == address(0)) seqFeed = BASE_SEQUENCER_FEED;
            require(seqFeed == BASE_SEQUENCER_FEED, "Base requires Chainlink's sequencer uptime feed");
        }
        // A pool key needs its fee and spacing: listing tokens alone listed a key
        // no pool can have, and the intended pool stayed closed (full audit GV-3).
        if (token0 != address(0) || token1 != address(0)) {
            require(token0 != address(0) && token1 != address(0), "set both ALLOWED_POOL_TOKEN0 and _TOKEN1");
            require(spacing > 0, "set ALLOWED_POOL_TICK_SPACING (and ALLOWED_POOL_FEE)");
        }

        vm.startBroadcast();
        // The address actually signing, whatever the signer type. `msg.sender`
        // inside a script is Foundry's default sender unless it can be inferred.
        (VmSafe.CallerMode mode, address deployer,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "broadcast not active");
        address finalOwner = vm.envOr("HOOK_OWNER", deployer);

        bytes memory args = abi.encode(IPoolManager(manager), deployer, rebalancer, cooldown);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, uint160(Hooks.AFTER_SWAP_FLAG), type(AutopilotHook).creationCode, args);
        hook = new AutopilotHook{salt: salt}(IPoolManager(manager), deployer, rebalancer, cooldown);
        require(address(hook) == predicted, "hook address mismatch");

        // All tightenings, so none waits on the timelock.
        hook.setAllowlistEnforced(true);
        bool listPool = token0 != address(0) && token1 != address(0);
        PoolKey memory key;
        if (listPool) {
            (address a, address b) = token0 < token1 ? (token0, token1) : (token1, token0);
            key = PoolKey(Currency.wrap(a), Currency.wrap(b), fee, spacing, IHooks(address(hook)));
            hook.setAllowedPool(key, true);
        }
        if (seqFeed != address(0)) {
            // Only Chainlink's feed, never a contract whoever set it controls
            // (re-audit TL-6). Its description is the cheapest positive check.
            require(
                keccak256(bytes(IFeedDescription(seqFeed).description()))
                    == keccak256(bytes(SEQUENCER_FEED_DESCRIPTION)),
                "not a Chainlink sequencer uptime feed"
            );
            hook.setSequencerUptimeFeed(seqFeed);
        }
        if (finalOwner != deployer) hook.transferOwnership(finalOwner);
        vm.stopBroadcast();

        // Assert what is deployed, not what was intended.
        require(hook.owner() == deployer, "owner not the deployer before handover");
        require(hook.allowlistEnforced(), "allowlist not enforced");
        if (listPool) require(hook.allowedPool(_id(key)), "pool not listed");
        require(hook.sequencerUptimeFeed() == seqFeed, "sequencer feed not set");
        if (finalOwner != deployer) require(hook.pendingOwner() == finalOwner, "handover not pending");

        console2.log("AutopilotHook deployed at", address(hook));
        if (!listPool) console2.log("WARNING: no pool listed; deposits are closed until setAllowedPool");
        if (finalOwner != deployer) {
            console2.log("Ownership handover pending. The new owner must call acceptOwnership():", finalOwner);
        }
    }

    function _id(PoolKey memory key) private pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}
