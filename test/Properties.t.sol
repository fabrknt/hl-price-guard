// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPriceGuard} from "../src/HLPriceGuard.sol";
import {PythRef, IPyth} from "../src/PythRef.sol";
import {HLPrecompiles} from "../src/HLPrecompiles.sol";
import {MockPrecompile, Harness} from "./HLPriceGuard.t.sol";

/// Pyth with fees: charges `feePerUpdate` per update and requires exactly that as msg.value.
contract FeePyth {
    IPyth.Price internal p;
    uint256 public feePerUpdate;
    uint256 public updates;
    uint256 public calls;
    uint256 public received;

    constructor(uint256 fee) {
        feePerUpdate = fee;
    }

    function setPrice(int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        p = IPyth.Price(price, conf, expo, publishTime);
    }

    function getPriceUnsafe(bytes32) external view returns (IPyth.Price memory) {
        return p;
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return updateData.length * feePerUpdate;
    }

    /// Each update is abi.encode(int64 price, uint256 publishTime).
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        require(msg.value == updateData.length * feePerUpdate, "fee");
        for (uint256 i; i < updateData.length; i++) {
            (int64 price, uint256 t) = abi.decode(updateData[i], (int64, uint256));
            p = IPyth.Price(price, p.conf, p.expo, t);
        }
        updates += updateData.length;
        calls++;
        received += msg.value;
    }
}

contract PythCaller {
    function updateAndRead(IPyth pyth, bytes[] calldata data, uint256 maxAge)
        external
        returns (HLPriceGuard.Ref memory)
    {
        return PythRef.updateAndRead(pyth, data, bytes32(0), maxAge, 0);
    }

    receive() external payable {}
}

contract LatchHolder {
    HLPriceGuard.JumpLatch public latch;

    function observe(uint256 px, uint16 maxBps) external returns (HLPriceGuard.Breach r) {
        (r,,) = HLPriceGuard.observe(latch, px, maxBps);
    }
}

contract PropertiesTest is Test {
    // ---- HLPriceGuard.check: whatever it returns is consistent with the bounds ----

    function _diff(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : y - x;
    }

    /// diffBps rounds up: a bound of N bps accepts exactly the gaps of at most N bps.
    function testFuzz_diffBpsRoundsUp(uint256 x, uint256 y) public pure {
        x = bound(x, 0, 1e36);
        y = bound(y, 1, 1e36);
        uint256 v = HLPriceGuard.diffBps(x, y);
        assertGe(v * y, _diff(x, y) * 10_000); // never under-reports
        if (v != 0) assertLt((v - 1) * y, _diff(x, y) * 10_000); // by less than 1 bp
    }

    /// None means every enabled check holds; a breach reports a value over its limit.
    function testFuzz_checkIsConsistent(
        uint256 oracle,
        int256 markMove,
        int256 midMove,
        uint256 spread,
        uint256 refPrice,
        uint256 refAge,
        uint16[4] memory lim
    ) public {
        vm.warp(2_000_000_000);
        oracle = bound(oracle, 1e12, 1e30);
        HLPriceGuard.Quote memory q;
        q.oracle = oracle;
        q.mark = _move(oracle, bound(markMove, -500, 500));
        uint256 mid = _move(oracle, bound(midMove, -500, 500));
        uint256 half = mid * bound(spread, 0, 100) / 20_000;
        (q.bid, q.ask) = (mid - half, mid + half);
        HLPriceGuard.Bounds memory b = HLPriceGuard.Bounds(lim[0] % 300, lim[1] % 300, lim[2] % 300, lim[3] % 300);
        HLPriceGuard.Ref memory r;
        if (refPrice % 3 != 0) {
            r = HLPriceGuard.Ref(_move(oracle, int256(refPrice % 1001) - 500), block.timestamp - bound(refAge, 0, 120), 60);
        }

        (HLPriceGuard.Breach why, uint256 seen, uint256 limit) = HLPriceGuard.check(q, b, r);
        if (why == HLPriceGuard.Breach.None) {
            assertTrue(q.bid != 0 && q.ask > q.bid, "book");
            if (b.maxSpreadBps != 0) assertLe(HLPriceGuard.diffBps(q.ask, q.bid), b.maxSpreadBps, "spread");
            if (b.maxMarkOracleBps != 0) assertLe(HLPriceGuard.diffBps(q.mark, q.oracle), b.maxMarkOracleBps, "mark");
            uint256 m = (q.bid + q.ask) / 2;
            if (b.maxMidOracleBps != 0) assertLe(HLPriceGuard.diffBps(m, q.oracle), b.maxMidOracleBps, "mid");
            if (r.price != 0) {
                assertLe(block.timestamp, r.updatedAt + r.maxAge, "ref age");
                if (b.maxRefOracleBps != 0) assertLe(HLPriceGuard.diffBps(q.oracle, r.price), b.maxRefOracleBps, "ref");
            }
        } else if (why != HLPriceGuard.Breach.EmptyBook) {
            assertGt(seen, limit, "breach over its limit");
        }
    }

    function _move(uint256 px, int256 bps) internal pure returns (uint256) {
        return bps >= 0 ? px * (10_000 + uint256(bps)) / 10_000 : px * (10_000 - uint256(-bps)) / 10_000;
    }

    // ---- JumpLatch: the anchor moves only on an accepted read, and only by at most maxJumpBps ----

    function testFuzz_latchAnchorOnlyMovesOnAccept(uint256 start, int16[24] memory steps, uint16 maxBps) public {
        LatchHolder l = new LatchHolder();
        maxBps = uint16(bound(maxBps, 1, 2000));
        uint256 px = bound(start, 1e12, 1e30);
        for (uint256 i; i < steps.length; i++) {
            (uint256 before,) = l.latch();
            px = _move(px, int256(steps[i]) % 3000);
            if (px == 0) px = 1;
            HLPriceGuard.Breach r = l.observe(px, maxBps);
            (uint256 anchor,) = l.latch();
            if (r == HLPriceGuard.Breach.None) {
                assertEq(anchor, px, "accepted read becomes the anchor");
                if (before != 0) assertLe(HLPriceGuard.diffBps(px, before), maxBps, "accepted within the bound");
            } else {
                assertEq(uint8(r), uint8(HLPriceGuard.Breach.Jump));
                assertEq(anchor, before, "rejected read leaves the anchor");
            }
        }
    }

    // ---- lenientPrice: one of the two prices, the one on the position's side ----

    function testFuzz_lenientPriceIsTheFavourableFeed(uint64 o, uint64 m, bool long) public {
        address mock = address(new MockPrecompile());
        vm.etch(HLPrecompiles.ORACLE_PX, mock.code);
        vm.etch(HLPrecompiles.MARK_PX, mock.code);
        MockPrecompile(HLPrecompiles.ORACLE_PX).set(1, abi.encode(o));
        MockPrecompile(HLPrecompiles.MARK_PX).set(1, abi.encode(m));
        Harness h = new Harness();
        HLPriceGuard.Asset memory a = HLPriceGuard.Asset(0, 1, 4);
        if (o == 0 || m == 0) {
            vm.expectRevert(abi.encodeWithSelector(HLPriceGuard.NoPrice.selector, uint32(1)));
            h.lenientPrice(a, long);
            return;
        }
        uint256 px = h.lenientPrice(a, long);
        (uint256 o18, uint256 m18) = (uint256(o) * 1e16, uint256(m) * 1e16);
        assertTrue(px == o18 || px == m18, "one of the two feeds");
        if (long) assertTrue(px >= o18 && px >= m18, "long: no lower than either");
        else assertTrue(px <= o18 && px <= m18, "short: no higher than either");
    }

    // ---- PythRef.updateAndRead ----

    function test_updateAndReadPaysTheFeeAndReadsTheUpdate() public {
        vm.warp(1_800_000_000);
        FeePyth pyth = new FeePyth(7 wei);
        pyth.setPrice(100e8, 0, -8, 1_700_000_000); // stale
        PythCaller c = new PythCaller();
        vm.deal(address(c), 1 ether);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(int64(2400e8), uint256(block.timestamp - 5));
        data[1] = abi.encode(int64(2427e8), uint256(block.timestamp));

        HLPriceGuard.Ref memory r = c.updateAndRead(IPyth(address(pyth)), data, 60);
        assertEq(r.price, 2427e18);
        assertEq(r.updatedAt, block.timestamp);
        assertEq(r.maxAge, 60);
        assertEq(pyth.received(), 14 wei, "fee from the caller's balance");
        assertEq(address(c).balance, 1 ether - 14 wei);
    }

    function test_updateAndReadWithoutDataOnlyReads() public {
        FeePyth pyth = new FeePyth(7 wei);
        pyth.setPrice(100e8, 0, -8, 1_700_000_000);
        PythCaller c = new PythCaller();
        HLPriceGuard.Ref memory r = c.updateAndRead(IPyth(address(pyth)), new bytes[](0), 60);
        assertEq(r.price, 100e18);
        assertEq(pyth.calls(), 0, "no update call at all");
    }

    function test_updateAndReadRevertsWithoutFeeBalance() public {
        FeePyth pyth = new FeePyth(7 wei);
        PythCaller c = new PythCaller(); // no balance
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(int64(2427e8), uint256(1));
        vm.expectRevert();
        c.updateAndRead(IPyth(address(pyth)), data, 60);
    }
}
