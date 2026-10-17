// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./utils/Base.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CloverHook} from "../src/CloverHook.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {EthereumNativeFeeVaultV3} from "../src/programmable/EthereumNativeFeeVaultV3.sol";
import {Vm} from "forge-std/Vm.sol";

contract CloverHookTest is Base {
    using PoolIdLibrary for PoolKey;

    function test_GenesisPool() public view {
        assertEq(launchpad.tokenCount(), 1);
        Launchpad.TokenInfo memory t = launchpad.tokenInfo(0);
        assertEq(t.token, address(clover));
        assertEq(t.canvasId, 0);
        (address c, uint32 canvasId, uint16 share,) = hook.tokenConfig(0);
        assertEq(c, creator);
        assertEq(canvasId, 0);
        assertEq(share, 10_000);
        // Genesis dev buy went to the creator.
        assertGt(clover.balanceOf(creator), 0);
    }

    function test_BuyFeeSplit() public {
        uint256 pendingBefore = hook.canvasPending(0);
        uint256 platformBefore = hook.platformAccrued();
        buyExactIn(alice, cloverKey, 1 ether);
        assertEq(hook.platformAccrued() - platformBefore, 0.003 ether);
        assertEq(hook.canvasPending(0) - pendingBefore, 0.05 ether); // 5 % token fee, 100 % to the canvas
        assertEq(hook.creatorOwed(creator), 0);
    }

    function test_SellFeeAndFlush() public {
        buyExactIn(alice, cloverKey, 1 ether);
        sellExactIn(alice, cloverKey, clover.balanceOf(alice) / 2);
        uint256 pending = hook.canvasPending(0);
        assertGt(pending, 0.05 ether);

        uint256 creatorBefore = canvas.owed(creator);
        hook.flush(0);
        assertEq(hook.canvasPending(0), 0);
        // No pixel held: the whole flush goes to the Genesis creator.
        assertEq(canvas.owed(creator) - creatorBefore, pending);
        assertEq(canvas.canvas(0).totalFunded, pending);
    }

    function test_FlushRewardsHolders() public {
        capture(bob, pid(0, 0), 0.01 ether, 30);
        buyExactIn(alice, cloverKey, 2.88 ether);
        uint256 pending = hook.canvasPending(0);
        hook.flush(0);
        assertApproxEqAbs(canvas.pixel(pid(0, 0)).pendingRewards, pending / 144, 1);
    }

    function test_PlatformClaim() public {
        buyExactIn(alice, cloverKey, 1 ether);
        EthereumNativeFeeVaultV3 vault = hook.feeVault();
        uint256 accrued = vault.platformAccrued();
        // Backed by PoolManager native claims held by the vault.
        assertEq(manager.balanceOf(address(vault), 0), accrued);
        uint256 before = platform.balance;
        vault.claimPlatform();
        assertEq(platform.balance - before, accrued);
        assertEq(vault.platformAccrued(), 0);
        assertEq(manager.balanceOf(address(vault), 0), 0);
    }

    function test_GenesisInitialBuyPaysPlatform() public view {
        // setUp's 0.1 ETH Genesis buy: ceil(0.1 ETH * 30 / 10000).
        assertEq(hook.platformAccrued(), 0.0003 ether);
        assertEq(hook.feeVault().kernel(), address(hook));
        assertEq(hook.feeVault().PLATFORM_RECIPIENT(), platform);
    }

    function test_SellPaysPlatform() public {
        buyExactIn(alice, cloverKey, 1 ether);
        uint256 before = hook.platformAccrued();
        vm.recordLogs();
        sellExactIn(alice, cloverKey, clover.balanceOf(alice));
        uint256 delta = hook.platformAccrued() - before;
        assertGt(delta, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FeeTaken(bytes32,address,bool,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            (, uint256 gross, uint256 plat,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            assertEq(plat, (gross * 30 + 9_999) / 10_000);
            assertEq(delta, plat);
        }
    }

    function test_FeeVaultOnlyKernel() public {
        EthereumNativeFeeVaultV3 vault = hook.feeVault();
        vm.expectRevert(EthereumNativeFeeVaultV3.UnauthorizedKernel.selector);
        vault.recordFees(1, 0);
    }

    function test_ChildLaunch() public {
        uint256 genesisCreatorBefore = canvas.owed(creator);
        (uint256 idx, address token, uint256 canvasId, PoolKey memory key) = launchChild(alice, 300, 5_000, 0.1 ether);
        assertEq(idx, 1);
        assertEq(canvasId, 1);
        assertEq(canvas.canvas(1).creator, alice);
        assertEq(canvas.canvas(1).size, 7);
        assertGt(CloverTokenLike(token).balanceOf(alice), 0);
        // Launch fee into the Genesis canvas (no holder: to its creator).
        assertEq(canvas.owed(creator) - genesisCreatorBefore, 0.01 ether);

        buyExactIn(bob, key, 1 ether);
        // Dev buy and bob's buy both paid the 3 % token fee: half to the canvas, half to alice.
        uint256 fees = (0.1 ether + 1 ether) * 30_000 / 1_000_000;
        assertEq(hook.canvasPending(1), fees / 2);
        assertEq(hook.creatorOwed(alice), fees - fees / 2);

        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claimCreator();
        assertEq(alice.balance - before, fees - fees / 2);
    }

    function test_CanvasShareRules() public {
        launchChild(alice, 300, 5_000, 0);
        vm.prank(bob);
        vm.expectRevert(CloverHook.NotCreator.selector);
        hook.setCanvasShare(1, 6_000);

        vm.startPrank(alice);
        hook.setCanvasShare(1, 8_000); // raise: instant
        vm.expectRevert(CloverHook.ShareDecreaseTooLarge.selector);
        hook.setCanvasShare(1, 6_000);
        hook.setCanvasShare(1, 7_000);
        vm.expectRevert(CloverHook.ShareDecreaseTooSoon.selector);
        hook.setCanvasShare(1, 6_500);
        vm.warp(block.timestamp + 7 days);
        hook.setCanvasShare(1, 6_000);
        vm.expectRevert(CloverHook.InvalidFee.selector);
        hook.setCanvasShare(1, 1_999);
        vm.stopPrank();
    }

    function test_LaunchValidation() public {
        Launchpad.LaunchParams memory p = Launchpad.LaunchParams({
            name: "X",
            symbol: "X",
            tokenFeeBps: 50, // below 1 %
            canvasShareBps: 5_000,
            canvasName: "X",
            size: 7,
            rentBps: 500,
            fadeTime: 1 days,
            startPrice: 0.001 ether,
            devBuyMinOut: 0,
            exemptWallets: new address[](0)
        });
        vm.prank(alice);
        vm.expectRevert(CloverHook.InvalidFee.selector);
        launchpad.launchWithCanvas{value: 0.01 ether}(p);

        p.tokenFeeBps = 500;
        vm.prank(alice);
        vm.expectRevert(Launchpad.InsufficientValue.selector);
        launchpad.launchWithCanvas{value: 0.009 ether}(p);
    }

    function test_GenesisOnlyOnce() public {
        vm.expectRevert(Launchpad.AlreadyGenesis.selector);
        launchpad.genesis(clover);
    }
}

interface CloverTokenLike {
    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);
}
