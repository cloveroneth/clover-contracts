# CLOVER contracts

Onchain pixel canvases on Ethereum, funded by the swap fees of tokens trading through a shared Uniswap v4 hook.
Site: https://cloverpixel.xyz · X: https://x.com/CloverOnETH

| Contract | Role |
| --- | --- |
| `src/CloverHook.sol` | Shared v4 hook (permissions mask `0x28CC`). Takes the fees in native ETH on every swap. |
| `src/CloverCanvas.sol` | Canvases of ERC-721 pixels: capture at the holder's price, weekly rent from a deposit, linear fade. |
| `src/Launchpad.sol` | Creates the pools, seeds single-sided liquidity, runs the `genesis` launch and later `launchWithCanvas`. |
| `src/CloverToken.sol` | Fixed-supply ERC-20 (1,000,000,000), minted once to the Launchpad. |

## Fees

All fees are charged by the hook in native ETH, on the gross ETH leg of each trade (buy: ETH paid, sell: ETH out).

- **Programmable platform fee: 30 bps**, rounded up once per trade, accrued in `platformAccrued` and paid by the
  permissionless `claimPlatform()` to the immutable `PLATFORM_RECIPIENT`
  (`0xD88539d3c4C460136a733A3Fd60cf6BF269079da`). It applies to every pool on the hook, including the initial buy.
- **Token fee**: 1 to 10 %, fixed per token at launch (3 % for $CLOVER). `canvasShareBps` of it goes to the token's
  canvas (sent by the permissionless `flush`), the rest to the token creator (`claimCreator`). $CLOVER sends 100 %
  to the Genesis canvas. The canvas share can be raised at any time, and lowered by at most 10 points per 7 days,
  never below 20 %.
- The pool LP fee is 0.

## Liquidity

`Launchpad` initializes each pool and adds the whole token supply as one single-sided position
(ticks `-887200` to `200200`, spacing 200). The position is owned by the Launchpad, which has no function
to remove it: the liquidity is permanent.

## Build and test

```sh
forge build
forge test --no-match-path 'test/fork/*'
ETH_RPC_URL=<mainnet rpc> forge test --match-path 'test/fork/*'   # full launch through the Programmable Router
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
