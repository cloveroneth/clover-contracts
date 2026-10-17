// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {CloverCanvas} from "./CloverCanvas.sol";
import {EthereumNativeFeeVaultV3} from "./programmable/EthereumNativeFeeVaultV3.sol";
import {CloverLaunchProtection} from "./CloverLaunchProtection.sol";
import {CloverOpeningTaxVault} from "./CloverOpeningTaxVault.sol";

/// @title CloverHook
/// @notice Shared Uniswap v4 hook for the $CLOVER pool and every pool created by the Launchpad.
///
/// Fee disclosure (see FEES.md):
/// - Asset: native ETH only (`currency0 == address(0)`).
/// - Base: gross ETH amount of the trade. Buy: ETH paid by the trader, fees included.
///   Sell: ETH leaving the pool, before fees.
/// - Rates in hundredths of a bip (denominator 1_000_000). Programmable platform fee: 3_000 (30 bps),
///   never derived from `PoolKey.fee` (which is 0). Token fee: 1 to 10 %, set at launch.
/// - Rounding: on the same base, the platform fee is rounded up once per trade and the token fee is floored.
/// - Enforced in the pool on every swap, whatever the router (programmable.market, Uniswap, aggregators),
///   including the Genesis initial buy, on every pool of this hook.
/// - Platform accounting: backed PoolManager native claims. During the swap the hook mints `platform` ERC-6909
///   native claims (id 0) to `feeVault` and records them with `feeVault.recordFees(platform, 0)`. `feeVault` is
///   Programmable's unmodified `EthereumNativeFeeVaultV3`, created by this constructor (kernel = this hook); it
///   reverts unless its claim balance backs `platformAccrued`. Its creator ledger is never used.
/// - Recipient and claim path: `feeVault.claimPlatform()` is permissionless and always pays the vault's fixed
///   `PLATFORM_RECIPIENT` (0xD88539d3c4C460136a733A3Fd60cf6BF269079da). No owner, setter or other withdrawal.
/// - Token fee: taken from the PoolManager with `take` and split: `canvasShareBps` accrues for the token's
///   canvas (sent by the permissionless `flush`), the rest is owed to the token creator.
///
/// Opening protection (anti-sniping), on every pool from its creation, in separate components created by this
/// constructor:
/// - `protection` (CloverLaunchProtection): 99 % opening buy fee decaying to the normal rate over 30 s with fixed
///   exemptions (creator + up to 6 wallets); for 300 s, buys only from the Launchpad or an approved router, and
///   cumulative 2 % caps per authenticated buyer and per recipient (the token reports its transfers).
/// - `openingTaxVault` (CloverOpeningTaxVault): custody of the opening tax, the part of an early buy fee above the
///   normal rate. It never enters the platform fee, the token fee or the creator / canvas balances.
/// The platform fee stays ceil 30 bps of the gross on every trade, opening buys included.
contract CloverHook is IHooks {
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- constants

    uint256 public constant PIPS = 1_000_000;
    uint256 public constant BPS = 10_000;
    /// @notice Programmable platform fee: 30 bps.
    uint24 public constant PLATFORM_FEE_PIPS = 3_000;
    uint24 public constant MIN_TOKEN_FEE_PIPS = 10_000;
    uint24 public constant MAX_TOKEN_FEE_PIPS = 100_000;
    uint16 public constant MIN_CANVAS_SHARE_BPS = 2_000;
    /// @notice Lowering the canvas share: at most 10 points, at most once per 7 days.
    uint16 public constant MAX_SHARE_DECREASE_BPS = 1_000;
    uint256 public constant SHARE_DECREASE_DELAY = 7 days;

    // ---------------------------------------------------------------- immutables

    IPoolManager public immutable poolManager;
    address public immutable PLATFORM_RECIPIENT;
    address public immutable DEPLOYER;


    // ---------------------------------------------------------------- wiring (set once)

    address public launchpad;
    CloverCanvas public canvas;

    /// @notice Programmable `EthereumNativeFeeVaultV3` holding the platform fee as backed PoolManager claims.
    /// @dev Written once by the constructor (the vault is this hook's first CREATE); there is no setter. Kept in
    ///      storage rather than as an immutable because its address derives from the hook's own address.
    EthereumNativeFeeVaultV3 public feeVault;
    /// @notice Opening protection component and opening tax custody, created by the constructor (no setter).
    CloverLaunchProtection public protection;
    CloverOpeningTaxVault public openingTaxVault;

    // ---------------------------------------------------------------- state

    struct PoolConfig {
        uint32 tokenIndex;
        uint24 tokenFeePips;
        bool registered;
    }

    struct TokenConfig {
        address creator;
        uint32 canvasId;
        uint16 canvasShareBps;
        uint64 lastDecrease;
    }

    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(uint256 tokenIndex => TokenConfig) public tokenConfig;
    mapping(uint256 tokenIndex => uint256) public canvasPending;
    mapping(address creator => uint256) public creatorOwed;

    // ---------------------------------------------------------------- events

    event Initialized(address launchpad, address canvas);
    event PoolRegistered(
        PoolId indexed poolId,
        uint256 indexed tokenIndex,
        address creator,
        uint256 canvasId,
        uint24 tokenFeePips,
        uint16 canvasShareBps
    );
    event OpeningTaxTaken(PoolId indexed poolId, address indexed sender, uint256 gross, uint256 openingTax);
    event FeeTaken(
        PoolId indexed poolId, address indexed sender, bool isBuy, uint256 gross, uint256 platform, uint256 tokenFee
    );
    event CanvasShareSet(uint256 indexed tokenIndex, uint16 canvasShareBps);
    event Flushed(uint256 indexed tokenIndex, uint256 canvasId, uint256 amount);
    event CreatorClaimed(address indexed creator, uint256 amount);

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error NotDeployer();
    error AlreadyInitialized();
    error NotLaunchpad();
    error NotCreator();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error HookNotImplemented();
    error InvalidFee();
    error ShareDecreaseTooLarge();
    error ShareDecreaseTooSoon();
    error AmountTooLarge();
    error TransferFailed();
    error ZeroAddress();
    error InvalidRecipient();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert NotLaunchpad();
        _;
    }

    constructor(IPoolManager poolManager_, address platformRecipient_, address routerA_, address routerB_) {
        if (address(poolManager_) == address(0) || platformRecipient_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        DEPLOYER = msg.sender;
        // Creator ledger unused: creatorRecipient is this hook, which never records creator fees in the vault.
        feeVault = new EthereumNativeFeeVaultV3(poolManager_, address(this));
        if (platformRecipient_ != feeVault.PLATFORM_RECIPIENT()) revert InvalidRecipient();
        PLATFORM_RECIPIENT = platformRecipient_;
        protection = new CloverLaunchProtection(address(poolManager_), routerA_, routerB_);
        openingTaxVault = new CloverOpeningTaxVault(address(poolManager_));
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice One-time wiring, called by the deployer (the Programmable Graph Factory) in the initializer phase.
    function initialize(address launchpad_, CloverCanvas canvas_) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (launchpad != address(0)) revert AlreadyInitialized();
        if (launchpad_ == address(0) || address(canvas_) == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        canvas = canvas_;
        emit Initialized(launchpad_, address(canvas_));
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- launchpad entry point

    /// @notice Registers the fee configuration of a pool before the Launchpad initializes it. The opening
    ///         protection starts now: `exempt` (at most 6 wallets) and `creator` skip the opening buy fee.
    function registerPool(
        PoolKey calldata key,
        uint256 tokenIndex,
        uint24 tokenFeePips,
        address creator,
        uint256 canvasId,
        uint16 canvasShareBps,
        address[] calldata exempt
    ) external onlyLaunchpad {
        PoolId id = key.toId();
        if (poolConfig[id].registered) revert PoolAlreadyRegistered();
        if (
            tokenFeePips < MIN_TOKEN_FEE_PIPS || tokenFeePips > MAX_TOKEN_FEE_PIPS
                || canvasShareBps < MIN_CANVAS_SHARE_BPS || canvasShareBps > BPS
        ) revert InvalidFee();
        poolConfig[id] = PoolConfig({tokenIndex: uint32(tokenIndex), tokenFeePips: tokenFeePips, registered: true});
        tokenConfig[tokenIndex] =
            TokenConfig({creator: creator, canvasId: uint32(canvasId), canvasShareBps: canvasShareBps, lastDecrease: 0});
        emit PoolRegistered(id, tokenIndex, creator, canvasId, tokenFeePips, canvasShareBps);
        protection.register(tokenIndex, Currency.unwrap(key.currency1), creator, exempt);
    }

    // ---------------------------------------------------------------- token creator

    /// @notice Raising the canvas share is instant. Lowering it is limited to 10 points per 7 days,
    ///         with a floor of 20 %.
    function setCanvasShare(uint256 tokenIndex, uint16 canvasShareBps) external {
        TokenConfig storage t = tokenConfig[tokenIndex];
        if (msg.sender != t.creator) revert NotCreator();
        if (canvasShareBps < MIN_CANVAS_SHARE_BPS || canvasShareBps > BPS) revert InvalidFee();
        if (canvasShareBps < t.canvasShareBps) {
            if (t.canvasShareBps - canvasShareBps > MAX_SHARE_DECREASE_BPS) revert ShareDecreaseTooLarge();
            if (t.lastDecrease != 0 && block.timestamp < t.lastDecrease + SHARE_DECREASE_DELAY) {
                revert ShareDecreaseTooSoon();
            }
            t.lastDecrease = uint64(block.timestamp);
        }
        t.canvasShareBps = canvasShareBps;
        emit CanvasShareSet(tokenIndex, canvasShareBps);
    }

    function claimCreator() external returns (uint256 amount) {
        amount = creatorOwed[msg.sender];
        if (amount == 0) return 0;
        creatorOwed[msg.sender] = 0;
        emit CreatorClaimed(msg.sender, amount);
        _send(msg.sender, amount);
    }

    // ---------------------------------------------------------------- permissionless

    /// @notice Sends the accrued canvas share of a token's fees to its canvas rewards.
    function flush(uint256 tokenIndex) external returns (uint256 amount) {
        amount = canvasPending[tokenIndex];
        if (amount == 0) return 0;
        canvasPending[tokenIndex] = 0;
        uint256 canvasId = tokenConfig[tokenIndex].canvasId;
        emit Flushed(tokenIndex, canvasId, amount);
        canvas.fund{value: amount}(canvasId);
    }

    /// @notice Platform fees accrued and not yet claimed (held by `feeVault`).
    function platformAccrued() external view returns (uint256) {
        return feeVault.platformAccrued();
    }

    // ---------------------------------------------------------------- views

    /// @notice Fee components for a gross ETH amount, as charged by the hook outside the opening window.
    function quoteFee(PoolId id, uint256 gross) external view returns (uint256 platform, uint256 tokenFee) {
        platform = (gross * PLATFORM_FEE_PIPS + PIPS - 1) / PIPS;
        tokenFee = gross * poolConfig[id].tokenFeePips / PIPS;
    }

    /// @notice Current total fee rate (pips) of a buy by `buyer`, opening fee included.
    function buyFeePips(PoolId id, address buyer) external view returns (uint256) {
        PoolConfig memory cfg = _config(id);
        return protection.ratePipsFor(cfg.tokenIndex, buyer, _normalRate(cfg));
    }

    // ---------------------------------------------------------------- hook callbacks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != launchpad) revert NotLaunchpad();
        if (!poolConfig[key.toId()].registered) revert PoolNotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != launchpad) revert NotLaunchpad();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Exact-in buy: fee on the ETH input. Exact-out sell: fee on the ETH output, the pool delivers
    ///      `A + fee` so the trader receives exactly `A`. Both return a positive specified delta.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactInput = params.amountSpecified < 0;
        // Specified currency is ETH for exact-in buys (zeroForOne) and exact-out sells (!zeroForOne).
        if (exactInput != params.zeroForOne) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = _beforeSwapFee(sender, key.toId(), params.zeroForOne, params.amountSpecified);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(fee), 0), 0);
    }

    function _beforeSwapFee(address sender, PoolId id, bool isBuy, int256 amountSpecified) private returns (uint256) {
        PoolConfig memory cfg = _config(id);
        uint256 rate = _rate(cfg, sender, isBuy);
        uint256 gross;
        if (amountSpecified < 0) {
            gross = uint256(-amountSpecified);
        } else {
            gross = uint256(amountSpecified) * PIPS / (PIPS - rate);
        }
        return _charge(id, cfg, sender, isBuy, gross, rate);
    }

    /// @dev Every buy: opening buyer limit. Exact-in sell: fee on the ETH output. Exact-out buy: fee on the gross
    ///      ETH input. Both return a positive unspecified delta (ETH).
    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolConfig memory cfg = _config(id);
        if (params.zeroForOne && delta.amount1() > 0) {
            protection.recordBuy(cfg.tokenIndex, sender, uint256(uint128(delta.amount1())));
        }
        bool exactInput = params.amountSpecified < 0;
        if (exactInput == params.zeroForOne) return (IHooks.afterSwap.selector, 0);
        return (IHooks.afterSwap.selector, _afterSwapFee(sender, id, cfg, exactInput, delta.amount0()));
    }

    function _afterSwapFee(address sender, PoolId id, PoolConfig memory cfg, bool exactInput, int128 amount0)
        private
        returns (int128)
    {
        // exactInput here means a sell (oneForZero); otherwise an exact-out buy.
        uint256 rate = _rate(cfg, sender, !exactInput);
        uint256 gross;
        if (exactInput) {
            // Sell exact-in: ETH leaves the pool, amount0 > 0.
            gross = amount0 > 0 ? uint256(uint128(amount0)) : 0;
        } else {
            // Buy exact-out: ETH enters the pool, amount0 < 0. Gross = net + fees.
            uint256 net = amount0 < 0 ? uint256(uint128(-amount0)) : 0;
            gross = net * PIPS / (PIPS - rate);
        }
        if (gross == 0) return 0;
        return _toInt128(_charge(id, cfg, sender, !exactInput, gross, rate));
    }

    // ---------------------------------------------------------------- unused callbacks

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------- internals

    function _config(PoolId id) private view returns (PoolConfig memory cfg) {
        cfg = poolConfig[id];
        if (!cfg.registered) revert PoolNotRegistered();
    }

    function _normalRate(PoolConfig memory cfg) private pure returns (uint256) {
        return uint256(PLATFORM_FEE_PIPS) + cfg.tokenFeePips;
    }

    /// @dev Total fee rate: the normal rate, or for a buy the protection's opening rate (99 % decaying to normal
    ///      over 30 s, except exempt buyers).
    function _rate(PoolConfig memory cfg, address sender, bool isBuy) private view returns (uint256) {
        if (!isBuy) return _normalRate(cfg);
        return protection.buyRatePips(cfg.tokenIndex, sender, _normalRate(cfg));
    }

    function _charge(PoolId id, PoolConfig memory cfg, address sender, bool isBuy, uint256 gross, uint256 rate)
        private
        returns (uint256 fee)
    {
        uint256 platform = (gross * PLATFORM_FEE_PIPS + PIPS - 1) / PIPS;
        uint256 tokenFee = gross * cfg.tokenFeePips / PIPS;
        // Opening buys: the part above the normal rate, same base, floored, to the opening tax vault.
        uint256 openingTax = gross * (rate - _normalRate(cfg)) / PIPS;
        fee = platform + tokenFee + openingTax;
        if (fee == 0) return 0;

        if (openingTax != 0) {
            emit OpeningTaxTaken(id, sender, gross, openingTax);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(openingTaxVault), openingTax);
            openingTaxVault.record(cfg.tokenIndex, openingTax);
        }

        if (tokenFee != 0) {
            TokenConfig storage t = tokenConfig[cfg.tokenIndex];
            uint256 toCanvas = tokenFee * t.canvasShareBps / BPS;
            canvasPending[cfg.tokenIndex] += toCanvas;
            creatorOwed[t.creator] += tokenFee - toCanvas;
        }
        emit FeeTaken(id, sender, isBuy, gross, platform, tokenFee);
        if (platform != 0) {
            poolManager.mint(address(feeVault), CurrencyLibrary.ADDRESS_ZERO.toId(), platform);
            feeVault.recordFees(platform, 0);
        }
        if (tokenFee != 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), tokenFee);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _toInt128(uint256 x) private pure returns (int128) {
        if (x > uint128(type(int128).max)) revert AmountTooLarge();
        return int128(int256(x));
    }

    /// @dev Accepts ETH only from the PoolManager (`take`).
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }
}
