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
    error NoPrice(uint32 perp);

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

    /// Jump check with a latch, for contracts that read the oracle repeatedly.
    ///
    /// `anchor` is the last accepted oracle. A read more than `maxJumpBps` from it is a Jump and
    /// leaves the anchor where it was, so a bad price that then walks on in small steps keeps
    /// being rejected. Reads resume once the oracle is back within `maxJumpBps` of the anchor.
    /// Replayed on xyz:SKHX 2026-07-27 (cases/skhx-20260727): comparing only with the previous
    /// read let 39 updates between $870 and $955 through; the latch let none through.
    struct JumpLatch {
        uint256 anchor;
        uint64 anchorAt;
    }

    function observe(JumpLatch storage l, uint256 oraclePx, uint16 maxJumpBps)
        internal
        returns (Breach reason, uint256 observedBps, uint256 limitBps)
    {
        if (l.anchor != 0) {
            uint256 v = diffBps(oraclePx, l.anchor);
            if (v > maxJumpBps) return (Breach.Jump, v, maxJumpBps);
        }
        l.anchor = oraclePx;
        l.anchorAt = uint64(block.timestamp);
        return (Breach.None, 0, 0);
    }

    /// Move the anchor without the jump check. A real gap (a stock opening after a weekend)
    /// leaves the latch tripped until this is called; call it only after an independent
    /// reference agrees with `oraclePx`, or from governance.
    function rearm(JumpLatch storage l, uint256 oraclePx) internal {
        l.anchor = oraclePx;
        l.anchorAt = uint64(block.timestamp);
    }

    /// The oracle alone, with no tripwires, reverting when it is 0. The raw reads in HLPrecompiles
    /// return 0 as a price. Prefer `read`; this is for reads that must not be blocked by a wide book.
    /// It is a price at the moment of the call: when a price at a set time decides who is paid, the
    /// caller can choose whether and when to call, so take that price from an observation nobody
    /// chooses (e.g. Pyth's parsePriceFeedUpdatesUnique, the first update after the time).
    function oracleOnly(Asset memory a) internal view returns (uint256 px) {
        uint32 perp = HLPrecompiles.perpIndex(a.dex, a.index);
        px = HLPrecompiles.oracle(perp, a.szDecimals);
        if (px == 0) revert NoPrice(perp);
    }

    /// For liquidations: of the oracle and the mark, the one that favours the position: the higher
    /// for a long (or for collateral that is lent against), the lower for a short. A move against
    /// the position counts only once both feeds show it: one feed moving alone liquidates no one,
    /// and a real move that one feed has not caught up with waits for it, which can leave a debt.
    /// No tripwires, so a wide or empty book does not hold a liquidation back; but the mark follows
    /// the book, so pushing the book the position's way does, for as long as the push is held.
    /// Whoever can move both the oracle and the mark (a HIP-3 deployer, or a push that reached the
    /// oracle) can liquidate at that price. See docs/safe-limits.md section 5. Reverts when either
    /// price is 0.
    function lenientPrice(Asset memory a, bool long) internal view returns (uint256) {
        uint32 perp = HLPrecompiles.perpIndex(a.dex, a.index);
        uint256 o = HLPrecompiles.oracle(perp, a.szDecimals);
        uint256 m = HLPrecompiles.mark(perp, a.szDecimals);
        if (o == 0 || m == 0) revert NoPrice(perp);
        return long ? (o > m ? o : m) : (o < m ? o : m);
    }

    /// The oracle price, or a revert naming the check that failed.
    function read(Asset memory a, Bounds memory b, Ref memory r) internal view returns (uint256) {
        Quote memory q = quote(a);
        (Breach reason, uint256 observed, uint256 limit) = check(q, b, r);
        if (reason != Breach.None) revert PriceRejected(reason, observed, limit);
        return q.oracle;
    }
}
