// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPrecompiles} from "../src/HLPrecompiles.sol";
import {HLPriceGuard} from "../src/HLPriceGuard.sol";
import {ExposureBudget} from "../src/ExposureBudget.sol";
import {PythRef, IPyth} from "../src/PythRef.sol";

/// Etched at a precompile address: returns whatever was set for the 32-byte input,
/// and fails (like the real precompiles) for anything unset.
contract MockPrecompile {
    mapping(bytes32 => bytes) internal ret;

    function set(uint32 index, bytes calldata out) external {
        ret[keccak256(abi.encode(index))] = out;
    }

    fallback(bytes calldata input) external returns (bytes memory out) {
        out = ret[keccak256(input)];
        require(out.length != 0, "PrecompileError");
    }
}

contract MockPyth {
    IPyth.Price internal p;

    function setPrice(int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        p = IPyth.Price(price, conf, expo, publishTime);
    }

    function getPriceUnsafe(bytes32) external view returns (IPyth.Price memory) {
        return p;
    }
}

/// External entry points so reverts can be asserted.
contract Harness {
    using ExposureBudget for ExposureBudget.Window;
    using ExposureBudget for ExposureBudget.Rolling;

    ExposureBudget.Rolling internal rolling;

    function spendRolling(uint256 notional, uint256 cap, uint64 windowSecs) external {
        rolling.spend(notional, cap, windowSecs);
    }

    function usedRolling() external view returns (uint256) {
        return rolling.used();
    }

    function reconfigure(uint256 cap, uint64 windowSecs) external {
        rolling.reconfigure(cap, windowSecs);
    }

    ExposureBudget.Window public window;

    function read(HLPriceGuard.Asset memory a, HLPriceGuard.Bounds memory b, HLPriceGuard.Ref memory r)
        external
        view
        returns (uint256)
    {
        return HLPriceGuard.read(a, b, r);
    }

    function pyth(address p, uint256 maxAge, uint16 maxConfBps) external view returns (HLPriceGuard.Ref memory) {
        return PythRef.read(IPyth(p), bytes32(0), maxAge, maxConfBps);
    }

    HLPriceGuard.JumpLatch public latch;

    function observe(uint256 px, uint16 maxBps) external returns (HLPriceGuard.Breach r, uint256 v) {
        (r, v,) = HLPriceGuard.observe(latch, px, maxBps);
    }

    function rearm(uint256 px) external {
        HLPriceGuard.rearm(latch, px);
    }

    function spend(uint256 notional, uint256 cap, uint64 windowSecs) external {
        window.spend(notional, cap, windowSecs);
    }
}

contract HLPriceGuardTest is Test {
    Harness h;
    HLPriceGuard.Asset eth = HLPriceGuard.Asset({dex: 0, index: 1, szDecimals: 4});
    HLPriceGuard.Asset tsla = HLPriceGuard.Asset({dex: 1, index: 1, szDecimals: 3});
    HLPriceGuard.Bounds bounds =
        HLPriceGuard.Bounds({maxMarkOracleBps: 15, maxMidOracleBps: 15, maxSpreadBps: 10, maxRefOracleBps: 50});
    HLPriceGuard.Ref none;

    function setUp() public {
        address mockCode = address(new MockPrecompile());
        vm.etch(HLPrecompiles.ORACLE_PX, mockCode.code);
        vm.etch(HLPrecompiles.MARK_PX, mockCode.code);
        vm.etch(HLPrecompiles.BBO, mockCode.code);
        h = new Harness();
        vm.warp(1792190822);
        // Mainnet ETH (index 1), 2026-10-17: oracle 2427.23, mark 2426.12, bbo 2426.30 / 2426.40.
        setEth(242723, 242612, 242630, 242640);
    }

    function setEth(uint64 oracle, uint64 mark, uint64 bid, uint64 ask) internal {
        MockPrecompile(HLPrecompiles.ORACLE_PX).set(1, abi.encode(oracle));
        MockPrecompile(HLPrecompiles.MARK_PX).set(1, abi.encode(mark));
        MockPrecompile(HLPrecompiles.BBO).set(1, abi.encode(bid, ask));
    }

    function rejectReason(HLPriceGuard.Ref memory r) internal view returns (HLPriceGuard.Breach, uint256) {
        try h.read(eth, bounds, r) {
            return (HLPriceGuard.Breach.None, 0);
        } catch (bytes memory err) {
            assertEq(bytes4(err), HLPriceGuard.PriceRejected.selector);
            (HLPriceGuard.Breach got, uint256 observed,) =
                abi.decode(_args(err), (HLPriceGuard.Breach, uint256, uint256));
            return (got, observed);
        }
    }

    function _args(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = err[i + 4];
        }
    }

    function test_indexEncodings() public pure {
        assertEq(HLPrecompiles.perpIndex(0, 1), 1);
        assertEq(HLPrecompiles.bboIndex(0, 1), 1);
        assertEq(HLPrecompiles.perpIndex(1, 1), 10001); // xyz:TSLA on 0x807
        assertEq(HLPrecompiles.bboIndex(1, 1), 110001); // xyz:TSLA on 0x80e
    }

    function test_normalBookReturnsOracle() public view {
        assertEq(h.read(eth, bounds, none), 2427.23e18);
    }

    function test_hip3UsesBothEncodings() public {
        // Mainnet xyz:TSLA, 2026-10-17: oracle 352.530, mark 352.560, bbo 352.620 / 352.630.
        MockPrecompile(HLPrecompiles.ORACLE_PX).set(10001, abi.encode(uint64(352530)));
        MockPrecompile(HLPrecompiles.MARK_PX).set(10001, abi.encode(uint64(352560)));
        MockPrecompile(HLPrecompiles.BBO).set(110001, abi.encode(uint64(352620), uint64(352630)));
        assertEq(h.read(tsla, bounds, none), 352.53e18);
    }

    /// Papertrade's 16 bp round (21:41 UTC): the book is pushed, the oracle is not.
    function test_papertradeLargePushIsRejected() public {
        uint64 pushed = uint64(242723) * 10016 / 10000;
        setEth(242723, 242612, pushed - 5, pushed + 5);
        (HLPriceGuard.Breach r, uint256 bps) = rejectReason(none);
        assertEq(uint8(r), uint8(HLPriceGuard.Breach.MidOracle));
        assertEq(bps, 16);
    }

    /// Papertrade's 7 bp round passes a 15 bp bound (2x ETH's normal 7.2 bp). Bounds alone do not stop it, which is
    /// why the settled notional has to be capped as well (test_exposureCap*).
    function test_papertradeSmallPushPassesBounds() public {
        uint64 pushed = uint64(242723) * 10007 / 10000;
        setEth(242723, 242612, pushed - 5, pushed + 5);
        assertEq(h.read(eth, bounds, none), 2427.23e18); // and the price is still the oracle
    }

    function test_emptyOrCrossedBook() public {
        setEth(242723, 242612, 0, 242640);
        (HLPriceGuard.Breach r,) = rejectReason(none);
        assertEq(uint8(r), uint8(HLPriceGuard.Breach.EmptyBook));
        setEth(242723, 242612, 242640, 242630);
        (r,) = rejectReason(none);
        assertEq(uint8(r), uint8(HLPriceGuard.Breach.EmptyBook));
    }

    function test_wideSpread() public {
        setEth(242723, 242612, 242500, 242800); // 13 bp
        (HLPriceGuard.Breach r, uint256 bps) = rejectReason(none);
        assertEq(uint8(r), uint8(HLPriceGuard.Breach.Spread));
        assertEq(bps, 13);
    }

    function test_markOracle() public {
        setEth(242723, 243500, 242720, 242730); // mark 33 bp above oracle
        (HLPriceGuard.Breach r,) = rejectReason(none);
        assertEq(uint8(r), uint8(HLPriceGuard.Breach.MarkOracle));
    }

    function test_unsetPrecompileReverts() public {
        HLPriceGuard.Asset memory unknown = HLPriceGuard.Asset({dex: 0, index: 999, szDecimals: 0});
        vm.expectRevert(
            abi.encodeWithSelector(HLPrecompiles.PrecompileFailed.selector, HLPrecompiles.ORACLE_PX, uint32(999))
        );
        h.read(unknown, bounds, none);
    }

    function test_zeroBoundsDisableChecks() public {
        setEth(242723, 250000, 242000, 243000);
        HLPriceGuard.Bounds memory off;
        assertEq(h.read(eth, off, none), 2427.23e18);
    }

    function test_referenceFreshAndClose() public view {
        HLPriceGuard.Ref memory r = HLPriceGuard.Ref(2430e18, block.timestamp - 5, 10);
        assertEq(h.read(eth, bounds, r), 2427.23e18);
    }

    function test_referenceStale() public view {
        HLPriceGuard.Ref memory r = HLPriceGuard.Ref(2430e18, block.timestamp - 11, 10);
        (HLPriceGuard.Breach reason, uint256 age) = rejectReason(r);
        assertEq(uint8(reason), uint8(HLPriceGuard.Breach.RefStale));
        assertEq(age, 11);
    }

    /// If the oracle itself moves (a HIP-3 deployer posts a bad price), only the reference catches it.
    function test_referenceCatchesMovedOracle() public {
        setEth(250000, 250000, 249995, 250005); // whole HL side 3% higher, internally consistent
        HLPriceGuard.Ref memory r = HLPriceGuard.Ref(2427e18, block.timestamp, 10);
        (HLPriceGuard.Breach reason, uint256 bps) = rejectReason(r);
        assertEq(uint8(reason), uint8(HLPriceGuard.Breach.RefOracle));
        assertEq(bps, 301);
    }

    /// SK Hynix (xyz:SKHX), 2026-07-27: all 144 deployer oracle updates, 22:57:36-23:04:45 UTC.
    /// The first bad update ($1,131.40 -> $954.99) is followed by -100 bp steps down to $870,
    /// each small enough to pass a 200 bp check against the previous read.
    function test_jumpLatchOnSkhx() public {
        string memory json = vm.readFile("cases/skhx-20260727/skhx-oracle.json");
        uint256 accepted;
        uint256 acceptedBelow1000;
        uint256 firstJumpBps;
        for (uint256 i; i < 144; i++) {
            uint256 px = vm.parseJsonUint(json, string.concat(".updates[", vm.toString(i), "][3]"));
            (HLPriceGuard.Breach r, uint256 v) = h.observe(px, 200);
            if (r == HLPriceGuard.Breach.None) {
                accepted++;
                if (px < 1000_00) acceptedBelow1000++;
            } else if (firstJumpBps == 0) {
                firstJumpBps = v;
            }
        }
        assertEq(firstJumpBps, 1560); // 23:00:03.946, 1559.2 rounded up
        assertEq(acceptedBelow1000, 0);
        assertEq(accepted, 100); // same as P3 in replay_c.py
    }

    function test_jumpLatchNeedsRearmAfterRealGap() public {
        h.observe(100, 200);
        (HLPriceGuard.Breach r,) = h.observe(105, 200); // a 5% opening gap
        assertEq(uint8(r), uint8(HLPriceGuard.Breach.Jump));
        (r,) = h.observe(105, 200);
        assertEq(uint8(r), uint8(HLPriceGuard.Breach.Jump)); // stays tripped
        h.rearm(105);
        (r,) = h.observe(105, 200);
        assertEq(uint8(r), uint8(HLPriceGuard.Breach.None));
    }

    function test_pythNormalizes() public {
        MockPyth p = new MockPyth();
        // Mainnet HyperEVM ETH/USD as stored on 2026-10-17.
        p.setPrice(244053202377, 221997623, -8, 1792163987);
        HLPriceGuard.Ref memory r = h.pyth(address(p), 10, 50);
        assertEq(r.price, 2440.53202377e18);
        assertEq(r.updatedAt, 1792163987);
        // That stored value is 7.5 hours old: unusable without a same-tx update.
        (HLPriceGuard.Breach reason,) = rejectReason(r);
        assertEq(uint8(reason), uint8(HLPriceGuard.Breach.RefStale));
    }

    function test_pythWideConfidence() public {
        MockPyth p = new MockPyth();
        p.setPrice(244053202377, 2440532023, -8, block.timestamp); // 100 bp
        vm.expectRevert(abi.encodeWithSelector(PythRef.PythConfTooWide.selector, bytes32(0), 100, 50));
        h.pyth(address(p), 10, 50);
    }

    /// Papertrade numbers: ~$10K to hold ETH's mid ~10 bp for a minute.
    function test_exposureCapFromPapertrade() public pure {
        assertEq(ExposureBudget.safeCap(10_000e18, 10, 3), 3_333_333.333333333333333333e18);
    }

    function test_exposureCapPerWindow() public {
        uint256 cap = 3_000_000e18;
        h.spend(2_000_000e18, cap, 60);
        vm.expectRevert(
            abi.encodeWithSelector(ExposureBudget.BudgetExceeded.selector, 2_000_000e18, 2_000_000e18, cap)
        );
        h.spend(2_000_000e18, cap, 60);
        vm.warp(block.timestamp + 60);
        h.spend(2_000_000e18, cap, 60); // new window
    }

    // ---- Rolling: no stretch of windowSecs settles more than cap ----

    uint256 constant CAP = 3_000_000e18;

    function _exceeded(uint256 used, uint256 req) internal {
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.BudgetExceeded.selector, used, req, CAP));
    }

    function test_rollingClosesTheFixedWindowGap() public {
        // The fixed window lets 2 x cap through across a reset: cap at t=659, cap again at t=660.
        vm.warp(600);
        h.spend(1, CAP, 60); // opens a window at 600
        vm.warp(659);
        h.spend(CAP - 1, CAP, 60);
        vm.warp(660);
        h.spend(CAP, CAP, 60);
        // Rolling refuses the same pattern.
        vm.warp(659);
        h.spendRolling(CAP, CAP, 60);
        vm.warp(660);
        _exceeded(CAP, CAP);
        h.spendRolling(CAP, CAP, 60);
    }

    function test_rollingAtEarlyTimestamps() public {
        vm.warp(5); // epoch 0, below SLICES: the lower bound clamps instead of underflowing
        h.spendRolling(CAP, CAP, 60);
        vm.warp(59);
        _exceeded(CAP, 1);
        h.spendRolling(1, CAP, 60);
    }

    function test_rollingExactBoundary() public {
        vm.warp(600); // epoch 60
        h.spendRolling(CAP, CAP, 60);
        vm.warp(660); // epoch 66 still counts epoch 60
        _exceeded(CAP, CAP);
        h.spendRolling(CAP, CAP, 60);
        vm.warp(670); // epoch 67 reuses slot 60 % 7 and drops it
        h.spendRolling(CAP, CAP, 60);
        assertEq(h.usedRolling(), CAP);
    }

    function test_rollingSpreadsAcrossSlices() public {
        for (uint256 t = 600; t < 660; t += 10) {
            vm.warp(t);
            h.spendRolling(CAP / 6, CAP, 60);
        }
        vm.warp(665);
        _exceeded(CAP, 1); // 600's bucket is still inside [epoch 60, 66]
        h.spendRolling(1, CAP, 60);
        vm.warp(670);
        h.spendRolling(CAP / 6, CAP, 60);
    }

    function test_rollingSparseGapsAndSameBlock() public {
        vm.warp(1_000);
        h.spendRolling(CAP / 2, CAP, 60);
        h.spendRolling(CAP / 2, CAP, 60); // same block, same slot
        _exceeded(CAP, 1);
        h.spendRolling(1, CAP, 60);
        vm.warp(1_000 + 7 * 3600); // long gap: stale slots are ignored by epoch
        assertEq(h.usedRolling(), 0);
        h.spendRolling(CAP, CAP, 60);
    }

    function test_rollingRejectsConfigChange() public {
        vm.warp(100);
        h.spendRolling(CAP, CAP, 60);
        vm.warp(110);
        // Codex's counterexample: widening the window to 120 s would hide the first spend.
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.ConfigChanged.selector, CAP, 60));
        h.spendRolling(CAP, CAP, 120);
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.ConfigChanged.selector, CAP, 60));
        h.spendRolling(CAP, 2 * CAP, 60);
    }

    function test_rollingReconfigure() public {
        vm.warp(100); // epoch 10, bucket ends at 110
        h.spendRolling(CAP, CAP, 60);
        h.reconfigure(CAP / 2, 60); // lowering the cap alone is immediate
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.NotDrained.selector, 110 + 120));
        h.reconfigure(CAP, 120);
        vm.warp(230);
        h.reconfigure(CAP, 120);
        h.spendRolling(CAP, CAP, 120);
    }

    function test_rollingBounds() public {
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.BadWindow.selector, 5));
        h.spendRolling(1, CAP, 5);
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.BadWindow.selector, 61));
        h.spendRolling(1, CAP, 61);
        uint256 big = uint256(type(uint192).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.CapTooLarge.selector, big));
        h.spendRolling(1, big, 60);
        vm.warp(100);
        h.spendRolling(1, CAP, 60);
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.BudgetExceeded.selector, 1, type(uint256).max, CAP));
        h.spendRolling(type(uint256).max, CAP, 60); // no overflow in the comparison
    }

    /// Any order of spends: no 60 s stretch ever settles more than the cap.
    function testFuzz_rollingNeverExceedsCap(uint32[24] memory gaps, uint64[24] memory amounts) public {
        uint256[24] memory ts;
        uint256[24] memory ok;
        uint256 t = 1_000;
        for (uint256 i; i < 24; ++i) {
            t += gaps[i] % 25;
            vm.warp(t);
            uint256 a = amounts[i] % (CAP / 1e12) * 1e12;
            try h.spendRolling(a, CAP, 60) { ok[i] = a; } catch {}
            ts[i] = t;
        }
        for (uint256 i; i < 24; ++i) {
            uint256 sum;
            for (uint256 j = i; j < 24 && ts[j] <= ts[i] + 60; ++j) sum += ok[j];
            assertLe(sum, CAP);
        }
    }

    function test_rollingReconfigureValidatesFirst() public {
        vm.warp(100);
        h.spendRolling(CAP, CAP, 60);
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.BadWindow.selector, 61));
        h.reconfigure(CAP, 61);
        uint256 big = uint256(type(uint192).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.CapTooLarge.selector, big));
        h.reconfigure(big, 60);
    }

    function test_rollingLowerCapIsNotRetroactive() public {
        vm.warp(100);
        h.spendRolling(CAP, CAP, 60);
        h.reconfigure(CAP / 2, 60);
        assertEq(h.usedRolling(), CAP); // still counted: nothing more until it ages out
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.BudgetExceeded.selector, CAP, 1, CAP / 2));
        h.spendRolling(1, CAP / 2, 60);
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.NotDrained.selector, 170));
        h.reconfigure(CAP, 60); // raising back waits
    }

    /// Spends mixed with reconfigure calls (caps CAP or CAP/2, windows 60 or 120 s):
    /// no 60 s stretch ever settles more than CAP, the largest cap used.
    function testFuzz_rollingWithReconfigure(uint32[24] memory gaps, uint64[24] memory amounts, uint8[24] memory ops)
        public
    {
        uint256[24] memory ts;
        uint256[24] memory ok;
        uint256 t = 1_000;
        uint256 cap = CAP;
        uint64 w = 60;
        for (uint256 i; i < 24; ++i) {
            t += gaps[i] % 40;
            vm.warp(t);
            ts[i] = t;
            if (ops[i] % 4 == 0) {
                uint256 nc = ops[i] & 16 == 0 ? CAP : CAP / 2;
                uint64 nw = ops[i] & 32 == 0 ? 60 : 120;
                try h.reconfigure(nc, nw) { (cap, w) = (nc, nw); } catch {}
                continue;
            }
            uint256 a = amounts[i] % (CAP / 1e12) * 1e12;
            try h.spendRolling(a, cap, w) { ok[i] = a; } catch {}
        }
        for (uint256 i; i < 24; ++i) {
            uint256 sum;
            for (uint256 j = i; j < 24 && ts[j] <= ts[i] + 60; ++j) sum += ok[j];
            assertLe(sum, CAP);
        }
    }
}
