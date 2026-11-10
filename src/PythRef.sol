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

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory priceFeeds);
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

    /// The price at a set time: the first Pyth update published at or after `at`, and no later than
    /// `at + window`. Pyth's parsePriceFeedUpdatesUnique accepts an update only if the one before it
    /// was published before `at`, so the caller cannot pick a favourable print from several; anyone
    /// can submit it later. Use it when a price at a set time decides who gets paid. Pays the fee
    /// from this contract's balance; `updatedAt` is the update's publishTime and `maxAge` is `window`.
    function readFirstAfter(
        IPyth pyth,
        bytes[] calldata updateData,
        bytes32 id,
        uint64 at,
        uint64 window,
        uint16 maxConfBps
    ) internal returns (HLPriceGuard.Ref memory) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        IPyth.PriceFeed[] memory f =
            pyth.parsePriceFeedUpdatesUnique{value: pyth.getUpdateFee(updateData)}(updateData, ids, at, at + window);
        if (f.length != 1 || f[0].id != id) revert BadPythPrice(id);
        return toRef(f[0].price, id, window, maxConfBps);
    }

    /// Staleness is checked later by HLPriceGuard.check against `maxAge`; use `readFresh` when
    /// there is no HLPriceGuard.check.
    function read(IPyth pyth, bytes32 id, uint256 maxAge, uint16 maxConfBps)
        internal
        view
        returns (HLPriceGuard.Ref memory r)
    {
        return toRef(pyth.getPriceUnsafe(id), id, maxAge, maxConfBps);
    }

    /// A Pyth price as a Ref in 18 decimals, reverting on a bad price or a confidence wider than
    /// `maxConfBps` (0 skips that check).
    function toRef(IPyth.Price memory p, bytes32 id, uint256 maxAge, uint16 maxConfBps)
        internal
        pure
        returns (HLPriceGuard.Ref memory r)
    {
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
