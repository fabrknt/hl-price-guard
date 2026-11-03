// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// For a project that already tests with hyper-evm-lib's simulator. Not compiled in this repo
// (it needs hyper-evm-lib); copy it into your test/ folder. Needs network access: the simulator
// forks mainnet, and reads the oracle live from mainnet on every call, so the tests leave room for
// it to move between reads.
//
// Remappings: hl-price-guard/=lib/hl-price-guard/src/  @hyper-evm-lib/=lib/hyper-evm-lib/

import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {HLTest} from "hl-price-guard/test/HLTest.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";
import {GuardedMarket} from "./GuardedMarket.sol"; // examples/GuardedMarket.sol, with its import pointed at hl-price-guard/

contract GuardedMarketSimTest is HLTest {
    GuardedMarket market;
    uint32 constant ETH_PERP = 1;

    function setUp() public {
        vm.createSelectFork("https://rpc.hyperliquid.xyz/evm");
        CoreSimulatorLib.init();
        installBboOnly(); // the simulator does not model the book; this does
        market = new GuardedMarket();
    }

    /// A tight book around the live oracle, with the mark on it.
    function _calmBook() internal returns (uint256 oracle) {
        oracle = HLPriceGuard.oracleOnly(ETH); // the book is not set yet, so read the oracle alone
        CoreSimulatorLib.setMarkPx(ETH_PERP, uint64(oracle / 1e16)); // raw: 2 decimals for ETH
        setBbo(ETH, oracle - oracle / 20_000, oracle + oracle / 20_000); // ±0.5 bp
    }

    function test_calmBookIsAccepted() public {
        uint256 oracle = _calmBook();
        assertApproxEqRel(market.price(), oracle, 0.001e18); // within 10 bp: the live oracle may have ticked
    }

    /// The simulator's own way to move a price (as in its PerpTradingTest): the mark up 20%.
    function test_markMovedAwayIsRejected() public {
        _calmBook();
        CoreSimulatorLib.setMarkPx(ETH_PERP, 2000, true);
        vm.expectPartialRevert(HLPriceGuard.PriceRejected.selector);
        market.price();
    }

    /// The book pushed ~20 bp while the oracle stays, as in Papertrade's first rounds. The exact bp
    /// depends on tick rounding and the live oracle, so the test checks the reason.
    function test_pushedBookIsRejected() public {
        uint256 oracle = _calmBook();
        setBbo(ETH, oracle + oracle / 500, oracle + oracle / 500 + oracle / 100_000);
        try market.price() returns (uint256) {
            fail("a pushed book should be rejected");
        } catch (bytes memory err) {
            assertEq(bytes4(err), HLPriceGuard.PriceRejected.selector);
            bytes memory args = new bytes(err.length - 4);
            for (uint256 i; i < args.length; i++) {
                args[i] = err[i + 4];
            }
            (HLPriceGuard.Breach why,,) = abi.decode(args, (HLPriceGuard.Breach, uint256, uint256));
            assertEq(uint8(why), uint8(HLPriceGuard.Breach.MidOracle));
        }
    }
}
