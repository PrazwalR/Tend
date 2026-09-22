// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Chainlink aggregator surface. Only the fields the hook
///         actually reads, so a feed that omits the rest still works.
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
