// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {CloverHook} from "../../src/CloverHook.sol";
import {CloverCanvas} from "../../src/CloverCanvas.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {CloverToken} from "../../src/CloverToken.sol";
import {TestSwapRouter} from "./TestSwapRouter.sol";

abstract contract Base is Test {
    uint160 internal constant HOOK_FLAGS = 0x28CC;

    IPoolManager internal manager;
    CloverHook internal hook;
    CloverCanvas internal canvas;
    Launchpad internal launchpad;
    CloverToken internal clover;
    TestSwapRouter internal router;
    PoolKey internal cloverKey;

    address internal platform = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address internal protocol = makeAddr("protocol");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    uint256 internal genesisAt;

    uint16 internal constant GENESIS_FEE_BPS = 500;
    uint8 internal constant GENESIS_SIZE = 12;
    uint16 internal constant GENESIS_RENT_BPS = 500;
    uint32 internal constant GENESIS_FADE = 3 days;
    uint96 internal constant GENESIS_START = 0.001 ether;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        // Mainnet PoolManager holds native ETH from other pools; hooks `take` before the trader settles.
        vm.deal(address(manager), 10_000 ether);

        // CREATE2 salt mining (not etching): the hook's constructor creates its fee vault with kernel = hook.
        bytes32 initHash = keccak256(abi.encodePacked(type(CloverHook).creationCode, abi.encode(manager, platform)));
        uint256 salt;
        while (
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initHash))))
                & 0x3FFF != HOOK_FLAGS
        ) ++salt;
        hook = new CloverHook{salt: bytes32(salt)}(manager, platform);

        canvas = new CloverCanvas(protocol);
        address[] memory exempt = new address[](1);
        exempt[0] = bob;
        launchpad = new Launchpad(
            manager,
            hook,
            canvas,
            creator,
            GENESIS_FEE_BPS,
            10_000,
            GENESIS_SIZE,
            GENESIS_RENT_BPS,
            GENESIS_FADE,
            GENESIS_START,
            exempt
        );
        clover = new CloverToken("CLOVER", "CLOVER", address(launchpad));

        hook.initialize(address(launchpad), canvas);
        canvas.initialize(address(launchpad), address(hook));
        launchpad.genesis{value: 0.1 ether}(clover);
        genesisAt = block.timestamp;

        cloverKey = launchpad.poolKeyOf(address(clover));
        router = new TestSwapRouter(manager);

        for (uint256 i; i < 4; ++i) {
            address u = [creator, alice, bob, carol][i];
            vm.deal(u, 1_000 ether);
            vm.prank(u);
            clover.approve(address(router), type(uint256).max);
        }
        // Most tests trade after the opening protection; OpeningProtection tests warp back.
        vm.warp(genesisAt + hook.OPENING_LIMIT_PERIOD());
    }

    // ---------------------------------------------------------------- helpers

    function buyExactIn(address who, PoolKey memory key, uint256 ethIn) internal returns (BalanceDelta d) {
        vm.prank(who);
        d = router.swap{value: ethIn}(key, true, -int256(ethIn));
    }

    function sellExactIn(address who, PoolKey memory key, uint256 tokensIn) internal returns (BalanceDelta d) {
        vm.prank(who);
        d = router.swap(key, false, -int256(tokensIn));
    }

    function pid(uint256 canvasId, uint256 index) internal pure returns (uint256) {
        return canvasId << 16 | index;
    }

    /// @dev Captures at the current price with `daysOfRent` days of deposit at `newPrice`.
    function capture(address who, uint256 id, uint96 newPrice, uint256 daysOfRent) internal {
        CloverCanvas.PixelView memory v = canvas.pixel(id);
        CloverCanvas.Canvas memory c = canvas.canvas(id >> 16);
        uint256 dep = uint256(newPrice) * c.rentBps / 10_000 / 7 * daysOfRent + 1;
        vm.prank(who);
        canvas.capture{value: v.price + dep}(id, v.price, newPrice, 0x22aa44);
    }

    function launchChild(address who, uint16 feeBps, uint16 shareBps, uint256 devBuy)
        internal
        returns (uint256 idx, address token, uint256 canvasId, PoolKey memory key)
    {
        (idx, token, canvasId, key) = launchChildAt(who, feeBps, shareBps, devBuy, new address[](0));
        vm.warp(block.timestamp + hook.OPENING_LIMIT_PERIOD());
    }

    /// @dev Launches without skipping the opening protection.
    function launchChildAt(address who, uint16 feeBps, uint16 shareBps, uint256 devBuy, address[] memory exempt)
        internal
        returns (uint256 idx, address token, uint256 canvasId, PoolKey memory key)
    {
        Launchpad.LaunchParams memory p = Launchpad.LaunchParams({
            name: "Child",
            symbol: "CHLD",
            tokenFeeBps: feeBps,
            canvasShareBps: shareBps,
            canvasName: "Child board",
            size: 7,
            rentBps: 500,
            fadeTime: 1 days,
            startPrice: 0.002 ether,
            devBuyMinOut: 0,
            exemptWallets: exempt
        });
        uint256 value = launchpad.LAUNCH_FEE() + devBuy;
        vm.prank(who);
        (idx, token, canvasId) = launchpad.launchWithCanvas{value: value}(p);
        key = launchpad.poolKeyOf(token);
        for (uint256 i; i < 4; ++i) {
            address u = [creator, alice, bob, carol][i];
            vm.prank(u);
            CloverToken(token).approve(address(router), type(uint256).max);
        }
    }

    /// @dev ETH held by the canvas contract must cover everything owed plus every live deposit and
    ///      every held pixel's unclaimed rewards.
    function liveDeposits(uint256 canvasId) internal view returns (uint256 sum) {
        CloverCanvas.PixelView[] memory all = canvas.pixels(canvasId);
        for (uint256 i; i < all.length; ++i) {
            if (all[i].state == 1) sum += all[i].deposit + all[i].pendingRewards;
        }
    }
}
