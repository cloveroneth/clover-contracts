// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./utils/Base.t.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {MockEthUsdFeed} from "./utils/MockEthUsdFeed.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {CloverHook} from "../src/CloverHook.sol";
import {CloverToken} from "../src/CloverToken.sol";
import {CloverLaunchProtection} from "../src/CloverLaunchProtection.sol";
import {CloverOpeningTaxVault} from "../src/CloverOpeningTaxVault.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Opening protection scenarios: starting FDV from the oracle, opening tax and its vault, exemptions,
///         authenticated buyer, buyer and recipient caps.
contract OpeningProtectionTest is Base {
    using PoolIdLibrary for PoolKey;

    MockEthUsdFeed internal feed = MockEthUsdFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    address internal dave = makeAddr("dave");

    struct Fees {
        uint256 gross;
        uint256 platform;
        uint256 tokenFee;
        uint256 openingTax;
    }

    function _protection() internal view returns (CloverLaunchProtection) {
        return hook.protection();
    }

    function _vault() internal view returns (CloverOpeningTaxVault) {
        return hook.openingTaxVault();
    }

    function _params(address[] memory ex) internal pure returns (Launchpad.LaunchParams memory) {
        return Launchpad.LaunchParams({
            name: "Child",
            symbol: "CHLD",
            tokenFeeBps: 300,
            canvasShareBps: 5_000,
            canvasName: "Child board",
            size: 7,
            rentBps: 500,
            fadeTime: 1 days,
            startPrice: 0.002 ether,
            devBuyMinOut: 0,
            exemptWallets: ex
        });
    }

    function _launch(address[] memory ex) internal returns (PoolKey memory key, CloverToken token) {
        address t;
        (, t,, key) = launchChildAt(alice, 300, 5_000, 0, ex);
        token = CloverToken(t);
        vm.deal(dave, 10 ether);
    }

    function _buy(address who, PoolKey memory key, int256 amountSpecified, uint256 value) internal returns (Fees memory f) {
        vm.recordLogs();
        vm.prank(who, who);
        router.swap{value: value}(key, true, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeTopic = keccak256("FeeTaken(bytes32,address,bool,uint256,uint256,uint256)");
        bytes32 taxTopic = keccak256("OpeningTaxTaken(bytes32,address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == feeTopic) {
                (, f.gross, f.platform, f.tokenFee) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            } else if (logs[i].topics[0] == taxTopic) {
                (, f.openingTax) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    // ---------------------------------------------------------------- 1-3. opening tax and decay

    function test_OpeningTaxAtCreation() public {
        (PoolKey memory key,) = _launch(new address[](0));
        uint256 creatorOwed0 = hook.creatorOwed(alice);
        uint256 canvas0 = hook.canvasPending(1);
        Fees memory f = _buy(carol, key, -0.01 ether, 0.01 ether);
        assertEq(f.gross, 0.01 ether);
        assertEq(f.platform, 0.00003 ether, "platform ceil 30 bps");
        assertEq(f.tokenFee, 0.0003 ether, "normal token fee only");
        assertEq(f.openingTax, 0.01 ether * (990_000 - 33_000) / 1_000_000, "99 % total");
        // Separate custody: the opening tax is in the vault, not in the creator / canvas balances.
        assertEq(_vault().accrued(1), f.openingTax);
        assertEq(address(_vault()).balance, _vault().totalAccrued());
        assertEq(hook.creatorOwed(alice) - creatorOwed0 + hook.canvasPending(1) - canvas0, f.tokenFee);
        assertEq(hook.buyFeePips(key.toId(), carol), 990_000);
    }

    function test_OpeningTaxDecay() public {
        (PoolKey memory key,) = _launch(new address[](0));
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 15);
        Fees memory f = _buy(carol, key, -0.01 ether, 0.01 ether);
        uint256 rate = 990_000 - (990_000 - 33_000) * 15 / 30;
        assertEq(f.openingTax, 0.01 ether * (rate - 33_000) / 1_000_000);
        assertEq(f.platform, 0.00003 ether);
        vm.warp(t0 + 30);
        f = _buy(carol, key, -0.01 ether, 0.01 ether);
        assertEq(f.openingTax, 0, "normal from 30 s");
        assertEq(f.tokenFee, 0.0003 ether);
        assertEq(hook.buyFeePips(key.toId(), carol), 33_000);
    }

    function test_OpeningTaxExactOutBuy() public {
        (PoolKey memory key,) = _launch(new address[](0));
        Fees memory f = _buy(carol, key, 1_000 ether, 1 ether);
        assertEq(f.platform, (f.gross * 30 + 9_999) / 10_000);
        assertEq(f.tokenFee, f.gross * 30_000 / 1_000_000);
        assertEq(f.openingTax, f.gross * 957_000 / 1_000_000);
    }

    function test_SellsPayNormalRateDuringOpening() public {
        address[] memory ex = new address[](1);
        ex[0] = carol;
        (PoolKey memory key, CloverToken token) = _launch(ex);
        _buy(carol, key, -0.01 ether, 0.01 ether);
        uint256 bag = token.balanceOf(carol);
        vm.recordLogs();
        vm.prank(carol, carol);
        router.swap(key, false, -int256(bag));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeTopic = keccak256("FeeTaken(bytes32,address,bool,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != feeTopic) continue;
            (, uint256 gross,, uint256 tokenFee) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            assertEq(tokenFee, gross * 30_000 / 1_000_000);
        }
        assertEq(_vault().accrued(1), 0);
    }

    // ---------------------------------------------------------------- 4-5. exemptions

    function test_ExemptWalletsAndCreator() public {
        address[] memory ex = new address[](6);
        for (uint256 i; i < 6; ++i) ex[i] = makeAddr(string.concat("ex", vm.toString(i)));
        (PoolKey memory key,) = _launch(ex);
        for (uint256 i; i < 6; ++i) {
            assertTrue(_protection().exempt(1, ex[i]));
            vm.deal(ex[i], 1 ether);
            Fees memory f = _buy(ex[i], key, -0.01 ether, 0.01 ether);
            assertEq(f.openingTax, 0, "exempt");
            assertEq(f.tokenFee, 0.0003 ether);
        }
        assertEq(_buy(alice, key, -0.01 ether, 0.01 ether).openingTax, 0, "creator exempt");
        assertGt(_buy(carol, key, -0.01 ether, 0.01 ether).openingTax, 0, "not exempt");
        // Per token: the child's wallets are not exempt on $CLOVER, and fixed at launch.
        assertFalse(_protection().exempt(0, ex[0]));
        assertTrue(_protection().exempt(0, bob));
        assertTrue(_protection().exempt(0, creator));
    }

    function test_TooManyExempt() public {
        address[] memory ex = new address[](7);
        for (uint256 i; i < 7; ++i) ex[i] = makeAddr(string.concat("ex", vm.toString(i)));
        Launchpad.LaunchParams memory p = _params(ex);
        vm.prank(alice);
        vm.expectRevert(CloverLaunchProtection.TooManyExempt.selector);
        launchpad.launchWithCanvas{value: 0.01 ether}(p);
    }

    // ---------------------------------------------------------------- 6-7. authenticated buyer

    function test_UnapprovedRouterRejectedForBuysDuringProtection() public {
        (PoolKey memory key,) = _launch(new address[](0));
        TestSwapRouter other = new TestSwapRouter(manager);
        vm.prank(carol, carol);
        vm.expectRevert();
        other.swap{value: 0.01 ether}(key, true, -0.01 ether);
        // After 300 s any router can buy.
        vm.warp(block.timestamp + 300);
        vm.prank(carol, carol);
        other.swap{value: 0.01 ether}(key, true, -0.01 ether);
    }

    function test_BuyerIsRouterMsgSenderNotTxOrigin() public {
        (PoolKey memory key,) = _launch(new address[](0));
        vm.warp(block.timestamp + 30);
        // tx.origin dave, router caller carol: carol is the authenticated buyer.
        vm.prank(carol, dave);
        router.swap{value: 0.01 ether}(key, true, -0.01 ether);
        assertGt(_protection().bought(1, carol), 0);
        assertEq(_protection().bought(1, dave), 0);
    }

    // ---------------------------------------------------------------- 8-10. 2 % caps

    function test_BuyerCapCumulativeIncludingExempt() public {
        address[] memory ex = new address[](1);
        ex[0] = bob;
        (PoolKey memory key,) = _launch(ex);
        vm.warp(block.timestamp + 30);
        _buy(bob, key, -0.08 ether, 0.08 ether); // ~1.2 % of the supply
        vm.prank(bob, bob);
        vm.expectRevert();
        router.swap{value: 0.08 ether}(key, true, -0.08 ether);
        assertLe(_protection().bought(1, bob), _protection().OPENING_MAX());
    }

    function test_TransfersDoNotResetBuyerConsumption() public {
        (PoolKey memory key, CloverToken token) = _launch(new address[](0));
        vm.warp(block.timestamp + 30);
        _buy(carol, key, -0.08 ether, 0.08 ether);
        uint256 bag = token.balanceOf(carol);
        vm.prank(carol);
        token.transfer(dave, bag);
        assertEq(_protection().received(1, dave), bag);
        vm.prank(carol, carol);
        vm.expectRevert();
        router.swap{value: 0.08 ether}(key, true, -0.08 ether);
    }

    function test_RecipientCapAcrossBuyers() public {
        (PoolKey memory key, CloverToken token) = _launch(new address[](0));
        vm.warp(block.timestamp + 30);
        _buy(carol, key, -0.08 ether, 0.08 ether);
        _buy(dave, key, -0.08 ether, 0.08 ether);
        // dave sends his bag to carol: carol would receive ~2.4 % in total.
        uint256 bag = token.balanceOf(dave);
        vm.prank(dave);
        vm.expectRevert(CloverLaunchProtection.RecipientLimit.selector);
        token.transfer(carol, bag);
        // Sending it back and forth does not reset the recipient ledger either.
        uint256 carolReceived = _protection().received(1, carol);
        vm.prank(carol);
        token.transfer(dave, 1 ether);
        assertEq(_protection().received(1, carol), carolReceived);
    }

    function test_CapsEndAfter300Seconds() public {
        (PoolKey memory key, CloverToken token) = _launch(new address[](0));
        vm.warp(block.timestamp + 300);
        _buy(carol, key, -0.5 ether, 0.5 ether);
        uint256 bag = token.balanceOf(carol);
        assertGt(bag, _protection().OPENING_MAX());
        vm.prank(carol);
        token.transfer(dave, bag);
    }

    function test_DevBuyCountsAgainstCreatorCaps() public {
        Launchpad.LaunchParams memory p = _params(new address[](0));
        vm.prank(alice, alice);
        vm.expectRevert();
        launchpad.launchWithCanvas{value: 0.51 ether}(p);
        vm.prank(alice, alice);
        (uint256 idx, address token,) = launchpad.launchWithCanvas{value: 0.06 ether}(p);
        assertEq(_protection().bought(idx, alice), CloverToken(token).balanceOf(alice));
        assertEq(_protection().received(idx, alice), CloverToken(token).balanceOf(alice));
    }

    // ---------------------------------------------------------------- 11. opening tax vault

    function test_OpeningTaxVaultClaimPaysCreator() public {
        (PoolKey memory key,) = _launch(new address[](0));
        Fees memory f = _buy(carol, key, -0.01 ether, 0.01 ether);
        uint256 before = alice.balance;
        vm.prank(dave);
        _vault().claim(1);
        assertEq(alice.balance - before, f.openingTax);
        assertEq(_vault().accrued(1), 0);
        assertEq(address(_vault()).balance, _vault().totalAccrued());
        CloverOpeningTaxVault v = _vault();
        vm.expectRevert(CloverOpeningTaxVault.NotHook.selector);
        v.record(1, 1);
    }

    // ---------------------------------------------------------------- 12. starting FDV from the oracle

    function test_StartingFdvFromOracle() public {
        address token;
        uint256 idx;
        (idx, token,,) = launchChildAt(alice, 300, 5_000, 0, new address[](0));
        Launchpad.TokenInfo memory t = launchpad.tokenInfo(idx);
        assertEq(t.ethUsd, 2_400e8);
        _assertFdvAtLeast15k(t.startTick, 2_400e8);
        // A different price gives a different tick, still >= $15,000.
        feed.set(3_100e8, 0);
        (int24 tick,) = launchpad.startTick();
        assertTrue(tick != t.startTick);
        _assertFdvAtLeast15k(tick, 3_100e8);
        // Genesis was priced the same way.
        _assertFdvAtLeast15k(launchpad.tokenInfo(0).startTick, 2_400e8);
    }

    function _assertFdvAtLeast15k(int24 tick, uint256 ethUsd) internal pure {
        assertEq(tick % 200, 0);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 fdvWei = FullMath.mulDiv(1e9 ether, 1 << 192, uint256(sqrtP) * sqrtP);
        uint256 fdvUsd = fdvWei * ethUsd / 1e8 / 1 ether;
        assertGe(fdvUsd, 15_000);
        assertLe(fdvUsd, 15_310, "one grid step above at most");
    }

    function test_StaleOrBadOracleBlocksLaunch() public {
        Launchpad.LaunchParams memory p = _params(new address[](0));
        vm.warp(block.timestamp + 10 days);
        feed.set(2_400e8, block.timestamp - 1 hours - 1);
        vm.prank(alice);
        vm.expectRevert(Launchpad.StaleOracle.selector);
        launchpad.launchWithCanvas{value: 0.01 ether}(p);
        feed.set(0, 0);
        vm.prank(alice);
        vm.expectRevert(Launchpad.BadOracle.selector);
        launchpad.launchWithCanvas{value: 0.01 ether}(p);
        feed.set(2_400e8, block.timestamp - 1 hours);
        vm.prank(alice);
        launchpad.launchWithCanvas{value: 0.01 ether}(p);
    }

    function test_GenesisProtectionConfig() public view {
        assertEq(launchpad.genesisExemptWallets().length, 1);
        assertEq(launchpad.genesisExemptWallets()[0], bob);
        assertEq(address(clover.protection()), address(_protection()));
        assertEq(clover.protectionEnds(), genesisAt + 300);
        // 0.1 ETH initial buy at ~$15,000 FDV stays under 2 % of the supply.
        assertLt(clover.balanceOf(creator), _protection().OPENING_MAX());
    }
}
