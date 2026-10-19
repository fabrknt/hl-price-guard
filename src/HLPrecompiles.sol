// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @notice Raw reads of HyperCore prices from HyperEVM, normalized to 1e18.
/// Behaviour below was checked against mainnet on 2026-10-17.
library HLPrecompiles {
    address internal constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000809;
    address internal constant PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    // Not in the official docs. Returns (uint64 bid, uint64 ask).
    address internal constant BBO = 0x000000000000000000000000000000000000080e;

    error PrecompileFailed(address precompile, uint32 index);
    error BadSzDecimals(uint8 szDecimals);

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    /// Index taken by 0x806, 0x807 and 0x80a: `dex * 10000 + i`. Core perps are dex 0.
    function perpIndex(uint32 dex, uint32 i) internal pure returns (uint32) {
        return dex * 10000 + i;
    }

    /// Index taken by 0x80e: the API asset ID. Core perps are `i`; HIP-3 perps are
    /// `100000 + dex * 10000 + i`.
    function bboIndex(uint32 dex, uint32 i) internal pure returns (uint32) {
        return dex == 0 ? i : 100000 + dex * 10000 + i;
    }

    function _call(address precompile, uint32 index) private view returns (bytes memory out) {
        bool ok;
        (ok, out) = precompile.staticcall(abi.encode(index));
        if (!ok || out.length == 0) revert PrecompileFailed(precompile, index);
    }

    function szDecimals(uint32 perp) internal view returns (uint8) {
        return abi.decode(_call(PERP_ASSET_INFO, perp), (PerpAssetInfo)).szDecimals;
    }

    /// Perp prices come back with `6 - szDecimals` decimals, so szDecimals is at most 6. A larger value
    /// is a caller's mistake and would scale prices up by orders of magnitude (from 46, overflow).
    function _scale(uint8 szDec) private pure returns (uint256) {
        if (szDec > 6) revert BadSzDecimals(szDec);
        return 10 ** (12 + uint256(szDec));
    }

    function oracle(uint32 perp, uint8 szDec) internal view returns (uint256) {
        return uint256(abi.decode(_call(ORACLE_PX, perp), (uint64))) * _scale(szDec);
    }

    function mark(uint32 perp, uint8 szDec) internal view returns (uint256) {
        return uint256(abi.decode(_call(MARK_PX, perp), (uint64))) * _scale(szDec);
    }

    function bbo(uint32 bboIdx, uint8 szDec) internal view returns (uint256 bid, uint256 ask) {
        (uint64 b, uint64 a) = abi.decode(_call(BBO, bboIdx), (uint64, uint64));
        uint256 s = _scale(szDec);
        return (uint256(b) * s, uint256(a) * s);
    }

    function l1BlockNumber() internal view returns (uint64) {
        (bool ok, bytes memory out) = L1_BLOCK_NUMBER.staticcall("");
        if (!ok || out.length == 0) revert PrecompileFailed(L1_BLOCK_NUMBER, 0);
        return abi.decode(out, (uint64));
    }
}
