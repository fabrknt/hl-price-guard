// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPrecompiles} from "../src/HLPrecompiles.sol";

/// Answers each input with the bytes recorded for it, so the library decodes real mainnet output.
contract ReplayPrecompile {
    mapping(bytes32 => bytes) internal out;

    function set(bytes calldata input, bytes calldata output) external {
        out[keccak256(input)] = output;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        bytes memory o = out[keccak256(input)];
        require(o.length != 0, "not recorded");
        return o;
    }
}

contract Reader {
    function szDecimals(uint32 perp) external view returns (uint8) {
        return HLPrecompiles.szDecimals(perp);
    }

    function oracle(uint32 perp, uint8 szDec) external view returns (uint256) {
        return HLPrecompiles.oracle(perp, szDec);
    }

    function mark(uint32 perp, uint8 szDec) external view returns (uint256) {
        return HLPrecompiles.mark(perp, szDec);
    }

    function bbo(uint32 idx, uint8 szDec) external view returns (uint256, uint256) {
        return HLPrecompiles.bbo(idx, szDec);
    }

    function l1BlockNumber() external view returns (uint64) {
        return HLPrecompiles.l1BlockNumber();
    }
}

/// Mocks in HLPriceGuard.t.sol return what we believe the precompiles return. This checks that belief
/// against mainnet: it fetches the precompiles' raw output over HyperEVM's public RPC (forge's fork mode
/// cannot run them) and runs it through HLPrecompiles. Needs the network, so it runs only with
/// HL_LIVE=true:  HL_LIVE=true forge test --match-contract Live
contract LiveTest is Test {
    Reader reader;

    function setUp() public {
        vm.skip(!vm.envOr("HL_LIVE", false));
        ReplayPrecompile code = new ReplayPrecompile();
        vm.etch(HLPrecompiles.PERP_ASSET_INFO, address(code).code);
        vm.etch(HLPrecompiles.ORACLE_PX, address(code).code);
        vm.etch(HLPrecompiles.MARK_PX, address(code).code);
        vm.etch(HLPrecompiles.BBO, address(code).code);
        vm.etch(HLPrecompiles.L1_BLOCK_NUMBER, address(code).code);
        reader = new Reader();
    }

    function _record(address precompile, uint32 index) internal {
        _record(precompile, abi.encode(index));
    }

    function _record(address precompile, bytes memory input) internal {
        string memory params = string.concat(
            '[{"to":"', vm.toString(precompile), '","data":"', vm.toString(input), '"},"latest"]'
        );
        ReplayPrecompile(precompile).set(input, vm.rpc("hyperevm", "eth_call", params));
    }

    /// Reads one perp through every precompile and checks the values hang together. The bounds are
    /// loose on purpose (`tol`, 1e18 = 100%): this is a daily check for a wrong encoding or scale, which
    /// is off by orders of magnitude (a wrong BBO index put xyz:TSLA's mid 31x off), not a market monitor.
    /// The four reads are separate calls at "latest", so prices may move a little between them.
    function _check(string memory name, uint32 dex, uint32 i, uint8 wantSzDec, uint256 tol) internal {
        uint32 perp = HLPrecompiles.perpIndex(dex, i);
        uint32 bboIdx = HLPrecompiles.bboIndex(dex, i);
        _record(HLPrecompiles.PERP_ASSET_INFO, perp);
        _record(HLPrecompiles.ORACLE_PX, perp);
        _record(HLPrecompiles.MARK_PX, perp);
        _record(HLPrecompiles.BBO, bboIdx);

        uint8 szDec = reader.szDecimals(perp);
        assertEq(szDec, wantSzDec, string.concat(name, ": szDecimals"));
        uint256 o = reader.oracle(perp, szDec);
        uint256 m = reader.mark(perp, szDec);
        (uint256 b, uint256 a) = reader.bbo(bboIdx, szDec);
        emit log_named_decimal_uint(string.concat(name, " oracle"), o, 18);
        assertGt(o, 0, string.concat(name, ": oracle"));
        assertApproxEqRel(m, o, tol, string.concat(name, ": mark vs oracle"));
        // A thin book (HIP-3 out of hours) may have a side missing; check the mid only when both exist.
        if (b != 0 && a != 0) {
            assertLe(b, a, string.concat(name, ": bid <= ask"));
            assertApproxEqRel((a + b) / 2, o, tol, string.concat(name, ": mid vs oracle"));
        }
    }

    function test_live_BTC() public {
        _check("BTC", 0, 0, 5, 0.05e18);
    }

    function test_live_ETH() public {
        _check("ETH", 0, 1, 4, 0.05e18);
    }

    /// HIP-3: 0x807/0x806/0x80a take dex * 10000 + i, 0x80e takes 100000 + dex * 10000 + i. Pinned to
    /// xyz:TSLA as dex 1, index 1 with 3 size decimals; if trade.xyz relists it, update this test.
    function test_live_xyzTSLA() public {
        _check("xyz:TSLA", 1, 1, 3, 0.2e18);
    }

    function test_live_l1BlockNumber() public {
        _record(HLPrecompiles.L1_BLOCK_NUMBER, "");
        assertGt(reader.l1BlockNumber(), 1_000_000_000);
    }
}
