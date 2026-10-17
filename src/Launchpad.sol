// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CloverToken, ICloverTransferProtection} from "./CloverToken.sol";
import {CloverHook} from "./CloverHook.sol";
import {CloverCanvas} from "./CloverCanvas.sol";

/// @dev Chainlink price feed (ETH / USD, 8 decimals on Ethereum mainnet).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title Launchpad
/// @notice Launches a token with its canvas in one transaction: token, ETH pool on the shared CloverHook,
///         locked single-sided liquidity, canvas, and the creator's optional first buy.
///
/// Liquidity: 100 % of the supply in one position [TICK_LOWER, startTick] owned by this contract.
/// The pool starts at startTick, so the position holds only the token.
/// Starting FDV: at least $15,000, enforced at launch with a fresh Chainlink ETH/USD price (`ETH_USD_FEED`,
/// updated within the last hour): startTick is the highest tick on the 200 grid whose FDV is >= $15,000.
/// Opening protection (CloverLaunchProtection, see CloverHook): 99 % buy fee decaying over 30 s, 2 % caps per
/// authenticated buyer and per recipient for 300 s; the creator and up to 6 wallets chosen at launch skip the
/// opening fee.
/// There is no function that removes liquidity: it is locked forever.
contract Launchpad is ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- constants

    /// @notice Paid on every launch, into the Genesis canvas rewards.
    uint256 public constant LAUNCH_FEE = 0.01 ether;
    int24 public constant TICK_SPACING = 200;
    /// @notice Minimum starting FDV, in USD.
    uint256 public constant MIN_START_FDV_USD = 15_000;
    /// @notice The ETH/USD price must have been updated within this delay (Chainlink heartbeat: 1 hour).
    uint256 public constant ORACLE_MAX_AGE = 1 hours;
    /// @dev ceil(MIN_TICK / 200) * 200.
    int24 public constant TICK_LOWER = -887_200;

    // ---------------------------------------------------------------- immutables

    IPoolManager public immutable poolManager;
    CloverHook public immutable hook;
    /// @notice Chainlink ETH / USD price feed on Ethereum mainnet.
    IAggregatorV3 public constant ETH_USD_FEED = IAggregatorV3(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    CloverCanvas public immutable canvas;
    address public immutable DEPLOYER;

    /// @dev Genesis ($CLOVER) parameters, fixed at deployment.
    address public immutable genesisCreator;
    uint16 public immutable genesisTokenFeeBps;
    /// @dev Share of the $CLOVER token fee sent to the Genesis canvas; the rest is owed to `genesisCreator`.
    uint16 public immutable genesisCanvasShareBps;
    uint8 public immutable genesisSize;
    uint16 public immutable genesisRentBps;
    uint32 public immutable genesisFadeTime;
    uint96 public immutable genesisStartPrice;

    // ---------------------------------------------------------------- state

    struct TokenInfo {
        address token;
        address creator;
        uint32 canvasId;
        uint16 tokenFeeBps;
        uint64 createdAt;
        PoolId poolId;
        int24 startTick;
        uint256 ethUsd;
    }

    struct LaunchParams {
        string name;
        string symbol;
        uint16 tokenFeeBps;
        uint16 canvasShareBps;
        string canvasName;
        uint8 size;
        uint16 rentBps;
        uint32 fadeTime;
        uint96 startPrice;
        uint256 devBuyMinOut;
        /// @dev Up to 6 wallets exempt from the opening buy fee, besides the creator.
        address[] exemptWallets;
    }

    /// @dev Wallets exempt from the $CLOVER opening buy fee, besides `genesisCreator` (at most 6).
    address[] internal _genesisExempt;

    TokenInfo[] internal _tokens;
    mapping(address token => uint256) public tokenIndexPlusOne;
    mapping(address creator => uint256) public nonces;

    event TokenLaunched(
        uint256 indexed tokenIndex,
        address indexed token,
        address indexed creator,
        PoolId poolId,
        uint256 canvasId,
        string name,
        string symbol,
        uint16 tokenFeeBps,
        uint16 canvasShareBps
    );
    event LiquidityLocked(uint256 indexed tokenIndex, uint128 liquidity, uint256 tokenAmount, uint256 dust);
    event DevBuy(uint256 indexed tokenIndex, address indexed creator, uint256 ethIn, uint256 tokensOut);
    event StartPrice(uint256 indexed tokenIndex, uint256 ethUsd, int24 startTick, uint256 startFdvWei);

    error NotDeployer();
    error AlreadyGenesis();
    error GenesisNotDone();
    error NotPoolManager();
    error InvalidParams();
    error InsufficientValue();
    error SlippageExceeded(uint256 out, uint256 minOut);
    error ZeroAddress();
    error StaleOracle();
    error BadOracle();

    constructor(
        IPoolManager poolManager_,
        CloverHook hook_,
        CloverCanvas canvas_,
        address genesisCreator_,
        uint16 genesisTokenFeeBps_,
        uint16 genesisCanvasShareBps_,
        uint8 genesisSize_,
        uint16 genesisRentBps_,
        uint32 genesisFadeTime_,
        uint96 genesisStartPrice_,
        address[] memory genesisExempt_
    ) {
        if (
            address(poolManager_) == address(0) || address(hook_) == address(0) || address(canvas_) == address(0)
                || genesisCreator_ == address(0)
        ) revert ZeroAddress();
        poolManager = poolManager_;
        hook = hook_;
        canvas = canvas_;
        DEPLOYER = msg.sender;
        genesisCreator = genesisCreator_;
        genesisTokenFeeBps = genesisTokenFeeBps_;
        genesisCanvasShareBps = genesisCanvasShareBps_;
        genesisSize = genesisSize_;
        genesisRentBps = genesisRentBps_;
        genesisFadeTime = genesisFadeTime_;
        genesisStartPrice = genesisStartPrice_;
        if (genesisExempt_.length > 6) revert InvalidParams();
        _genesisExempt = genesisExempt_;
    }

    // ---------------------------------------------------------------- genesis ($CLOVER, tokenIndex 0, canvas 0)

    /// @notice Last initializer of the Programmable graph. Sets up the $CLOVER pool, its locked liquidity and
    ///         the Genesis canvas (canvas share 100 %). `msg.value` is an initial buy for `genesisCreator`.
    function genesis(CloverToken clover) external payable nonReentrant {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (_tokens.length != 0) revert AlreadyGenesis();
        uint256 canvasId = canvas.createCanvasFor(
            genesisCreator, "Genesis", genesisSize, genesisRentBps, genesisFadeTime, genesisStartPrice, address(clover)
        );
        _launch(
            address(clover), genesisCreator, genesisTokenFeeBps, genesisCanvasShareBps, canvasId, _genesisExempt, msg.value, 0
        );
    }

    // ---------------------------------------------------------------- public launch

    /// @notice Launches a token and its canvas. `msg.value = LAUNCH_FEE + optional dev buy`.
    function launchWithCanvas(LaunchParams calldata p)
        external
        payable
        nonReentrant
        returns (uint256 tokenIndex, address token, uint256 canvasId)
    {
        if (_tokens.length == 0) revert GenesisNotDone();
        if (msg.value < LAUNCH_FEE) revert InsufficientValue();
        uint256 nameLen = bytes(p.name).length;
        uint256 symbolLen = bytes(p.symbol).length;
        if (nameLen == 0 || nameLen > 64 || symbolLen == 0 || symbolLen > 16) revert InvalidParams();

        bytes32 salt = keccak256(abi.encode(msg.sender, nonces[msg.sender]++));
        token = address(new CloverToken{salt: salt}(p.name, p.symbol, address(this)));
        canvas.fund{value: LAUNCH_FEE}(0);
        canvasId = canvas.createCanvasFor(msg.sender, p.canvasName, p.size, p.rentBps, p.fadeTime, p.startPrice, token);
        tokenIndex = _launch(
            token, msg.sender, p.tokenFeeBps, p.canvasShareBps, canvasId, p.exemptWallets, msg.value - LAUNCH_FEE, p.devBuyMinOut
        );
    }

    // ---------------------------------------------------------------- views

    /// @notice Starting tick from the current ETH/USD price: the highest tick on the 200 grid whose FDV
    ///         (1e9 tokens) is at least `MIN_START_FDV_USD`. Reverts on a stale or invalid price.
    function startTick() public view returns (int24 tick, uint256 ethUsd) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = ETH_USD_FEED.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert BadOracle();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > ORACLE_MAX_AGE) revert StaleOracle();
        ethUsd = uint256(answer);
        uint256 unit = 10 ** ETH_USD_FEED.decimals();
        // Tokens per ETH at an FDV of exactly MIN_START_FDV_USD: 1e9 * ethUsd / 15,000, as a Q192 ratio.
        uint256 ratioX192 = FullMath.mulDiv(1e9 * ethUsd, 1 << 192, MIN_START_FDV_USD * unit);
        int24 t = TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(ratioX192)));
        // Fewer tokens per ETH is a higher FDV: round down onto the grid.
        tick = t - (((t % TICK_SPACING) + TICK_SPACING) % TICK_SPACING);
        if (tick <= TICK_LOWER) revert BadOracle();
    }

    function genesisExemptWallets() external view returns (address[] memory) {
        return _genesisExempt;
    }

    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    function tokenInfo(uint256 tokenIndex) external view returns (TokenInfo memory) {
        return _tokens[tokenIndex];
    }

    function poolKeyOf(address token) public view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function predictTokenAddress(address creator, uint256 nonce, string calldata name, string calldata symbol)
        external
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(creator, nonce));
        bytes32 initHash =
            keccak256(abi.encodePacked(type(CloverToken).creationCode, abi.encode(name, symbol, address(this))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    // ---------------------------------------------------------------- internals

    function _launch(
        address token,
        address creator,
        uint16 tokenFeeBps,
        uint16 canvasShareBps,
        uint256 canvasId,
        address[] memory exempt,
        uint256 devBuy,
        uint256 devBuyMinOut
    ) private returns (uint256 tokenIndex) {
        tokenIndex = _push(token, creator, tokenFeeBps, canvasId);
        PoolKey memory key = poolKeyOf(token);
        hook.registerPool(key, tokenIndex, uint24(tokenFeeBps) * 100, creator, canvasId, canvasShareBps, exempt);
        _startProtection(tokenIndex, token);
        _initPool(tokenIndex, key);
        _emitLaunched(tokenIndex, canvasShareBps);
        if (devBuy != 0) _devBuy(tokenIndex, key, creator, devBuy, devBuyMinOut);
    }

    function _push(address token, address creator, uint16 tokenFeeBps, uint256 canvasId)
        private
        returns (uint256 tokenIndex)
    {
        tokenIndex = _tokens.length;
        (int24 tick, uint256 ethUsd) = startTick();
        _tokens.push(
            TokenInfo({
                token: token,
                creator: creator,
                canvasId: uint32(canvasId),
                tokenFeeBps: tokenFeeBps,
                createdAt: uint64(block.timestamp),
                poolId: poolKeyOf(token).toId(),
                startTick: tick,
                ethUsd: ethUsd
            })
        );
        tokenIndexPlusOne[token] = tokenIndex + 1;
    }

    function _startProtection(uint256 tokenIndex, address token) private {
        CloverLaunchProtectionLike protection = CloverLaunchProtectionLike(address(hook.protection()));
        CloverToken(token).startProtection(
            ICloverTransferProtection(address(protection)), protection.protectionEnds(tokenIndex)
        );
    }

    function _devBuy(uint256 tokenIndex, PoolKey memory key, address creator, uint256 devBuy, uint256 minOut) private {
        uint256 out = abi.decode(poolManager.unlock(abi.encode(uint8(1), key, devBuy, creator, int24(0))), (uint256));
        if (out < minOut) revert SlippageExceeded(out, minOut);
        emit DevBuy(tokenIndex, creator, devBuy, out);
    }

    function _initPool(uint256 tokenIndex, PoolKey memory key) private {
        TokenInfo storage t = _tokens[tokenIndex];
        uint160 sqrtStart = TickMath.getSqrtPriceAtTick(t.startTick);
        poolManager.initialize(key, sqrtStart);
        // FDV in wei: 1e9 tokens at (2^96 / sqrtStart)^2 ETH per token.
        uint256 fdv = FullMath.mulDiv(1e9 ether, 1 << 192, uint256(sqrtStart) * sqrtStart);
        emit StartPrice(tokenIndex, t.ethUsd, t.startTick, fdv);
        _addLiquidity(tokenIndex, key, t.startTick);
    }

    function _emitLaunched(uint256 tokenIndex, uint16 canvasShareBps) private {
        TokenInfo storage t = _tokens[tokenIndex];
        emit TokenLaunched(
            tokenIndex,
            t.token,
            t.creator,
            t.poolId,
            t.canvasId,
            IERC20Metadata(t.token).name(),
            IERC20Metadata(t.token).symbol(),
            t.tokenFeeBps,
            canvasShareBps
        );
    }

    function _addLiquidity(uint256 tokenIndex, PoolKey memory key, int24 tickUpper) private {
        uint256 amount = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = uint128(FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtUpper - sqrtLower));
        uint256 paid = abi.decode(
            poolManager.unlock(abi.encode(uint8(0), key, uint256(liquidity), address(0), tickUpper)), (uint256)
        );
        emit LiquidityLocked(tokenIndex, liquidity, paid, amount - paid);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, PoolKey memory key, uint256 amount, address recipient, int24 tickUpper) =
            abi.decode(data, (uint8, PoolKey, uint256, address, int24));

        if (action == 0) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount),
                    salt: bytes32(0)
                }),
                ""
            );
            // Position is entirely token1 at the starting price: amount0 must be zero.
            if (delta.amount0() != 0) revert InvalidParams();
            uint256 owedTokens = uint256(uint128(-delta.amount1()));
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), owedTokens);
            poolManager.settle();
            return abi.encode(owedTokens);
        }

        BalanceDelta d = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 paid = uint256(uint128(-d.amount0()));
        uint256 out = uint256(uint128(d.amount1()));
        poolManager.settle{value: paid}();
        poolManager.take(key.currency1, recipient, out);
        return abi.encode(out);
    }
}

interface CloverLaunchProtectionLike {
    function protectionEnds(uint256 tokenIndex) external view returns (uint256);
}
