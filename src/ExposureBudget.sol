// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @notice Cap how much notional can be settled against one price within a time window.
///
/// A bounds check limits how far the price can be moved without being noticed; this caps
/// how much that move can be worth. Size the cap with `safeCap` (docs/safe-limits.md).
///
/// Two budgets:
/// - `Rolling` (use this): no stretch of `windowSecs` ever settles more than `cap` (more than
///   the largest cap in force during it, if `reconfigure` lowered it).
/// - `Window`: a fixed window that resets, so up to `2 * cap` can settle across a reset.
///   Kept for existing users.
library ExposureBudget {
    struct Window {
        uint64 start;
        uint192 used;
    }

    /// Sub-buckets per window. The check counts the current bucket and the SLICES before it,
    /// so it sees between `windowSecs` and `windowSecs + windowSecs / SLICES` of history:
    /// strict, and conservative by under one slice (a full-cap burst on a 60 s window waits
    /// up to 70 s for the next).
    uint256 internal constant SLICES = 6;

    /// `cap` and `windowSecs` are bound on first use; changing them mid-life would let more than
    /// either cap settle within one window, so it goes through `reconfigure`.
    struct Rolling {
        uint64 windowSecs;
        uint192 cap;
        uint64 lastSpendAt; // the slots forget after one window; reconfigure needs the last spend
        uint256[7] slots; // SLICES + 1; each packs (uint64 epoch << 192 | uint192 amount)
    }

    error BudgetExceeded(uint256 used, uint256 requested, uint256 cap);
    error BadWindow(uint256 windowSecs);
    error CapTooLarge(uint256 cap);
    error ConfigChanged(uint256 cap, uint256 windowSecs);
    error NotDrained(uint256 readyAt);

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

    function spend(Rolling storage r, uint256 notional, uint256 cap, uint64 windowSecs) internal {
        if (r.windowSecs == 0) _configure(r, cap, windowSecs);
        else if (r.cap != cap || r.windowSecs != windowSecs) revert ConfigChanged(r.cap, r.windowSecs);

        uint256 e = block.timestamp / (windowSecs / SLICES);
        uint256 sum = _sum(r, e);
        if (sum > cap || notional > cap - sum) revert BudgetExceeded(sum, notional, cap);

        uint256 i = e % (SLICES + 1);
        uint256 slot = r.slots[i];
        uint256 amount = slot >> 192 == e ? uint192(slot) : 0;
        // amount + notional <= cap <= uint192.max; e < 2**64 for any realistic timestamp.
        r.slots[i] = (uint256(uint64(e)) << 192) | (amount + notional);
        if (notional != 0) r.lastSpendAt = uint64(block.timestamp);
    }

    /// Notional counted against the cap right now.
    function used(Rolling storage r) internal view returns (uint256) {
        if (r.windowSecs == 0) return 0;
        return _sum(r, block.timestamp / (r.windowSecs / SLICES));
    }

    /// Change cap or window. Lowering the cap alone takes effect at once for new spends (it does
    /// not undo what already settled, so a stretch spanning the change is bounded by the higher
    /// cap); anything else waits until nothing settled under the old settings is inside either
    /// window. Either way no stretch of the window settles more than the largest cap in force
    /// during it.
    function reconfigure(Rolling storage r, uint256 cap, uint64 windowSecs) internal {
        _check(cap, windowSecs);
        if (r.windowSecs == windowSecs && cap <= r.cap) {
            r.cap = uint192(cap);
            return;
        }
        if (r.windowSecs != 0) {
            // Wait until the last spend is outside [t - W, t] for both the old and the new window.
            uint256 longer = windowSecs > r.windowSecs ? windowSecs : r.windowSecs;
            uint256 readyAt = uint256(r.lastSpendAt) + longer + 1;
            if (r.lastSpendAt != 0 && block.timestamp < readyAt) revert NotDrained(readyAt);
            delete r.slots;
        }
        _configure(r, cap, windowSecs);
    }

    function _configure(Rolling storage r, uint256 cap, uint64 windowSecs) private {
        _check(cap, windowSecs);
        r.cap = uint192(cap);
        r.windowSecs = windowSecs;
    }

    function _check(uint256 cap, uint64 windowSecs) private pure {
        if (windowSecs < SLICES || windowSecs % SLICES != 0) revert BadWindow(windowSecs);
        if (cap > type(uint192).max) revert CapTooLarge(cap);
    }

    function _sum(Rolling storage r, uint256 e) private view returns (uint256 sum) {
        uint256 first = e > SLICES ? e - SLICES : 0;
        for (uint256 i; i <= SLICES; ++i) {
            uint256 slot = r.slots[i];
            uint256 se = slot >> 192;
            if (se >= first && se <= e) sum += uint192(slot);
        }
    }
}
