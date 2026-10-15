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
import {CloverToken} from "./CloverToken.sol";
import {CloverHook} from "./CloverHook.sol";
import {CloverCanvas} from "./CloverCanvas.sol";

/// @title Launchpad
/// @notice Launches a token with its canvas in one transaction: token, ETH pool on the shared CloverHook,
///         locked single-sided liquidity, canvas, and the creator's optional first buy.
///
/// Liquidity: 100 % of the supply in one position [TICK_LOWER, TICK_UPPER] owned by this contract.
/// The pool starts at TICK_UPPER, so the position holds only the token. Starting FDV is about 2 ETH.
/// There is no function that removes liquidity: it is locked forever.
contract Launchpad is ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- constants

    /// @notice Paid on every launch, into the Genesis canvas rewards.
    uint256 public constant LAUNCH_FEE = 0.01 ether;
    int24 public constant TICK_SPACING = 200;
    /// @dev floor(log_1.0001(1e9 / 2) / 200) * 200: starting FDV ~2.0224 ETH.
    int24 public constant TICK_UPPER = 200_200;
    /// @dev ceil(MIN_TICK / 200) * 200.
    int24 public constant TICK_LOWER = -887_200;

    // ---------------------------------------------------------------- immutables

    IPoolManager public immutable poolManager;
    CloverHook public immutable hook;
    CloverCanvas public immutable canvas;
    address public immutable DEPLOYER;

    /// @dev Genesis ($CLOVER) parameters, fixed at deployment.
    address public immutable genesisCreator;
    uint16 public immutable genesisTokenFeeBps;
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
    }

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

    error NotDeployer();
    error AlreadyGenesis();
    error GenesisNotDone();
    error NotPoolManager();
    error InvalidParams();
    error InsufficientValue();
    error SlippageExceeded(uint256 out, uint256 minOut);
    error ZeroAddress();

    constructor(
        IPoolManager poolManager_,
        CloverHook hook_,
        CloverCanvas canvas_,
        address genesisCreator_,
        uint16 genesisTokenFeeBps_,
        uint8 genesisSize_,
        uint16 genesisRentBps_,
        uint32 genesisFadeTime_,
        uint96 genesisStartPrice_
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
        genesisSize = genesisSize_;
        genesisRentBps = genesisRentBps_;
        genesisFadeTime = genesisFadeTime_;
        genesisStartPrice = genesisStartPrice_;
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
        _launch(address(clover), genesisCreator, genesisTokenFeeBps, 10_000, canvasId, msg.value, 0);
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
        tokenIndex =
            _launch(token, msg.sender, p.tokenFeeBps, p.canvasShareBps, canvasId, msg.value - LAUNCH_FEE, p.devBuyMinOut);
    }

    // ---------------------------------------------------------------- views

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
        uint256 devBuy,
        uint256 devBuyMinOut
    ) private returns (uint256 tokenIndex) {
        tokenIndex = _tokens.length;
        PoolKey memory key = poolKeyOf(token);
        PoolId poolId = key.toId();
        _tokens.push(
            TokenInfo({
                token: token,
                creator: creator,
                canvasId: uint32(canvasId),
                tokenFeeBps: tokenFeeBps,
                createdAt: uint64(block.timestamp),
                poolId: poolId
            })
        );
        tokenIndexPlusOne[token] = tokenIndex + 1;

        hook.registerPool(key, tokenIndex, uint24(tokenFeeBps) * 100, creator, canvasId, canvasShareBps);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(TICK_UPPER));
        _addLiquidity(tokenIndex, key);
        _emitLaunched(tokenIndex, canvasShareBps);

        if (devBuy != 0) {
            uint256 out = abi.decode(poolManager.unlock(abi.encode(uint8(1), key, devBuy, creator)), (uint256));
            if (out < devBuyMinOut) revert SlippageExceeded(out, devBuyMinOut);
            emit DevBuy(tokenIndex, creator, devBuy, out);
        }
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

    function _addLiquidity(uint256 tokenIndex, PoolKey memory key) private {
        uint256 amount = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint128 liquidity = uint128(FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtUpper - sqrtLower));
        uint256 paid = abi.decode(poolManager.unlock(abi.encode(uint8(0), key, uint256(liquidity), address(0))), (uint256));
        emit LiquidityLocked(tokenIndex, liquidity, paid, amount - paid);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, PoolKey memory key, uint256 amount, address recipient) =
            abi.decode(data, (uint8, PoolKey, uint256, address));

        if (action == 0) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
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

