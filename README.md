# HL Price Guard (hl-price-guard)

**If your HyperEVM contract settles, lends, liquidates or mints against Hyperliquid's prices, one
wallet can move those prices and take the difference.** On 2026-10-10 a wallet spent $130,873 on
Hyperliquid pushing ETH's book and was paid $1.41M by Papertrade, an exchange that settled at
HL's mid: $1.28M net ([`cases/papertrade-20261010`](cases/papertrade-20261010/README.md), rebuilt from public data).

The obvious fixes did not hold up when we replayed it on the same 228 positions:

| what the exchange could have done | what the positions take in the replay |
|---|---|
| nothing: settle at HL's best bid/ask mid | $2,052,046 |
| settle at HL's oracle instead (it moved with the push) | $1,738,919, only 15% less |
| refuse closes when the mid is over 15 bp from the oracle | refuses 0 of 228 |
| cap notional settled per minute at $3.3M (`ExposureBudget.Rolling`) | about $55,101 (estimate, below), under the $130,873 the push cost |

Take is notional times the price move each rule settles at. The cap row is not a replay of
`ExposureBudget.Rolling`: it is the incident's average edge times $3.3M times the 18 minutes with
closes, an estimate from this one incident and not a bound (`replay_c.py`, `docs/safe-limits.md`). The other
failure is the oracle itself: on 2026-07-27 a HIP-3 deployer's oracle for xyz:SKHX fell 15.6% in one
update, then stepped down 1% at a time. Comparing each read with the previous one let 39 prices
under $1,000 through; the jump latch let none ([`cases/skhx-20260727`](cases/skhx-20260727/README.md)).

This library is those defenses as Solidity you call: read the oracle and refuse it when the book or
mark disagrees, check it against an independent price, latch on jumps, and cap what one price can
settle. Unaudited, and not for production funds yet (Status).
Part of **[Fabrknt for HIP-3](https://fabrknt.com/hip3/index.html)** ([product page](https://fabrknt.com/hip3/price-guard/index.html)); built for Hyperliquid, not affiliated with it.

## Quickstart
Try it in a minute, with no key and no funds:

```bash
git clone --recurse-submodules https://github.com/fabrknt/hl-price-guard && cd hl-price-guard
forge test --match-contract Quickstart -vv
```
```
normal book:   accepted at $2427.23
pushed book:   rejected, mid vs oracle 20 bp, limit 15
```
The second book is pushed 20 bp before the oracle has moved: the case the mid check catches. In
Papertrade itself the mid moved the attacker's way in 16 of 18 rounds (up to about 18 bp), and in
each of those 16 the oracle moved the same way too (mid–oracle gap at close at most 10.2 bp), which
is why that incident needs the cap in the table above as well.

Use it in your own Foundry project:

```bash
forge install fabrknt/hl-price-guard@v0.3.1
echo 'hl-price-guard/=lib/hl-price-guard/src/' >> remappings.txt
```
The second line pins where `hl-price-guard/` imports resolve. Without it, Foundry guesses from the
repo's layout and can pick the repo root (it did with v0.3.0 and forge 1.7.1), and the imports
below are not found.
```solidity
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";

contract MyMarket {
    HLPriceGuard.Asset ETH = HLPriceGuard.Asset({dex: 0, index: 1, szDecimals: 4});
    HLPriceGuard.Bounds BOUNDS =
        HLPriceGuard.Bounds({maxMarkOracleBps: 15, maxMidOracleBps: 15, maxSpreadBps: 10, maxRefOracleBps: 0});

    function price() public view returns (uint256) {
        // The oracle (1e18), or a revert PriceRejected(reason, observedBps, limitBps).
        return HLPriceGuard.read(ETH, BOUNDS, HLPriceGuard.Ref(0, 0, 0));
    }
}
```
Test it locally with `HLTest`, which puts mock precompiles at their real addresses (forge's fork
mode cannot run them) and lets you set prices in 1e18:

```solidity
import {HLTest} from "hl-price-guard/test/HLTest.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";

contract MyMarketTest is HLTest {
    function setUp() public { installHL(); }

    function test_pushedBook() public {
        MyMarket m = new MyMarket();
        setBook(ETH, 2427.23e18, 2428.00e18, 2432.00e18, 2432.10e18); // oracle, mark, bid, ask
        vm.expectRevert(
            abi.encodeWithSelector(HLPriceGuard.PriceRejected.selector, HLPriceGuard.Breach.MidOracle, 20, 15)
        );
        m.price();
    }
}
```
The same contract and test are `examples/GuardedMarket.sol` and `test/Quickstart.t.sol`.

Already testing with [hyper-evm-lib](https://github.com/hyperliquid-dev/hyper-evm-lib)'s
simulator? Its simulator forks mainnet and lets you move the mark (`CoreSimulatorLib.setMarkPx`),
but it cannot set the oracle (we proposed `setOraclePx`:
[hyper-evm-lib#38](https://github.com/hyperliquid-dev/hyper-evm-lib/pull/38)) and does not model the book: BBO reads go to mainnet. Call
`installBboOnly()` after `CoreSimulatorLib.init()` and set the book with `setBbo`; the simulator
keeps the oracle and mark. `examples/with-hyper-evm-lib/GuardedMarketSim.t.sol` plays a calm book,
the simulator's own +20% mark move, and a book pushed 60 bp against ETH's live oracle. It is
not compiled here; copy it into a project with both libraries (checked with hyper-evm-lib
`4eb7ab0`). It needs network access. The simulator reads the oracle live on every call, so a test
can see it move between reads (the example leaves room for that), and the public RPC sometimes
answers "invalid block height": rerun. `installBboOnly` replaces the book for every asset: set each
one your contract reads with `setBbo`, or its BBO read reverts.

`read` is a deviation check: it rejects a book or mark that has moved away from the oracle. It does
not stop a push that moves the oracle too (Papertrade's later rounds), or a HIP-3 deployer moving
their own oracle. For that, add an independent reference, the jump latch and a cap, as
`test/Integration.t.sol` does; the table below says which piece covers what.

| I want to… | Use |
|---|---|
| read the oracle, reverting when the book or mark has moved away from it | `HLPriceGuard.read` |
| know why, without reverting (monitoring, pausing) | `HLPriceGuard.check` |
| check against an independent price | `PythRef` + `maxRefOracleBps` |
| use Pyth alone, reverting when its price is stale | `PythRef.readFresh` / `updateAndReadFresh` |
| take the price at a set time, from a print no caller can choose | `PythRef.readFirstAfter` |
| reject an oracle that jumps, and every small step after | `HLPriceGuard.observe` (`JumpLatch`) |
| cap how much settles against one price per minute | `ExposureBudget.Rolling` (cap sizes: `docs/safe-limits.md` §4, first estimates from one incident) |
| liquidate without a wide book holding it back | `HLPriceGuard.lenientPrice` |
| test my contract locally | `HLTest` |
| test inside hyper-evm-lib's simulator | `HLTest.installBboOnly` + `setBbo` |

Bounds and caps per asset: `docs/safe-limits.md`. Pin a tag, not `main` (see Versions).

## Scope
Scope: reading prices, detecting deviation (BBO, mark), an independent reference, a jump latch, and
exposure caps. Nothing else: pools, settlement queues, liquidation and UI belong to the apps that use
it (for example Day One, below), and nothing in this repo depends on any of them.

## How HL prices reach HyperEVM
HyperEVM contracts can read HyperCore prices through precompiles (how a node exposes its own state to contracts this way is built step by step in
[Build OpenHL Precompiles](https://fabrknt.com/dojo/courses/building-openhl-precompiles-en), on Reth):

| Precompile | Price | Set by | How hard to move |
|---|---|---|---|
| `0x…807` | oracle | validators, from external venues (HIP-3: the deployer) | harder, but a push on HL reached it for ETH (cases/papertrade-20261010) |
| `0x…806` | mark | oracle combined with the HL book | medium |
| `0x…80e` | best bid / ask (BBO) | the HL book itself | easy |

Index encodings differ between precompiles (checked on mainnet, 2026-10-17):
- `0x807` oracle takes `dex * 10000 + index` (xyz:TSLA = `10001`); the API's asset ID `110001` errors.
- `0x80e` BBO takes the API asset ID `100000 + dex * 10000 + index` (xyz:TSLA = `110001`).

## Contents
- `src/`: a Solidity library to read HL prices safely.
  - `HLPriceGuard`: returns the oracle and rejects it when the BBO, mark, an independent
    reference or the last stored price disagree beyond set bounds.
    `lenientPrice` gives liquidations the oracle or the mark, whichever favours the position, and
    `oracleOnly` the oracle with no tripwires; both revert on a 0 price (docs/safe-limits.md §5).
  - `PythRef`: Pyth on HyperEVM as the independent reference (it must be updated in the same tx,
    with update data from Pyth's Hermes, which needs an API key). Without an HL quote, use
    `readFresh` / `updateAndReadFresh`: they revert with `PythStale` when `publishTime` is more than
    `maxAge` from the block time, in either direction. When a price at a set time decides who gets
    paid, `readFirstAfter(at, window)` takes the first update published at or after `at` (Pyth's
    `parsePriceFeedUpdatesUnique`), so the caller cannot pick one print from several.
  - `ExposureBudget`: caps notional settled against one price per time window. `Rolling` (use this):
    no stretch of the window settles more than the cap; cap and window change only through
    `reconfigure`. `Window`: the older fixed window, which lets up to `2 * cap` through across a reset.
  - `HLPrecompiles`: raw reads and the two index encodings.
  - `test/HLTest`: a base for testing your own contract locally, with mock precompiles at their
    real addresses and prices set in 1e18 (`setBook`) or in the precompiles' own units (`setBookRaw`,
    on `main`, not yet tagged).
  - Apps built on it live in their own repos. One is Day One — Fabrknt Labs (`fabrknt/dayone`,
    private for now), a research launch pool. It uses this library as a git submodule (see Versions).
- `examples/GuardedMarket.sol`: the smallest contract using the library (tested in `test/Quickstart.t.sol`).
- `examples/with-hyper-evm-lib/`: the same contract tested inside hyper-evm-lib's simulator.
- `docs/safe-limits.md`: which price to use, how to set the bounds, how to size the cap, and what
  the cap does not cover (settlements at a single instant; a HIP-3 deployer's oracle key); then
  liquidations, prices at a set time (including time-averages of HIP-3 oracles that are built
  from their own book) and testnet, learned from apps built on the library.
- `docs/c-launch-pool-design.md`: points to Day One, where the launch-pool design now lives.
- `cases/`: incidents rebuilt from public data. Each is replayed under rules built from this library
  (oracle instead of BBO, deviation tripwire, exposure cap), plus the two-step settlement Day One adds.
  - Papertrade, 2026-10-10: one wallet moved HL's ETH mid and settled 500x positions against it.
    The Binance comparison fetches Binance's public klines; save them once to rerun offline.
  - xyz:SKHX, 2026-07-27: the deployer's oracle fell 15.6% in one update, then stepped down.
- `measure/`: `normal_gaps.py` samples the gaps the guard checks; `safe_caps.py` turns book
  depth into a per-minute exposure cap per asset (calibrated on Papertrade, one incident: a first
  estimate). Both save as they go; `safe_caps.py summary OUT.json` re-prints per UTC hour.
  `session.sh START END OUT` runs both over a UTC window; `.github/workflows/measure-us-session.yml`
  ran it on GitHub through the US session of 2026-10-19, started on time by `dispatch-at.yml`
  because this repository's scheduled runs start hours late. The data are
  `normal-gaps-20261019.json` and `safe-caps-20261019.json`; `session_tables.py` re-prints the
  tables in `docs/safe-limits.md` from them.
  `round_trips_collect.py` records trades (with wallets), best bid/offer and books;
  `round_trips.py` picks out single-wallet push-and-unwind round trips and compares their cost
  with the book-depth prediction, to test the Papertrade calibration on more than one incident.
  `round_trips_summary.py` combines many runs' results; the runs through 2026-11-03 are in
  `round-trips-20261017-20261103.jsonl` (with `round-trips-covered-20261017-20261103.json`, the
  stretches collected, and `round-trips-runs-20261017-20261103.txt`, the workflow run IDs).
  `.github/workflows/collect-round-trips.yml` runs both every 6 hours (it skips itself if the
  repository is private) and keeps the round trips found as artifacts for 30 days.
  `settle_window.py` records every oracle on the core, xyz and `io` dexes and a dozen books about
  every 10 s (backing off up to 2 minutes after a failed sweep; a request that fails leaves a gap
  in that row) around a fixed-time settlement (a TWAP ending 20:00 ET, say). `settle_session.sh
  START END OUT` runs it over a UTC window, `.github/workflows/settle-window.yml` on GitHub, which
  `dispatch-at.yml` starts at a set time with `target=settle-window`. A run that records nothing,
  or starts after `END`, fails; one that starts late but before `END` records what is left.
  Data files are named by the JST date they were taken; their timestamps are UTC.

## Used in
Projects of ours that depend on it through a pinned tag, the way an outside app would:
- [hyperevm-lend](https://github.com/psyto/hyperevm-lend): borrowing and collateral withdrawals go
  through `HLPriceGuard.read`; liquidation picks the higher of oracle and mark itself (the pattern
  `lenientPrice` was later added for). Its tests set prices with `HLTest`.
- [hyperevm-perp](https://github.com/psyto/hyperevm-perp): settles through `read`; liquidation picks
  oracle or mark itself, as in hyperevm-lend. Tests on `HLTest`.
- Day One (`fabrknt/dayone`, private): a launch pool on `quote` and `check`, the jump latch
  (`observe`, `rearm`) and `ExposureBudget.Rolling`. Tests on `HLTest`.
- Summon (`psyto/summon-stocks`, private for now): backer-funded rounds for tokenized stocks on Base
  Sepolia, priced from Pyth alone through `PythRef.readFresh`, which was added for it in `v0.3.2`
  (Summon needed a staleness check without an HL quote), and fills through `PythRef.readFirstAfter`,
  added for it in `v0.4.0` (a review found that a filler could choose among several fresh prints).

All three moved from `v0.2.1` to `v0.3.0` on 2026-11-04 with no change to their contracts and all
their tests passing. hyperevm-lend and hyperevm-perp hold their test prices in the precompiles' own
units and had to convert them for `setBook`, which is where `setBookRaw` came from; both moved to
`v0.3.1` the same day and now pass those units straight to `setBookRaw`. Day One kept its raw `.set`
calls on `HLMockPrecompile` and stays on `v0.3.0`.

## Status
**Not for production funds.** The library is unaudited and its caps are first estimates from
little data; use it for research, test deployments and review.
- Measured so far: normal gaps and book depth through one full US session (2026-10-19), plus a
  quiet Friday-evening sample of each (2026-10-16). The caps in `docs/safe-limits.md` still rest
  on the 0.27 calibration from one incident, so they remain first estimates.
- Running: round trips are collected every 6 hours to test that calibration. Through 2026-11-03
  (59 runs, 314 hours) 7 of 321 candidates passed the strict filters, all 5 to 14 bp pushes with a
  predicted cost of $10 to $87 and ratios from -11 to 15; the 14 pushes of $1M or more were all
  filtered out, mostly because they moved past the recorded book or unwound outside 20 to 120 s.
  0.27 is still one incident's number; how to change the measurement is in `docs/safe-limits.md`
  ("Measuring `C` per asset").
- Scheduled: oracles and books from 19:00 to 20:05 ET on Friday 2026-11-06 (xyz equities still
  priced from outside venues until 20:00), Saturday 11-07 and Sunday 11-08 (priced from their own
  book). The last 11 minutes of the window ending 20:00 ET on Wednesday 2026-11-04 were recorded
  locally for comparison.
- Not measured: volatile sessions; weekend depth for the caps in `docs/safe-limits.md`.
- Not done: a cost for pushes shorter than a minute; an audit.

## Versions
Tagged `vX.Y.Z`. Apps should pin a tag (as a git submodule at that tag) and move to a new tag on
purpose, never to the latest commit. hyperevm-lend and hyperevm-perp pin `v0.3.1`, Day One `v0.3.0`, Summon `v0.3.2` (Used in).
- `v0.1.0` (b596268): `HLPriceGuard`, `PythRef`, `JumpLatch`, `ExposureBudget` (fixed window).
- `v0.2.0` (d996453): adds `ExposureBudget.Rolling`, a cap that no stretch of the window can exceed,
  and `reconfigure` that waits on the last spend. Do not pin: a spend at timestamp 0 was treated as
  "never spent", so `reconfigure` skipped the wait.
- `v0.2.1` (f18cdd4): the same, with that fix. The first version safe to pin for `Rolling`; new
  projects should pin the latest tag.
- `v0.3.0` (b343536): `szDecimals` over 6 reverts (`BadSzDecimals`; it used to mis-scale, and overflow from 46);
  `lenientPrice`, `oracleOnly` and `NoPrice`; `test/HLTest` for testing apps locally, alone or
  inside hyper-evm-lib's simulator (`installBboOnly`, `setBbo`); source files
  carry the Apache-2.0 SPDX identifier (they said UNLICENSED).
- `v0.3.1` (f151b2d): adds `HLTest.setBookRaw`, for tests that hold prices in the precompiles' own units
  (as hyperevm-lend and hyperevm-perp do). No change to the library contracts.
- `v0.3.2` (e82819a): adds `PythRef.readFresh` and `updateAndReadFresh`, for contracts that read Pyth without
  an HL quote (`read` leaves staleness to `HLPriceGuard.check`, which needs one). No change to existing
  functions.
- `v0.4.0` (4d6a832): adds `PythRef.readFirstAfter` (the first Pyth update at or after a set time, through
  `parsePriceFeedUpdatesUnique`) and `PythRef.toRef`; `IPyth` gains `PriceFeed` and
  `parsePriceFeedUpdatesUnique`. `read` now calls `toRef`, with the same result. A minor version because
  `IPyth` grew: a contract that implements it must add the new function.

## Tests
`forge test`. Precompiles are mocked at their real addresses with mainnet values (`HLTest`, the
same mock apps use): forge's fork mode cannot run HyperEVM's custom precompiles. `test/Live.t.sol` checks what the mocks assume
against mainnet: it fetches real precompile output over the public RPC and decodes it with
`HLPrecompiles` for BTC, ETH, xyz:TSLA and the L1 block number, and reads HyperEVM's Pyth
through `PythRef` (`HL_LIVE=true forge test --match-contract Live`). Its bounds are loose: it
catches a wrong encoding or scale, not a market anomaly. CI (`.github/workflows/test.yml`) runs
the suite on pushes to `main` and pull requests, and the live check then and daily.
- `test/HLPriceGuard.t.sol`: each check against mainnet values and the two incidents;
  `lenientPrice` and `oracleOnly` (including a 0 price), and `szDecimals` over 6 reverting.
  `ExposureBudget.Rolling` has two fuzz tests (with and without `reconfigure`) that check every
  admitted spend against the cap and window it was admitted under.
- `test/Properties.t.sol`: fuzz tests that `check` never passes a price outside an enabled bound
  and never reports a breach within one, that `diffBps` rounds up, and that the jump latch moves
  its anchor only on an accepted read, that `lenientPrice` returns one of the two feeds and the one
  on the position's side; `PythRef.updateAndRead` paying the fee and reading the update;
  `PythRef.readFirstAfter` taking the first update after the time and refusing a later print, one past
  the window, or a wide confidence.
- `test/Quickstart.t.sol`: `examples/GuardedMarket.sol` on a normal ETH book (accepted) and on
  Papertrade's pushed book (rejected), through `HLTest`; shown to fail with the mid check turned off.
  The Quickstart's install steps were run in a fresh Foundry project (`forge install` of `v0.3.0`
  from GitHub, forge 1.7.1) and the README test passed there; repeated for `v0.3.1` with a
  `setBookRaw` test.
- `examples/with-hyper-evm-lib/GuardedMarketSim.t.sol` is not run here (it needs hyper-evm-lib and
  mainnet). It was run in a project with both libraries (hyper-evm-lib `4eb7ab0`, 2026-11-03): 3
  passed, and the mark test failed with the mark check turned off.
- `test/Integration.t.sol`: an example settlement contract wiring Pyth, the tripwires, the latch
  and a rolling cap the way docs/safe-limits.md recommends, run through Papertrade- and
  SKHX-like moves. A starting point for apps, not part of the library.
- Each fuzz test was shown to fail when the check it covers is removed or weakened.
- Not covered: the library running on HyperEVM itself (it runs locally; only what the precompiles
  and Pyth return is fetched from HyperEVM), and pushes shorter than a minute.

## License
Apache-2.0 (see `LICENSE`). Not audited.
