# CLOVER contracts

Onchain pixel canvases on Ethereum, funded by the swap fees of tokens trading through a shared Uniswap v4 hook.
Site: https://cloverpixel.xyz · X: https://x.com/CloverOnETH

| Contract | Role |
| --- | --- |
| `src/CloverHook.sol` | Shared v4 hook (permissions mask `0x28CC`). Takes the fees in native ETH on every swap. |
| `src/CloverCanvas.sol` | Canvases of ERC-721 pixels: capture at the holder's price, weekly rent from a deposit, linear fade. |
| `src/Launchpad.sol` | Creates the pools, seeds single-sided liquidity, runs the `genesis` launch and later `launchWithCanvas`. |
| `src/CloverToken.sol` | Fixed-supply ERC-20 (1,000,000,000), minted once to the Launchpad; reports transfers to the protection for 300 s. |
| `src/CloverLaunchProtection.sol` | Opening fee decay, fixed exemptions, authenticated buyer and 2 % buyer / recipient caps (created by the hook). |
| `src/CloverOpeningTaxVault.sol` | Custody of the opening tax, claim to the token creator (created by the hook). |
| `src/programmable/EthereumNativeFeeVaultV3.sol` | Programmable's fee vault, unmodified, created by the hook. |

## Fees

All fees are charged **inside the pool by the hook**, in native ETH, on the gross ETH leg of every swap
(buy: ETH paid, sell: ETH out), whatever the router: programmable.market, Uniswap, aggregators, and the Genesis
initial buy in the launch transaction. The pool LP fee is 0.

**$CLOVER: 3.3 % per trade** = 0.3 % Programmable platform fee + 3 % CLOVER fee, both on the same gross base.

- **Programmable platform fee: 30 bps**, `ceil(gross * 30 / 10000)` once per trade, on every pool of the hook.
  Accounting is backed PoolManager native claims: during the swap the hook mints the fee as ERC-6909 native
  claims (id 0) to `feeVault` and calls `feeVault.recordFees(platform, 0)`. `feeVault` is Programmable's
  unmodified `EthereumNativeFeeVaultV3` (`src/programmable/`), created by the hook's constructor with
  `kernel = hook`; it reverts unless its claim balance backs `platformAccrued`. `feeVault.claimPlatform()` is
  permissionless and always pays the fixed recipient `0xD88539d3c4C460136a733A3Fd60cf6BF269079da`. No owner,
  setter or other withdrawal path. The vault's creator ledger is never used.
- **CLOVER fee: 3 %** (`floor`), taken by the hook with `take`: 20 % goes to the Genesis canvas (sent by the
  permissionless `flush`), 80 % to the creator (`claimCreator`). The canvas share can be raised at any time, and
  lowered by at most 10 points per 7 days, never below 20 %.
- Pools created later by the Launchpad use the same hook: same 30 bps platform fee into the same vault, plus their
  own token fee (1 to 10 %).

Example, buy of 1 ETH (any router): 0.003 ETH platform fee to the vault, 0.03 ETH CLOVER fee, 0.967 ETH buys tokens.

The fork test `test/fork/CloverLaunchFork.t.sol` checks, with exact deltas of `platformAccrued`, of the vault's
claim backing and of the recipient balance: the initial buy, buy/sell exact-in/exact-out at two sizes through the
canonical Uniswap Universal Router and through the router used by programmable.market, a second wallet after
9 days, and the claim (log: `launch/evidence/fork-launch-test.txt`).

## Opening protection (anti-snipe)

Three components, apart from the fee accounting, all created by the `CloverHook` constructor or set at launch:

- **Starting FDV >= $15,000** (`Launchpad.startTick`): at launch the Launchpad reads Chainlink ETH/USD
  (`0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`), requires a positive answer updated within the last hour, and starts
  the pool at the highest tick on the 200 grid whose FDV is at least $15,000 (one grid step, about 2 %, above at
  most). The price and tick are stored in `tokenInfo` and emitted in `StartPrice`.
- **Opening buy fee** (`CloverLaunchProtection`): the total buy fee starts at **99 %** and decays linearly to the
  normal rate (3.3 % for $CLOVER) over **30 seconds**. The platform fee stays exactly ceil 30 bps of the gross and
  the token fee stays at its normal rate; only the surplus is the **opening tax**, held in the dedicated
  `CloverOpeningTaxVault` (backed native ETH, permissionless `claim` to the token creator). Sells always pay the
  normal rate. The token creator and up to **6 wallets** fixed at launch pay the normal rate from the first block
  ($CLOVER: `genesis.exemptWallets` in `launch/launch.params.json`, `Launchpad.genesisExemptWallets()`; later
  tokens: `LaunchParams.exemptWallets`). They cannot be changed.
- **Authenticated buyer and recipient caps, 300 seconds** (`CloverLaunchProtection` + `CloverToken`): buys are
  accepted only from the Launchpad (initial buy, buyer = creator) or an approved router (Uniswap Universal Router
  `0x66a9…8Af`, programmable.market router `0xd92A…446C`), whose `msgSender()` is the buyer. Each buyer can buy at
  most **2 % of the supply** (20,000,000) and each recipient can receive at most 2 %, cumulatively: the token
  reports every transfer, infrastructure (PoolManager, hook, Launchpad, approved routers) excepted. Exempt wallets
  and the creator's initial buy are included; sending tokens away never resets either ledger.

## Liquidity## Liquidity

`Launchpad` initializes each pool and adds the whole token supply as one single-sided position
(ticks `-887200` to the oracle-derived start tick, spacing 200). The position is owned by the Launchpad, which has no function
to remove it: the liquidity is permanent.

## Build and test

```sh
forge build
forge test --no-match-path 'test/fork/*'
ETH_RPC_URL=<mainnet rpc> forge test --match-path 'test/fork/*'   # Router launch, then swaps through Uniswap and Programmable routers
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
