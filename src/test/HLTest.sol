// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPrecompiles} from "../HLPrecompiles.sol";
import {HLPriceGuard} from "../HLPriceGuard.sol";

/// Stands in for one HyperCore price precompile: returns whatever was set for an index, and fails
/// like the real one for an index that was never set.
contract HLMockPrecompile {
    mapping(bytes32 => bytes) internal ret;

    function set(uint32 index, bytes calldata out) external {
        ret[keccak256(abi.encode(index))] = out;
    }

    fallback(bytes calldata input) external returns (bytes memory out) {
        out = ret[keccak256(input)];
        require(out.length != 0, "PrecompileError");
    }
}

/// Base for testing your own contract locally. forge's fork mode cannot run HyperEVM's custom
/// precompiles, so this puts mocks at their real addresses; you set prices in 1e18, the way
/// HLPriceGuard returns them, and your contract reads them through the real library code.
///
///     contract MyTest is HLTest {
///         function setUp() public { installHL(); }
///         function test_x() public { setBook(ETH, 2427.23e18, 2426.12e18, 2426.30e18, 2426.40e18); ... }
///     }
abstract contract HLTest is Test {
    /// Core ETH perp (dex 0, index 1, szDecimals 4), as on mainnet.
    HLPriceGuard.Asset internal ETH = HLPriceGuard.Asset({dex: 0, index: 1, szDecimals: 4});

    function installHL() internal {
        address mock = address(new HLMockPrecompile());
        vm.etch(HLPrecompiles.ORACLE_PX, mock.code);
        vm.etch(HLPrecompiles.MARK_PX, mock.code);
        vm.etch(HLPrecompiles.BBO, mock.code);
    }

    /// With hyper-evm-lib's simulator (CoreSimulatorLib.init), which serves the oracle and mark
    /// itself but sends BBO reads to mainnet: replaces only 0x80e, so `setBbo` controls the book
    /// while the simulator keeps the oracle and mark (move the mark with CoreSimulatorLib.setMarkPx).
    function installBboOnly() internal {
        vm.etch(HLPrecompiles.BBO, address(new HLMockPrecompile()).code);
    }

    /// Prices in 1e18. Digits finer than the asset's tick (6 - szDecimals decimals) are dropped,
    /// as HyperCore would never report them.
    function setBook(HLPriceGuard.Asset memory a, uint256 oracle, uint256 mark, uint256 bid, uint256 ask)
        internal
    {
        uint32 perp = HLPrecompiles.perpIndex(a.dex, a.index);
        HLMockPrecompile(HLPrecompiles.ORACLE_PX).set(perp, abi.encode(_raw(oracle, a)));
        HLMockPrecompile(HLPrecompiles.MARK_PX).set(perp, abi.encode(_raw(mark, a)));
        setBbo(a, bid, ask);
    }

    function setBbo(HLPriceGuard.Asset memory a, uint256 bid, uint256 ask) internal {
        HLMockPrecompile(HLPrecompiles.BBO).set(
            HLPrecompiles.bboIndex(a.dex, a.index), abi.encode(_raw(bid, a), _raw(ask, a))
        );
    }

    function _raw(uint256 px, HLPriceGuard.Asset memory a) private pure returns (uint64) {
        uint256 raw = px / 10 ** (12 + uint256(a.szDecimals));
        require(raw <= type(uint64).max, "HLTest: price does not fit the precompile's uint64");
        return uint64(raw);
    }
}
