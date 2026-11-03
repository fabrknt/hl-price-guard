// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HLPriceGuard} from "../src/HLPriceGuard.sol";

/// The smallest use of the library: a contract that needs Hyperliquid's ETH price and would rather
/// revert than use one a single wallet can push. In your project, import from
/// "hl-price-guard/HLPriceGuard.sol" instead.
contract GuardedMarket {
    HLPriceGuard.Asset ETH = HLPriceGuard.Asset({dex: 0, index: 1, szDecimals: 4});
    // Bounds from docs/safe-limits.md for ETH. 0 turns a check off; no independent reference here.
    HLPriceGuard.Bounds BOUNDS =
        HLPriceGuard.Bounds({maxMarkOracleBps: 15, maxMidOracleBps: 15, maxSpreadBps: 10, maxRefOracleBps: 0});

    /// The oracle price (1e18), or a revert PriceRejected(reason, observedBps, limitBps).
    function price() public view returns (uint256) {
        return HLPriceGuard.read(ETH, BOUNDS, HLPriceGuard.Ref(0, 0, 0));
    }
}
