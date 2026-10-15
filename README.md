# CLOVER contracts

Onchain pixel canvases on Ethereum, funded by the swap fees of tokens trading through a shared Uniswap v4 hook.
Site: https://cloverpixel.xyz · X: https://x.com/CloverOnETH

| Contract | Role |
| --- | --- |
| `src/CloverHook.sol` | Shared v4 hook (permissions mask `0x28CC`). Takes the token fees in native ETH on every swap. |
| `src/CloverCanvas.sol` | Canvases of ERC-721 pixels: capture at the holder's price, weekly rent from a deposit, linear fade. |
| `src/Launchpad.sol` | Creates the pools, seeds single-sided liquidity, runs the `genesis` launch and later `launchWithCanvas`. |
| `src/CloverToken.sol` | Fixed-supply ERC-20 (1,000,000,000), minted once to the Launchpad. |

## Fees

All fees are in native ETH, on the ETH leg of each trade. The pool LP fee is 0.

**$CLOVER (Genesis pool, the Programmable launch), total for a trade:**

| Where the trade goes through | CLOVER fee (hook) | Programmable fee | Total |
| --- | --- | --- | --- |
| programmable.market (Programmable route) | 3 % | 0.3 % | about 3.3 % (3.291 %) |
| Any other router (Uniswap, aggregators) | 3 % | none | 3 % |
| Initial buy in the launch transaction | 3 % | 0.3 % | about 3.3 % (3.291 %) |

- **Programmable platform fee: 0.3 % (30 bps), one collection path.** On trades routed by programmable.market,
  Programmable's router collects it itself (policy `programmable.ethereum-routed-native-fee.v2`): on a buy, 30 bps
  of the ETH paid, sent to `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` before the swap; on a sell, 30 bps of the
  gross ETH output. The hook charges **no** platform fee on the Genesis pool, so there is no second charge.
  The Genesis initial buy does not go through that route, so `Launchpad.genesis` pays the same 30 bps of the
  funded ETH (floored) to the same recipient, atomically, before the swap.
- **CLOVER fee: 3 %**, taken by the hook on the ETH that reaches the pool (buy) or leaves it (sell): 20 % goes to
  the Genesis canvas (sent by the permissionless `flush`), 80 % to the creator (`claimCreator`). The canvas share
  can be raised at any time, and lowered by at most 10 points per 7 days, never below 20 %.

Example, buy of 1 ETH on programmable.market: 0.003 ETH to Programmable, then 3 % of the remaining 0.997 ETH
(0.02991 ETH) as the CLOVER fee, so 0.96709 ETH buys tokens.

**Pools created later by the Launchpad** (not Programmable launches, never routed by Programmable): the hook
charges the token fee (1 to 10 %, set by the creator) and the 30 bps platform fee itself, rounded up once per
trade, accrued in `platformAccrued` and paid by the permissionless `claimPlatform()` to the immutable
`PLATFORM_RECIPIENT` (`0xD88539d3c4C460136a733A3Fd60cf6BF269079da`).

The fork test `test/fork/CloverLaunchFork.t.sol` checks the exact recipient deltas for the initial buy, a buy and
a sell through the Programmable route, and a trade through the canonical Uniswap Universal Router
(log: `launch/evidence/fork-launch-test.txt`).

## Liquidity

`Launchpad` initializes each pool and adds the whole token supply as one single-sided position
(ticks `-887200` to `200200`, spacing 200). The position is owned by the Launchpad, which has no function
to remove it: the liquidity is permanent.

## Build and test

```sh
forge build
forge test --no-match-path 'test/fork/*'
ETH_RPC_URL=<mainnet rpc> forge test --match-path 'test/fork/*'   # Router launch, then trades through the Programmable route
```

Dependencies are vendored as plain files under `lib/` (Uniswap v4-core `e50237c`, OpenZeppelin Contracts `cab1993`,
solmate, forge-std) so the exact compiled sources are in this repository.

## Programmable launch package

`launch/build.mjs` compiles with solc `0.8.26+commit.8a97fa7a` (optimizer 1000, cancun, no CBOR) and writes
`programmable-launch.config.json` for the Programmable Launch CLI (`@programmable/launch` 4.1.6, profile 3.6.0):

```sh
cd launch && npm ci && CLOVER_SOURCE_REVISION=<this commit> node build.mjs && cd ..
programmable-launch pack --config programmable-launch.config.json --output launch.json
programmable-launch validate launch.json --config programmable-launch.config.json --remote
```

These contracts have not been audited.
