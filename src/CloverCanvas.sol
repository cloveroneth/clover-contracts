// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title CloverCanvas
/// @notice Canvases of contestable pixels (see CANVAS_SPEC.md). Every pixel is an ERC-721 that exists only
///         while it is HELD: `id = canvasId << 16 | index`.
///
/// Money flows (ETH only, all payouts are pull payments through `owed`):
/// - First sale of an OPEN pixel at the start price: 95 % creator, 5 % protocol.
/// - Capture of a HELD pixel at its price: 90 % seller (plus their unused deposit), 5 % creator, 5 % protocol.
/// - Reclaim of a FADED pixel at its fading price: 90 % previous holder after a release; after a
///   forfeiture 80 % previous holder and 10 % into the canvas rewards. 5 % creator, 5 % protocol.
/// - Rent from the deposit: 80 % creator, 20 % protocol.
/// - Rewards (`fund`): split equally per pixel. The share of the pixels that are not held at funding time
///   goes to the creator; the rest goes to the held pixels through a per-canvas accumulator.
///
/// Rent and forfeiture are settled lazily (`poke`). A pixel whose deposit ran out keeps earning rewards
/// until it is poked; anyone can poke.
contract CloverCanvas is ERC721, ReentrancyGuard {
    // ---------------------------------------------------------------- constants

    uint256 public constant BPS = 10_000;
    uint256 public constant PROTOCOL_BPS = 500;
    uint256 public constant CREATOR_BPS = 500;
    uint256 public constant FIRST_SALE_CREATOR_BPS = 9_500;
    uint256 public constant RENT_CREATOR_BPS = 8_000;
    uint256 public constant PENALTY_BPS = 1_000;
    uint256 public constant COOLDOWN = 15 minutes;
    uint256 public constant WEEK = 7 days;
    uint256 public constant ACC = 1e18;
    uint256 public constant MAX_PRICE = 1e24;
    uint16 public constant MIN_RENT_BPS = 100;
    uint16 public constant MAX_RENT_BPS = 1_000;
    uint256 public constant CREATE_FEE = 0.01 ether;
    uint256 public constant GENESIS_ID = 0;

    uint8 internal constant OPEN = 0;
    uint8 internal constant HELD = 1;
    uint8 internal constant FADED = 2;

    // ---------------------------------------------------------------- immutables

    address public immutable DEPLOYER;
    address public immutable PROTOCOL;

    // ---------------------------------------------------------------- wiring (set once)

    address public launchpad;
    address public hook;

    // ---------------------------------------------------------------- state

    struct Canvas {
        address creator;
        uint8 size;
        uint16 rentBps;
        uint32 fadeTime;
        uint96 startPrice;
        uint16 heldCount;
        uint64 createdAt;
        uint256 accPerPixel;
        uint256 remainder;
        uint256 totalFunded;
    }

    struct Pixel {
        uint8 state;
        bool forfeited;
        uint24 color;
        uint96 price;
        uint96 deposit;
        uint64 lastSettled;
        uint64 capturedAt;
        address prevHolder;
        uint96 fadeFrom;
        uint64 fadeStart;
        uint256 rewardDebt;
    }

    Canvas[] internal _canvases;
    mapping(uint256 id => Pixel) internal _pixels;
    mapping(address => uint256) public owed;
    mapping(address => string) public profileOf;

    uint256 public totalOwed;

    // ---------------------------------------------------------------- events

    event Initialized(address launchpad, address hook);
    event CanvasCreated(
        uint256 indexed canvasId,
        address indexed creator,
        string name,
        uint8 size,
        uint16 rentBps,
        uint32 fadeTime,
        uint96 startPrice,
        address token
    );
    event Captured(
        uint256 indexed id,
        address indexed buyer,
        address indexed seller,
        uint8 fromState,
        uint256 paid,
        uint96 newPrice,
        uint96 deposit,
        uint24 color
    );
    event PriceSet(uint256 indexed id, uint96 price);
    event DepositChanged(uint256 indexed id, uint96 deposit);
    event ColorSet(uint256 indexed id, uint24 color);
    event Released(uint256 indexed id, address indexed holder);
    event Forfeited(uint256 indexed id, address indexed holder, uint64 at);
    event Reopened(uint256 indexed id);
    event RentPaid(uint256 indexed id, uint256 amount);
    event Funded(uint256 indexed canvasId, address indexed from, uint256 amount, uint256 toHolders, uint256 toCreator);
    event RewardsPaid(uint256 indexed id, address indexed holder, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event ProfileSet(address indexed account, string handle);

    // ---------------------------------------------------------------- errors

    error NotDeployer();
    error AlreadyInitialized();
    error NotLaunchpad();
    error ZeroAddress();
    error InvalidParams();
    error InvalidPixel();
    error NotHolder();
    error Cooldown();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error InsufficientDeposit(uint256 required);
    error InsufficientValue();
    error AlreadyHolder();
    error TransferFailed();
    error InvalidHandle();

    constructor(address protocol_) ERC721("CLOVER Pixel", "PIXEL") {
        if (protocol_ == address(0)) revert ZeroAddress();
        DEPLOYER = msg.sender;
        PROTOCOL = protocol_;
    }

    /// @notice One-time wiring, called by the deployer (the Programmable Graph Factory).
    function initialize(address launchpad_, address hook_) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (launchpad != address(0)) revert AlreadyInitialized();
        if (launchpad_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        hook = hook_;
        emit Initialized(launchpad_, hook_);
    }

    // ---------------------------------------------------------------- canvases

    /// @notice Creates a canvas for a token launched by the Launchpad (the Genesis canvas included).
    function createCanvasFor(
        address creator,
        string calldata name,
        uint8 size,
        uint16 rentBps,
        uint32 fadeTime,
        uint96 startPrice,
        address token
    ) external returns (uint256) {
        if (msg.sender != launchpad) revert NotLaunchpad();
        return _createCanvas(creator, name, size, rentBps, fadeTime, startPrice, token);
    }

    /// @notice Creates a canvas with a custom revenue source (anyone can `fund` it).
    ///         `CREATE_FEE` goes to the Genesis canvas rewards.
    function createCanvas(string calldata name, uint8 size, uint16 rentBps, uint32 fadeTime, uint96 startPrice)
        external
        payable
        nonReentrant
        returns (uint256 canvasId)
    {
        if (_canvases.length == 0) revert InvalidParams();
        if (msg.value != CREATE_FEE) revert InsufficientValue();
        canvasId = _createCanvas(msg.sender, name, size, rentBps, fadeTime, startPrice, address(0));
        _fund(GENESIS_ID, msg.value);
    }

    function _createCanvas(
        address creator,
        string calldata name,
        uint8 size,
        uint16 rentBps,
        uint32 fadeTime,
        uint96 startPrice,
        address token
    ) private returns (uint256 canvasId) {
        uint256 nameLen = bytes(name).length;
        if (
            creator == address(0) || (size != 7 && size != 10 && size != 12) || rentBps < MIN_RENT_BPS
                || rentBps > MAX_RENT_BPS || (fadeTime != 1 days && fadeTime != 3 days && fadeTime != 7 days)
                || startPrice == 0 || startPrice > MAX_PRICE || nameLen == 0 || nameLen > 48
        ) revert InvalidParams();
        canvasId = _canvases.length;
        _canvases.push(
            Canvas({
                creator: creator,
                size: size,
                rentBps: rentBps,
                fadeTime: fadeTime,
                startPrice: startPrice,
                heldCount: 0,
                createdAt: uint64(block.timestamp),
                accPerPixel: 0,
                remainder: 0,
                totalFunded: 0
            })
        );
        emit CanvasCreated(canvasId, creator, name, size, rentBps, fadeTime, startPrice, token);
    }

    // ---------------------------------------------------------------- rewards in

    /// @notice Adds ETH to a canvas's rewards. Used by the hook (token fees) and by anyone (custom source).
    function fund(uint256 canvasId) external payable nonReentrant {
        if (canvasId >= _canvases.length) revert InvalidParams();
        _fund(canvasId, msg.value);
    }

    function _fund(uint256 canvasId, uint256 amount) private {
        if (amount == 0) return;
        Canvas storage c = _canvases[canvasId];
        uint256 count = uint256(c.size) * c.size;
        uint256 held = c.heldCount;
        uint256 toCreator = amount * (count - held) / count;
        uint256 toHolders = amount - toCreator;
        if (held == 0) {
            toCreator = amount;
            toHolders = 0;
        } else {
            uint256 scaled = toHolders * ACC + c.remainder;
            c.accPerPixel += scaled / held;
            c.remainder = scaled % held;
        }
        c.totalFunded += amount;
        _credit(c.creator, toCreator);
        emit Funded(canvasId, msg.sender, amount, toHolders, toCreator);
    }

    // ---------------------------------------------------------------- capture

    /// @notice Captures pixel `id`. `msg.value` = current price + deposit (at least one day of rent at
    ///         `newPrice`). `maxPrice` protects against a price change between quote and inclusion.
    function capture(uint256 id, uint256 maxPrice, uint96 newPrice, uint24 color) external payable nonReentrant {
        (uint256 canvasId, Canvas storage c) = _canvasOf(id);
        Pixel storage p = _pixels[id];
        _sync(id, c, p);
        if (newPrice == 0 || newPrice > MAX_PRICE) revert InvalidParams();

        uint256 price = _currentPrice(c, p);
        if (price > maxPrice) revert PriceAboveMax(price, maxPrice);
        if (msg.value < price) revert InsufficientValue();
        uint96 deposit = _checkDeposit(msg.value - price, newPrice, c.rentBps);

        uint8 fromState = p.state;
        address seller = _settleSale(id, canvasId, c, p, price);
        _setHeld(p, c.accPerPixel, newPrice, deposit, color);
        emit Captured(id, msg.sender, seller, fromState, price, newPrice, deposit, color);
    }

    function _checkDeposit(uint256 deposit, uint256 newPrice, uint16 rentBps) private pure returns (uint96) {
        uint256 minDeposit = _dayRent(newPrice, rentBps);
        if (deposit < minDeposit) revert InsufficientDeposit(minDeposit);
        if (deposit > type(uint96).max) revert InvalidParams();
        return uint96(deposit);
    }

    function _setHeld(Pixel storage p, uint256 acc, uint96 newPrice, uint96 deposit, uint24 color) private {
        p.state = HELD;
        p.forfeited = false;
        p.color = color;
        p.price = newPrice;
        p.deposit = deposit;
        p.lastSettled = uint64(block.timestamp);
        p.capturedAt = uint64(block.timestamp);
        p.prevHolder = address(0);
        p.fadeFrom = 0;
        p.fadeStart = 0;
        p.rewardDebt = acc;
    }

    /// @dev Splits the sale price, pays the seller and hands the pixel to the caller. Returns the seller.
    function _settleSale(uint256 id, uint256 canvasId, Canvas storage c, Pixel storage p, uint256 price)
        private
        returns (address seller)
    {
        uint256 protocolCut = price * PROTOCOL_BPS / BPS;
        uint256 creatorCut = price * CREATOR_BPS / BPS;
        _credit(PROTOCOL, protocolCut);
        if (p.state == HELD) {
            seller = ownerOf(id);
            if (seller == msg.sender) revert AlreadyHolder();
            if (block.timestamp < p.capturedAt + COOLDOWN) revert Cooldown();
            _payRewards(id, c, p, seller);
            _credit(seller, price - protocolCut - creatorCut + p.deposit);
            _credit(c.creator, creatorCut);
            _transfer(seller, msg.sender, id);
            return seller;
        }
        if (p.state == OPEN) {
            _credit(c.creator, price - protocolCut);
        } else {
            // FADED: the previous holder is paid, with a penalty into the rewards after a forfeiture.
            seller = p.prevHolder;
            uint256 penalty = p.forfeited ? price * PENALTY_BPS / BPS : 0;
            _credit(seller, price - protocolCut - creatorCut - penalty);
            _credit(c.creator, creatorCut);
            _fund(canvasId, penalty);
        }
        c.heldCount += 1;
        _mint(msg.sender, id);
    }

    // ---------------------------------------------------------------- holder actions

    function setPrice(uint256 id, uint96 newPrice) external nonReentrant {
        (Canvas storage c, Pixel storage p) = _held(id);
        if (newPrice == 0 || newPrice > MAX_PRICE) revert InvalidParams();
        if (p.deposit < _dayRent(newPrice, c.rentBps)) revert InsufficientDeposit(_dayRent(newPrice, c.rentBps));
        p.price = newPrice;
        emit PriceSet(id, newPrice);
    }

    function addDeposit(uint256 id) external payable nonReentrant {
        (, Pixel storage p) = _held(id);
        uint256 d = uint256(p.deposit) + msg.value;
        if (d > type(uint96).max) revert InvalidParams();
        p.deposit = uint96(d);
        emit DepositChanged(id, uint96(d));
    }

    /// @notice Withdraws part of the deposit, keeping at least one day of rent.
    function withdrawDeposit(uint256 id, uint96 amount) external nonReentrant {
        (Canvas storage c, Pixel storage p) = _held(id);
        uint256 minDeposit = _dayRent(p.price, c.rentBps);
        if (amount > p.deposit || p.deposit - amount < minDeposit) revert InsufficientDeposit(minDeposit);
        p.deposit -= amount;
        _credit(msg.sender, amount);
        emit DepositChanged(id, p.deposit);
    }

    function setColor(uint256 id, uint24 color) external nonReentrant {
        (, Pixel storage p) = _held(id);
        p.color = color;
        emit ColorSet(id, color);
    }

    /// @notice Gives the pixel up: deposit and rewards are paid, the price starts fading.
    function release(uint256 id) external nonReentrant {
        (Canvas storage c, Pixel storage p) = _held(id);
        _payRewards(id, c, p, msg.sender);
        _credit(msg.sender, p.deposit);
        _toFaded(id, c, p, msg.sender, false, uint64(block.timestamp));
        emit Released(id, msg.sender);
    }

    /// @notice Pays the pending rewards of the caller's pixels.
    function claim(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; ++i) {
            (Canvas storage c, Pixel storage p) = _held(ids[i]);
            _payRewards(ids[i], c, p, msg.sender);
        }
    }

    /// @notice Settles rent, forfeitures and finished fades. Anyone can call it.
    function poke(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; ++i) {
            (, Canvas storage c) = _canvasOf(ids[i]);
            _sync(ids[i], c, _pixels[ids[i]]);
        }
    }

    /// @notice Pays the pending rewards of the caller's pixels `ids`, then sends everything owed to the caller.
    function collect(uint256[] calldata ids) external nonReentrant returns (uint256) {
        for (uint256 i; i < ids.length; ++i) {
            (Canvas storage c, Pixel storage p) = _held(ids[i]);
            _payRewards(ids[i], c, p, msg.sender);
        }
        return _withdraw();
    }

    /// @notice Sends everything owed to the caller (sales, refunds, rewards, rent, creator shares).
    function withdraw() external nonReentrant returns (uint256) {
        return _withdraw();
    }

    function _withdraw() private returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) return 0;
        owed[msg.sender] = 0;
        totalOwed -= amount;
        emit Withdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Links an X handle to the caller (unverified on-chain; the app verifies it off-chain).
    function setProfile(string calldata handle) external {
        bytes memory b = bytes(handle);
        if (b.length > 15) revert InvalidHandle();
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            bool ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_";
            if (!ok) revert InvalidHandle();
        }
        profileOf[msg.sender] = handle;
        emit ProfileSet(msg.sender, handle);
    }

    // ---------------------------------------------------------------- views

    function canvasCount() external view returns (uint256) {
        return _canvases.length;
    }

    function canvas(uint256 canvasId) external view returns (Canvas memory) {
        return _canvases[canvasId];
    }

    struct PixelView {
        uint8 state;
        address holder;
        uint256 price;
        uint96 deposit;
        uint24 color;
        uint64 capturedAt;
        uint64 paidUntil;
        uint256 pendingRewards;
        address prevHolder;
        bool forfeited;
    }

    /// @notice Pixel state as of now, with lazy rent, forfeiture and fade applied.
    function pixel(uint256 id) public view returns (PixelView memory v) {
        uint256 canvasId = id >> 16;
        uint256 index = id & 0xffff;
        if (canvasId >= _canvases.length) revert InvalidPixel();
        Canvas memory c = _canvases[canvasId];
        if (index >= uint256(c.size) * c.size) revert InvalidPixel();
        Pixel memory p = _pixels[id];
        v.color = p.color;
        if (p.state == HELD) {
            uint256 rent = _rentDue(c.rentBps, p.price, p.lastSettled, block.timestamp);
            if (rent < p.deposit) {
                v.state = HELD;
                v.holder = _ownerOf(id);
                v.price = p.price;
                v.deposit = uint96(p.deposit - rent);
                v.capturedAt = p.capturedAt;
                v.paidUntil = _paidUntil(c.rentBps, p);
                v.pendingRewards = (c.accPerPixel - p.rewardDebt) / ACC;
                return v;
            }
            p.state = FADED;
            p.forfeited = true;
            p.prevHolder = _ownerOf(id);
            p.fadeFrom = p.price;
            p.fadeStart = _paidUntil(c.rentBps, p);
        }
        if (p.state == FADED && block.timestamp < uint256(p.fadeStart) + c.fadeTime) {
            v.state = FADED;
            v.prevHolder = p.prevHolder;
            v.forfeited = p.forfeited;
            v.price = _fadingPrice(c, p);
            return v;
        }
        v.state = OPEN;
        v.price = c.startPrice;
    }

    function pixels(uint256 canvasId) external view returns (PixelView[] memory out) {
        Canvas memory c = _canvases[canvasId];
        uint256 n = uint256(c.size) * c.size;
        out = new PixelView[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = pixel(canvasId << 16 | i);
        }
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return string.concat("https://cloverpixel.xyz/api/pixel/", Strings.toString(id));
    }

    // ---------------------------------------------------------------- internals

    function _canvasOf(uint256 id) private view returns (uint256 canvasId, Canvas storage c) {
        canvasId = id >> 16;
        if (canvasId >= _canvases.length) revert InvalidPixel();
        c = _canvases[canvasId];
        if ((id & 0xffff) >= uint256(c.size) * c.size) revert InvalidPixel();
    }

    /// @dev Syncs the pixel and checks that the caller holds it.
    function _held(uint256 id) private returns (Canvas storage c, Pixel storage p) {
        (, c) = _canvasOf(id);
        p = _pixels[id];
        _sync(id, c, p);
        if (p.state != HELD || ownerOf(id) != msg.sender) revert NotHolder();
    }

    function _sync(uint256 id, Canvas storage c, Pixel storage p) private {
        if (p.state == HELD) {
            uint256 rent = _rentDue(c.rentBps, p.price, p.lastSettled, block.timestamp);
            if (rent < p.deposit) {
                p.deposit -= uint96(rent);
                p.lastSettled = uint64(block.timestamp);
                _payRent(id, c, rent);
                return;
            }
            uint64 at = _paidUntil(c.rentBps, p);
            uint256 all = p.deposit;
            p.deposit = 0;
            _payRent(id, c, all);
            address holder = ownerOf(id);
            _payRewards(id, c, p, holder);
            _toFaded(id, c, p, holder, true, at);
            emit Forfeited(id, holder, at);
        }
        if (p.state == FADED && block.timestamp >= uint256(p.fadeStart) + c.fadeTime) {
            p.state = OPEN;
            p.forfeited = false;
            p.prevHolder = address(0);
            p.fadeFrom = 0;
            p.fadeStart = 0;
            emit Reopened(id);
        }
    }

    function _toFaded(uint256 id, Canvas storage c, Pixel storage p, address holder, bool forfeited, uint64 at)
        private
    {
        p.state = FADED;
        p.forfeited = forfeited;
        p.prevHolder = holder;
        p.fadeFrom = p.price;
        p.fadeStart = at;
        p.deposit = 0;
        c.heldCount -= 1;
        _burn(id);
    }

    function _payRent(uint256 id, Canvas storage c, uint256 rent) private {
        if (rent == 0) return;
        uint256 toCreator = rent * RENT_CREATOR_BPS / BPS;
        _credit(c.creator, toCreator);
        _credit(PROTOCOL, rent - toCreator);
        emit RentPaid(id, rent);
    }

    function _payRewards(uint256 id, Canvas storage c, Pixel storage p, address holder) private {
        uint256 acc = c.accPerPixel;
        uint256 amount = (acc - p.rewardDebt) / ACC;
        p.rewardDebt = acc;
        if (amount == 0) return;
        _credit(holder, amount);
        emit RewardsPaid(id, holder, amount);
    }

    function _credit(address to, uint256 amount) private {
        if (amount == 0) return;
        owed[to] += amount;
        totalOwed += amount;
    }

    function _currentPrice(Canvas storage c, Pixel storage p) private view returns (uint256) {
        if (p.state == HELD) return p.price;
        if (p.state == FADED) return _fadingPrice(c, p);
        return c.startPrice;
    }

    function _fadingPrice(Canvas memory c, Pixel memory p) private view returns (uint256) {
        uint256 elapsed = block.timestamp - p.fadeStart;
        if (elapsed >= c.fadeTime) return 0;
        return uint256(p.fadeFrom) * (c.fadeTime - elapsed) / c.fadeTime;
    }

    function _dayRent(uint256 price, uint16 rentBps) private pure returns (uint256) {
        return price * rentBps / BPS / 7;
    }

    function _rentDue(uint16 rentBps, uint256 price, uint64 from, uint256 to) private pure returns (uint256) {
        return price * rentBps * (to - from) / (BPS * WEEK);
    }

    /// @dev Timestamp at which the deposit runs out at the current price.
    function _paidUntil(uint16 rentBps, Pixel memory p) private pure returns (uint64) {
        uint256 perWeek = uint256(p.price) * rentBps;
        uint256 secs = uint256(p.deposit) * BPS * WEEK / perWeek;
        uint256 t = uint256(p.lastSettled) + secs;
        return t > type(uint64).max ? type(uint64).max : uint64(t);
    }

    /// @dev Transfers by holders (not captures) hand the pixel over with its deposit; the sender's pending
    ///      rewards are paid first so they do not move with the token.
    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = _ownerOf(id);
        if (auth != address(0) && from != address(0) && to != address(0)) {
            (, Canvas storage c) = _canvasOf(id);
            Pixel storage p = _pixels[id];
            _sync(id, c, p);
            if (p.state != HELD) revert NotHolder();
            _payRewards(id, c, p, from);
        }
        return super._update(to, id, auth);
    }
}
