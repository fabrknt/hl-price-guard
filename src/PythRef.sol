// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HLPriceGuard} from "./HLPriceGuard.sol";

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

/// @notice Pyth as the independent reference for HLPriceGuard.
///
/// Pyth on HyperEVM (0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc) is pull-based. On
/// 2026-10-17 the stored ETH/USD was 7.5 hours old and TSLA/USD 3.5 months old, so the
/// caller must push a fresh update in the same transaction; `maxAge` enforces it.
library PythRef {
    address internal constant HYPEREVM_PYTH = 0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc;

    error BadPythPrice(bytes32 id);
    error PythConfTooWide(bytes32 id, uint256 confBps, uint256 maxConfBps);
    error PythStale(bytes32 id, uint256 ageSecs, uint256 maxAge);

    /// Push `updateData` (pays the fee from this contract's balance), then read.
    function updateAndRead(IPyth pyth, bytes[] calldata updateData, bytes32 id, uint256 maxAge, uint16 maxConfBps)
        internal
        returns (HLPriceGuard.Ref memory)
    {
        if (updateData.length != 0) {
            pyth.updatePriceFeeds{value: pyth.getUpdateFee(updateData)}(updateData);
        }
        return read(pyth, id, maxAge, maxConfBps);
    }

    /// For callers that use Pyth alone, without an HL quote for HLPriceGuard.check: `read`, then
    /// revert unless `publishTime` is within `maxAge` of the block time. Like Pyth's own
    /// getPriceNoOlderThan, the distance is absolute, so a publishTime ahead of the block counts too.
    function readFresh(IPyth pyth, bytes32 id, uint256 maxAge, uint16 maxConfBps)
        internal
        view
        returns (HLPriceGuard.Ref memory r)
    {
        r = read(pyth, id, maxAge, maxConfBps);
        uint256 age = block.timestamp > r.updatedAt ? block.timestamp - r.updatedAt : r.updatedAt - block.timestamp;
        if (age > maxAge) revert PythStale(id, age, maxAge);
    }

    /// `updateAndRead` with the staleness check of `readFresh`.
    function updateAndReadFresh(IPyth pyth, bytes[] calldata updateData, bytes32 id, uint256 maxAge, uint16 maxConfBps)
        internal
        returns (HLPriceGuard.Ref memory)
    {
        if (updateData.length != 0) {
            pyth.updatePriceFeeds{value: pyth.getUpdateFee(updateData)}(updateData);
        }
        return readFresh(pyth, id, maxAge, maxConfBps);
    }

    /// Staleness is checked later by HLPriceGuard.check against `maxAge`; use `readFresh` when
    /// there is no HLPriceGuard.check.
    function read(IPyth pyth, bytes32 id, uint256 maxAge, uint16 maxConfBps)
        internal
        view
        returns (HLPriceGuard.Ref memory r)
    {
        IPyth.Price memory p = pyth.getPriceUnsafe(id);
        if (p.price <= 0 || p.expo > 0 || p.expo < -18) revert BadPythPrice(id);
        uint256 scale = 10 ** uint256(int256(18 + p.expo));
        r.price = uint256(int256(p.price)) * scale;
        if (maxConfBps != 0) {
            uint256 px = uint256(int256(p.price));
            uint256 confBps = (uint256(p.conf) * 10_000 + px - 1) / px; // rounded up, as in diffBps
            if (confBps > maxConfBps) revert PythConfTooWide(id, confBps, maxConfBps);
        }
        r.updatedAt = p.publishTime;
        r.maxAge = maxAge;
    }
}
