// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {HLPrecompiles} from "./HLPrecompiles.sol";

/// @notice Read a Hyperliquid perp price on HyperEVM and refuse it when the cheap-to-move
/// prices disagree with the hard-to-move ones, or with an independent reference.
///
/// The returned price is always the oracle (0x807). The BBO (0x80e) and mark (0x806) are
/// only used as tripwires: a pushed book shows up there first. See docs/safe-limits.md.
library HLPriceGuard {
    struct Asset {
        uint32 dex; // 0 for core perps
        uint32 index; // index within the dex
        uint8 szDecimals; // from 0x80a; pass it in to save a call
    }

    /// All bounds in basis points; 0 disables that check.
    struct Bounds {
        uint16 maxMarkOracleBps;
        uint16 maxMidOracleBps;
        uint16 maxSpreadBps;
        uint16 maxRefOracleBps;
    }

    /// An independent price fetched by the caller (e.g. PythRef). `price == 0` means none.
    struct Ref {
        uint256 price; // 1e18
        uint256 updatedAt; // unix seconds
        uint256 maxAge; // seconds
    }

    struct Quote {
        uint256 oracle;
        uint256 mark;
        uint256 bid;
        uint256 ask;
    }

    enum Breach {
        None,
        EmptyBook,
        Spread,
        MarkOracle,
        MidOracle,
        RefStale,
        RefOracle,
        Jump
    }

    error PriceRejected(Breach reason, uint256 observedBps, uint256 limitBps);

    function quote(Asset memory a) internal view returns (Quote memory q) {
        uint32 perp = HLPrecompiles.perpIndex(a.dex, a.index);
        q.oracle = HLPrecompiles.oracle(perp, a.szDecimals);
        q.mark = HLPrecompiles.mark(perp, a.szDecimals);
        (q.bid, q.ask) = HLPrecompiles.bbo(HLPrecompiles.bboIndex(a.dex, a.index), a.szDecimals);
    }

    /// |x - y| / y in bps, rounded up so a bound of N rejects anything above N.
    function diffBps(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 d = x > y ? x - y : y - x;
        return (d * 10_000 + y - 1) / y;
    }

    /// First failing check, without reverting. Use it for monitoring and for pausing.
    function check(Quote memory q, Bounds memory b, Ref memory r)
        internal
        view
        returns (Breach reason, uint256 observedBps, uint256 limitBps)
    {
        if (q.oracle == 0 || q.bid == 0 || q.ask <= q.bid) return (Breach.EmptyBook, 0, 0);
        uint256 mid = (q.bid + q.ask) / 2;
        uint256 v;
        if (b.maxSpreadBps != 0 && (v = diffBps(q.ask, q.bid)) > b.maxSpreadBps) {
            return (Breach.Spread, v, b.maxSpreadBps);
        }
        if (b.maxMarkOracleBps != 0 && (v = diffBps(q.mark, q.oracle)) > b.maxMarkOracleBps) {
            return (Breach.MarkOracle, v, b.maxMarkOracleBps);
        }
        if (b.maxMidOracleBps != 0 && (v = diffBps(mid, q.oracle)) > b.maxMidOracleBps) {
            return (Breach.MidOracle, v, b.maxMidOracleBps);
        }
        if (r.price != 0) {
            if (block.timestamp > r.updatedAt + r.maxAge) {
                return (Breach.RefStale, block.timestamp - r.updatedAt, r.maxAge);
            }
            if (b.maxRefOracleBps != 0 && (v = diffBps(q.oracle, r.price)) > b.maxRefOracleBps) {
                return (Breach.RefOracle, v, b.maxRefOracleBps);
            }
        }
        return (Breach.None, 0, 0);
    }

    /// For prices the caller stores between reads: reject an oracle that moved more than
    /// `maxJumpBps` since `prevPrice` was read at `prevAt`, if that was within `window`
    /// seconds. Matters most on HIP-3, where one deployer posts the oracle.
    function checkJump(uint256 oraclePx, uint256 prevPrice, uint256 prevAt, uint16 maxJumpBps, uint256 window)
        internal
        view
        returns (Breach reason, uint256 observedBps, uint256 limitBps)
    {
        if (prevPrice == 0 || block.timestamp > prevAt + window) return (Breach.None, 0, 0);
        uint256 v = diffBps(oraclePx, prevPrice);
        if (v > maxJumpBps) return (Breach.Jump, v, maxJumpBps);
        return (Breach.None, 0, 0);
    }

    /// The oracle price, or a revert naming the check that failed.
    function read(Asset memory a, Bounds memory b, Ref memory r) internal view returns (uint256) {
        Quote memory q = quote(a);
        (Breach reason, uint256 observed, uint256 limit) = check(q, b, r);
        if (reason != Breach.None) revert PriceRejected(reason, observed, limit);
        return q.oracle;
    }
}
