// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @notice Cap how much notional can be settled against one price within a time window.
///
/// A bounds check limits how far the price can be moved without being noticed; this caps
/// how much that move can be worth. Size the cap with `safeCap` (docs/safe-limits.md).
library ExposureBudget {
    struct Window {
        uint64 start;
        uint192 used;
    }

    error BudgetExceeded(uint256 used, uint256 requested, uint256 cap);

    /// Largest exposure E for which moving the price by `moveBps` pays less than it costs:
    /// E * moveBps / 1e4 * safetyFactor <= cost.
    function safeCap(uint256 costToMove, uint256 moveBps, uint256 safetyFactor) internal pure returns (uint256) {
        return costToMove * 10_000 / (moveBps * safetyFactor);
    }

    function spend(Window storage w, uint256 notional, uint256 cap, uint64 windowSecs) internal {
        if (block.timestamp >= uint256(w.start) + windowSecs) {
            w.start = uint64(block.timestamp);
            w.used = 0;
        }
        uint256 used = w.used;
        if (used + notional > cap) revert BudgetExceeded(used, notional, cap);
        w.used = uint192(used + notional);
    }
}
