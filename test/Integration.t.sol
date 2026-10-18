// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPrecompiles} from "../src/HLPrecompiles.sol";
import {HLPriceGuard} from "../src/HLPriceGuard.sol";
import {ExposureBudget} from "../src/ExposureBudget.sol";
import {PythRef, IPyth} from "../src/PythRef.sol";
import {MockPrecompile} from "./HLPriceGuard.t.sol";
import {FeePyth} from "./Properties.t.sol";

/// How an app is meant to put the pieces together (docs/safe-limits.md, checklist): push a fresh
/// independent reference, read the oracle through the tripwires, run it past the jump latch, then
/// count the notional against a rolling cap. Any failure reverts the whole settlement.
contract ExampleSettlement {
    using ExposureBudget for ExposureBudget.Rolling;

    HLPriceGuard.Asset public asset;
    HLPriceGuard.Bounds public bounds;
    IPyth public pyth;
    bytes32 public feed;
    uint16 public maxJumpBps;
    uint256 public cap;
    uint64 public windowSecs;

    HLPriceGuard.JumpLatch public latch;
    ExposureBudget.Rolling internal budget;

    constructor(
        HLPriceGuard.Asset memory a,
        HLPriceGuard.Bounds memory b,
        IPyth p,
        bytes32 f,
        uint16 jump,
        uint256 c,
        uint64 w
    ) {
        (asset, bounds, pyth, feed, maxJumpBps, cap, windowSecs) = (a, b, p, f, jump, c, w);
    }

    function settle(uint256 notional, bytes[] calldata pythUpdate) external payable returns (uint256 px) {
        HLPriceGuard.Ref memory ref = PythRef.updateAndRead(pyth, pythUpdate, feed, 60, 50);
        px = HLPriceGuard.read(asset, bounds, ref);
        (HLPriceGuard.Breach jump, uint256 seen, uint256 limit) = HLPriceGuard.observe(latch, px, maxJumpBps);
        if (jump != HLPriceGuard.Breach.None) revert HLPriceGuard.PriceRejected(jump, seen, limit);
        budget.spend(notional, cap, windowSecs);
    }

    function used() external view returns (uint256) {
        return budget.used();
    }
}

contract IntegrationTest is Test {
    ExampleSettlement app;
    FeePyth pyth;
    uint256 constant CAP = 3_300_000e18; // Papertrade's ETH cap, $3.3M per minute (docs/safe-limits.md)

    function setUp() public {
        address mock = address(new MockPrecompile());
        vm.etch(HLPrecompiles.ORACLE_PX, mock.code);
        vm.etch(HLPrecompiles.MARK_PX, mock.code);
        vm.etch(HLPrecompiles.BBO, mock.code);
        vm.warp(1792190822);
        pyth = new FeePyth(1 wei);
        pyth.setPrice(2427e8, 0.5e8, -8, block.timestamp - 3600); // stale until pushed
        app = new ExampleSettlement(
            HLPriceGuard.Asset(0, 1, 4),
            HLPriceGuard.Bounds({maxMarkOracleBps: 15, maxMidOracleBps: 15, maxSpreadBps: 10, maxRefOracleBps: 50}),
            IPyth(address(pyth)),
            bytes32(0),
            200,
            CAP,
            60
        );
        vm.deal(address(app), 1 ether);
        // Mainnet ETH, 2026-10-17: oracle 2427.23, mark 2426.12, bbo 2426.30 / 2426.40.
        book(242723, 242612, 242630, 242640);
    }

    function book(uint64 oracle, uint64 mark, uint64 bid, uint64 ask) internal {
        MockPrecompile(HLPrecompiles.ORACLE_PX).set(1, abi.encode(oracle));
        MockPrecompile(HLPrecompiles.MARK_PX).set(1, abi.encode(mark));
        MockPrecompile(HLPrecompiles.BBO).set(1, abi.encode(bid, ask));
    }

    function pythAt(int64 price) internal view returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = abi.encode(price, block.timestamp);
    }

    function _settleReason(uint256 notional, bytes[] memory u) internal returns (bool ok, HLPriceGuard.Breach why) {
        try app.settle(notional, u) {
            return (true, HLPriceGuard.Breach.None);
        } catch (bytes memory err) {
            assertEq(bytes4(err), HLPriceGuard.PriceRejected.selector, "rejected by the guard");
            bytes memory args = new bytes(err.length - 4);
            for (uint256 i; i < args.length; i++) {
                args[i] = err[i + 4];
            }
            (why,,) = abi.decode(args, (HLPriceGuard.Breach, uint256, uint256));
        }
    }

    function test_normalSettlement() public {
        assertEq(app.settle(1_000_000e18, pythAt(2427e8)), 2427.23e18);
        assertEq(app.used(), 1_000_000e18);
        assertEq(pyth.received(), 1 wei, "the update fee came from the app's balance");
    }

    function test_referenceMustBePushed() public {
        (bool ok, HLPriceGuard.Breach why) = _settleReason(1e18, new bytes[](0));
        assertFalse(ok);
        assertEq(uint8(why), uint8(HLPriceGuard.Breach.RefStale));
    }

    /// Papertrade's first rounds: the book is pushed ~20 bp while the oracle stays. The mid tripwire
    /// rejects; nothing is counted against the cap.
    function test_pushedBookIsRejected() public {
        book(242723, 242800, 243200, 243210);
        (bool ok, HLPriceGuard.Breach why) = _settleReason(1_000_000e18, pythAt(2427e8));
        assertFalse(ok);
        assertEq(uint8(why), uint8(HLPriceGuard.Breach.MidOracle));
        assertEq(app.used(), 0);
    }

    /// Papertrade's later rounds: the oracle moves with the book (10 bp, inside every bound and
    /// with Pyth agreeing), so every price check passes. Only the cap stops more settling.
    function test_oracleMovedWithThePushOnlyTheCapLimits() public {
        book(242966, 242960, 242960, 242970);
        assertEq(app.settle(3_000_000e18, pythAt(2429e8)), 2429.66e18);
        vm.expectRevert(abi.encodeWithSelector(ExposureBudget.BudgetExceeded.selector, 3_000_000e18, 1_000_000e18, CAP));
        app.settle(1_000_000e18, pythAt(2429e8));
        vm.warp(block.timestamp + 71); // the rolling window (plus under one slice) has passed
        app.settle(1_000_000e18, pythAt(2429e8));
    }

    /// xyz:SKHX-style: the oracle falls 15.6% in one update and the book follows. With Pyth still at
    /// the old price the reference check rejects; even with the reference agreeing (or unavailable),
    /// the latch rejects the jump and every small step after it.
    function test_oracleJumpIsRejectedAndStaysRejected() public {
        app.settle(1e18, pythAt(2427e8)); // sets the latch anchor at 2427.23
        book(204894, 204894, 204890, 204900); // -15.6%
        (bool ok, HLPriceGuard.Breach why) = _settleReason(1e18, pythAt(2427e8));
        assertFalse(ok);
        assertEq(uint8(why), uint8(HLPriceGuard.Breach.RefOracle));

        for (uint64 p = 204894; p > 196000; p -= 2000) {
            book(p, p, p - 5, p + 5);
            (ok, why) = _settleReason(1e18, pythAt(int64(uint64(p)) * 1e6));
            assertFalse(ok);
            assertEq(uint8(why), uint8(HLPriceGuard.Breach.Jump));
        }
        book(242723, 242612, 242630, 242640); // back near the anchor: accepted again
        assertEq(app.settle(1e18, pythAt(2427e8)), 2427.23e18);
    }
}
