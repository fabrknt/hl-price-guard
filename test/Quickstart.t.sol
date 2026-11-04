// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";
import {HLTest} from "../src/test/HLTest.sol";
import {HLPriceGuard} from "../src/HLPriceGuard.sol";
import {GuardedMarket} from "../examples/GuardedMarket.sol";

/// Quickstart: `forge test --match-contract Quickstart -vv`. Plays a normal ETH book, then the
/// book pushed 20 bp before the oracle has moved, which the mid check rejects. (In Papertrade,
/// cases/papertrade-20261010, the oracle followed each push within seconds; that needs the cap.)
contract QuickstartTest is HLTest {
    GuardedMarket market;

    function setUp() public {
        installHL();
        market = new GuardedMarket();
    }

    function test_normalBookIsAccepted() public {
        // Mainnet ETH, 2026-10-17.
        setBook(ETH, 2427.23e18, 2426.12e18, 2426.30e18, 2426.40e18);
        uint256 px = market.price();
        console.log(string.concat("normal book:   accepted at $", vm.toString(px / 1e18), px / 1e16 % 100 < 10 ? ".0" : ".", vm.toString(px / 1e16 % 100)));
        assertEq(px, 2427.23e18);
    }

    function test_pushedBookIsRejected() public {
        setBook(ETH, 2427.23e18, 2428.00e18, 2432.00e18, 2432.10e18);
        try market.price() returns (uint256) {
            fail("a pushed book should be rejected");
        } catch (bytes memory err) {
            (HLPriceGuard.Breach why, uint256 seen, uint256 limit) = _decode(err);
            console.log("pushed book:   rejected, mid vs oracle", seen, "bp, limit", limit);
            assertEq(uint8(why), uint8(HLPriceGuard.Breach.MidOracle));
        }
    }

    /// setBookRaw takes the precompiles' units (ETH: 2 decimals) and gives the same book as setBook.
    function test_setBookRawMatchesSetBook() public {
        setBookRaw(ETH, 242723, 242612, 242630, 242640);
        assertEq(market.price(), 2427.23e18);
        setBookRaw(ETH, 242723, 242800, 243200, 243210);
        vm.expectRevert(abi.encodeWithSelector(HLPriceGuard.PriceRejected.selector, HLPriceGuard.Breach.MidOracle, 20, 15));
        market.price();
    }

    /// A HIP-3 asset: oracle and mark at dex * 10000 + index, the book at the API id
    /// 100000 + dex * 10000 + index (xyz:TSLA, dex 1 index 1; szDecimals 3, so 3 price decimals).
    function test_setBookRawHip3UsesBothIndexEncodings() public {
        HLPriceGuard.Asset memory tsla = HLPriceGuard.Asset({dex: 1, index: 1, szDecimals: 3});
        setBookRaw(tsla, 433_120, 433_050, 433_000, 433_200);
        HLPriceGuard.Quote memory q = HLPriceGuard.quote(tsla);
        assertEq(q.oracle, 433.12e18);
        assertEq(q.mark, 433.05e18);
        assertEq(q.bid, 433.0e18);
        assertEq(q.ask, 433.2e18);
    }

    function _decode(bytes memory err) internal pure returns (HLPriceGuard.Breach, uint256, uint256) {
        require(bytes4(err) == HLPriceGuard.PriceRejected.selector, "not a guard rejection");
        bytes memory args = new bytes(err.length - 4);
        for (uint256 i; i < args.length; i++) {
            args[i] = err[i + 4];
        }
        return abi.decode(args, (HLPriceGuard.Breach, uint256, uint256));
    }
}
