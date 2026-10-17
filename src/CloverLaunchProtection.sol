// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Uniswap v4 periphery routers (Universal Router, V4Router) expose the account that unlocked them.
interface IMsgSender {
    function msgSender() external view returns (address);
}

/// @title CloverLaunchProtection
/// @notice Opening protection of every pool of the CloverHook, kept apart from the fee accounting.
///
/// From the block that creates a pool (`register`):
/// - Opening buy fee: the total buy fee starts at 99 % and decays linearly to the pool's normal rate over 30 s.
///   The token creator and up to 6 wallets fixed at launch pay the normal rate. The hook sends the part above
///   the normal rate to the dedicated `CloverOpeningTaxVault`.
/// - Authenticated buyer: for 300 s, buys are accepted only from the Launchpad (initial buy, buyer = creator) or
///   from an approved router, whose `msgSender()` is the buyer. Each buyer can buy at most 2 % of the supply.
/// - Recipient: for 300 s, every token transfer is reported by the token; any address other than the
///   infrastructure (PoolManager, hook, Launchpad, approved routers) can receive at most 2 % of the supply.
/// Both limits are cumulative over the 300 s, include exempt wallets and the creator, and are never reduced by
/// sending tokens away.
contract CloverLaunchProtection {
    uint256 public constant PIPS = 1_000_000;
    /// @notice Total buy fee at pool creation, decaying linearly to the normal rate over `OPENING_DECAY`.
    uint256 public constant OPENING_FEE_PIPS = 990_000;
    uint256 public constant OPENING_DECAY = 30 seconds;
    uint256 public constant OPENING_LIMIT_PERIOD = 300 seconds;
    /// @notice 2 % of the 1,000,000,000 supply of every CloverToken.
    uint256 public constant OPENING_MAX = 20_000_000 ether;
    uint256 public constant MAX_EXEMPT = 6;

    address public immutable hook;
    address public immutable poolManager;
    address public immutable ROUTER_A;
    address public immutable ROUTER_B;

    struct Launch {
        address token;
        address creator;
        uint40 launchedAt;
    }

    mapping(uint256 tokenIndex => Launch) public launches;
    mapping(address token => uint256) public tokenIndexPlusOne;
    mapping(uint256 tokenIndex => mapping(address wallet => bool)) public exempt;
    mapping(uint256 tokenIndex => mapping(address buyer => uint256)) public bought;
    mapping(uint256 tokenIndex => mapping(address recipient => uint256)) public received;

    event Registered(uint256 indexed tokenIndex, address indexed token, address indexed creator, uint256 launchedAt);
    event Exempt(uint256 indexed tokenIndex, address indexed wallet);

    error NotHook();
    error TooManyExempt();
    error UnauthenticatedBuyer();
    error BuyerLimit();
    error RecipientLimit();

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(address poolManager_, address routerA, address routerB) {
        hook = msg.sender;
        poolManager = poolManager_;
        ROUTER_A = routerA;
        ROUTER_B = routerB;
    }

    // ---------------------------------------------------------------- hook

    function register(uint256 tokenIndex, address token, address creator, address[] calldata wallets) external onlyHook {
        if (wallets.length > MAX_EXEMPT) revert TooManyExempt();
        launches[tokenIndex] = Launch({token: token, creator: creator, launchedAt: uint40(block.timestamp)});
        tokenIndexPlusOne[token] = tokenIndex + 1;
        emit Registered(tokenIndex, token, creator, block.timestamp);
        exempt[tokenIndex][creator] = true;
        emit Exempt(tokenIndex, creator);
        for (uint256 i; i < wallets.length; ++i) {
            exempt[tokenIndex][wallets[i]] = true;
            emit Exempt(tokenIndex, wallets[i]);
        }
    }

    /// @notice Counts a buy against its authenticated buyer during the first 300 s.
    function recordBuy(uint256 tokenIndex, address sender, uint256 tokensOut) external onlyHook {
        if (!limitActive(tokenIndex)) return;
        address buyer = buyerOf(tokenIndex, sender);
        uint256 total = bought[tokenIndex][buyer] + tokensOut;
        if (total > OPENING_MAX) revert BuyerLimit();
        bought[tokenIndex][buyer] = total;
    }

    // ---------------------------------------------------------------- token

    /// @notice Called by a protected token on every transfer during its first 300 s.
    function recordTransfer(address to, uint256 amount) external {
        uint256 indexPlusOne = tokenIndexPlusOne[msg.sender];
        if (indexPlusOne == 0) return;
        uint256 tokenIndex = indexPlusOne - 1;
        if (!limitActive(tokenIndex) || isInfrastructure(to)) return;
        uint256 total = received[tokenIndex][to] + amount;
        if (total > OPENING_MAX) revert RecipientLimit();
        received[tokenIndex][to] = total;
    }

    // ---------------------------------------------------------------- views

    function limitActive(uint256 tokenIndex) public view returns (bool) {
        return block.timestamp < uint256(launches[tokenIndex].launchedAt) + OPENING_LIMIT_PERIOD;
    }

    function protectionEnds(uint256 tokenIndex) external view returns (uint256) {
        return uint256(launches[tokenIndex].launchedAt) + OPENING_LIMIT_PERIOD;
    }

    function isApprovedRouter(address a) public view returns (bool) {
        return a == ROUTER_A || a == ROUTER_B;
    }

    /// @notice Addresses that only hold tokens in transit and are not counted as recipients.
    function isInfrastructure(address a) public view returns (bool) {
        return a == poolManager || a == hook || a == ICloverHookLaunchpad(hook).launchpad() || isApprovedRouter(a);
    }

    /// @notice Authenticated buyer of a swap sent by `sender`: the creator for the Launchpad initial buy, the
    ///         `msgSender()` of an approved router. Reverts for any other sender while the limit is active.
    function buyerOf(uint256 tokenIndex, address sender) public view returns (address buyer) {
        if (sender == ICloverHookLaunchpad(hook).launchpad()) return launches[tokenIndex].creator;
        if (isApprovedRouter(sender)) buyer = IMsgSender(sender).msgSender();
        if (buyer == address(0)) revert UnauthenticatedBuyer();
    }

    /// @notice Total buy fee rate (pips) for a buy sent by `sender`, given the pool's normal rate.
    function buyRatePips(uint256 tokenIndex, address sender, uint256 normalRate) external view returns (uint256) {
        if (block.timestamp - launches[tokenIndex].launchedAt >= OPENING_DECAY) return normalRate;
        return ratePipsFor(tokenIndex, buyerOf(tokenIndex, sender), normalRate);
    }

    /// @notice Total buy fee rate (pips) for `buyer` now: 99 % at creation decaying linearly to `normalRate`
    ///         over 30 s; `normalRate` for exempt wallets.
    function ratePipsFor(uint256 tokenIndex, address buyer, uint256 normalRate) public view returns (uint256 rate) {
        rate = normalRate;
        uint256 elapsed = block.timestamp - launches[tokenIndex].launchedAt;
        if (elapsed >= OPENING_DECAY || exempt[tokenIndex][buyer]) return rate;
        uint256 opening = OPENING_FEE_PIPS - (OPENING_FEE_PIPS - normalRate) * elapsed / OPENING_DECAY;
        if (opening > rate) rate = opening;
    }
}

interface ICloverHookLaunchpad {
    function launchpad() external view returns (address);
}
