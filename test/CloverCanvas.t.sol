// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./utils/Base.t.sol";
import {CloverCanvas} from "../src/CloverCanvas.sol";

contract CloverCanvasTest is Base {
    uint256 internal constant G = 0; // Genesis canvas

    function test_GenesisCanvas() public view {
        CloverCanvas.Canvas memory c = canvas.canvas(G);
        assertEq(c.creator, creator);
        assertEq(c.size, 12);
        assertEq(c.rentBps, 500);
        assertEq(c.fadeTime, 3 days);
        assertEq(canvas.canvasCount(), 1);
        CloverCanvas.PixelView[] memory all = canvas.pixels(G);
        assertEq(all.length, 144);
        assertEq(all[143].state, 0);
        assertEq(all[143].price, GENESIS_START);
    }

    function test_FirstSaleSplit() public {
        capture(alice, pid(G, 5), 0.01 ether, 7);
        assertEq(canvas.ownerOf(pid(G, 5)), alice);
        assertEq(canvas.owed(creator), GENESIS_START * 9_500 / 10_000);
        assertEq(canvas.owed(protocol), GENESIS_START * 500 / 10_000);
        assertEq(canvas.canvas(G).heldCount, 1);
    }

    function test_CaptureHeldSplitAndRefund() public {
        uint256 id = pid(G, 7);
        capture(alice, id, 1 ether, 7);
        uint256 aliceDeposit = canvas.pixel(id).deposit;
        uint256 creatorBefore = canvas.owed(creator);
        uint256 protocolBefore = canvas.owed(protocol);

        vm.warp(block.timestamp + 1 hours);
        uint256 rent = uint256(1 ether) * 500 * 1 hours / (10_000 * 7 days);
        capture(bob, id, 2 ether, 7);

        assertEq(canvas.ownerOf(id), bob);
        assertEq(canvas.owed(alice), 0.9 ether + aliceDeposit - rent);
        assertEq(canvas.owed(creator) - creatorBefore, 0.05 ether + rent * 8_000 / 10_000);
        assertEq(canvas.owed(protocol) - protocolBefore, 0.05 ether + rent - rent * 8_000 / 10_000);
    }

    function test_CooldownAndGuards() public {
        uint256 id = pid(G, 1);
        capture(alice, id, 1 ether, 2);

        CloverCanvas.PixelView memory v = canvas.pixel(id);
        vm.prank(bob);
        vm.expectRevert(CloverCanvas.Cooldown.selector);
        canvas.capture{value: 2 ether}(id, v.price, 1 ether, 0);

        vm.warp(block.timestamp + 15 minutes);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CloverCanvas.PriceAboveMax.selector, 1 ether, 0.5 ether));
        canvas.capture{value: 2 ether}(id, 0.5 ether, 1 ether, 0);

        uint256 minDep = uint256(1 ether) * 500 / 10_000 / 7;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CloverCanvas.InsufficientDeposit.selector, minDep));
        canvas.capture{value: 1 ether + minDep - 1}(id, 1 ether, 1 ether, 0);

        vm.prank(alice);
        vm.expectRevert(CloverCanvas.AlreadyHolder.selector);
        canvas.capture{value: 2 ether}(id, 1 ether, 1 ether, 0);
    }

    function test_ForfeitFadeAndReclaimPenalty() public {
        uint256 id = pid(G, 9);
        capture(alice, id, 1 ether, 1); // one day of deposit
        capture(carol, pid(G, 10), 0.01 ether, 30); // a second holder receives the penalty

        vm.warp(block.timestamp + 1 days + 1 hours);
        CloverCanvas.PixelView memory v = canvas.pixel(id);
        assertEq(v.state, 2);
        assertTrue(v.forfeited);
        assertEq(v.prevHolder, alice);
        assertLt(v.price, 1 ether);
        assertGt(v.price, 0.95 ether);

        uint256 carolPendingBefore = canvas.pixel(pid(G, 10)).pendingRewards;
        uint256 price = v.price;
        capture(bob, id, 1 ether, 7);
        assertEq(canvas.ownerOf(id), bob);
        // Each cut is floored; the rounding stays with the previous holder.
        uint256 penalty = price * 1_000 / 10_000;
        assertEq(canvas.owed(alice), price - 2 * (price * 500 / 10_000) - penalty);
        // Penalty: 10 % of the price, split over the 144 pixels; carol's pixel was the only one held.
        assertApproxEqAbs(canvas.pixel(pid(G, 10)).pendingRewards - carolPendingBefore, penalty / 144, 1);
    }

    function test_ReleaseThenReopen() public {
        uint256 id = pid(G, 3);
        capture(alice, id, 1 ether, 7);
        uint256 dep = canvas.pixel(id).deposit;
        vm.prank(alice);
        canvas.release(id);
        assertEq(canvas.owed(alice), dep);
        assertEq(canvas.pixel(id).state, 2);
        assertEq(canvas.pixel(id).price, 1 ether);

        vm.warp(block.timestamp + 1.5 days);
        assertEq(canvas.pixel(id).price, 0.5 ether);

        vm.warp(block.timestamp + 1.5 days);
        assertEq(canvas.pixel(id).state, 0);
        assertEq(canvas.pixel(id).price, GENESIS_START);
    }

    function test_FundSplitsBetweenHoldersAndCreator() public {
        capture(alice, pid(G, 0), 0.01 ether, 30);
        capture(bob, pid(G, 1), 0.01 ether, 30);
        uint256 creatorBefore = canvas.owed(creator);

        vm.deal(carol, 10 ether);
        vm.prank(carol);
        canvas.fund{value: 1.44 ether}(G);

        assertEq(canvas.owed(creator) - creatorBefore, 1.44 ether * 142 / 144);
        assertEq(canvas.pixel(pid(G, 0)).pendingRewards, 0.01 ether);

        uint256[] memory ids = new uint256[](1);
        ids[0] = pid(G, 0);
        vm.prank(alice);
        canvas.claim(ids);
        uint256 before = alice.balance;
        vm.prank(alice);
        canvas.withdraw();
        assertEq(alice.balance - before, 0.01 ether);
    }

    function test_CollectClaimsAndWithdraws() public {
        capture(alice, pid(G, 0), 0.01 ether, 30);
        vm.prank(carol);
        canvas.fund{value: 1.44 ether}(G);
        uint256[] memory ids = new uint256[](1);
        ids[0] = pid(G, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        canvas.collect(ids);
        assertEq(alice.balance - before, 0.01 ether);
        assertEq(canvas.owed(alice), 0);
    }

    function test_TransferPaysSenderRewards() public {
        capture(alice, pid(G, 0), 0.01 ether, 30);
        vm.prank(carol);
        canvas.fund{value: 1.44 ether}(G);
        vm.prank(alice);
        canvas.transferFrom(alice, bob, pid(G, 0));
        assertEq(canvas.owed(alice), 0.01 ether);
        assertEq(canvas.pixel(pid(G, 0)).pendingRewards, 0);
        assertEq(canvas.pixel(pid(G, 0)).holder, bob);
    }

    function test_HolderActions() public {
        uint256 id = pid(G, 2);
        capture(alice, id, 1 ether, 3);
        uint256 dayRent = uint256(1 ether) * 500 / 10_000 / 7;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloverCanvas.InsufficientDeposit.selector, uint256(10 ether) * 500 / 10_000 / 7));
        canvas.setPrice(id, 10 ether);

        vm.prank(alice);
        canvas.withdrawDeposit(id, uint96(dayRent));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloverCanvas.InsufficientDeposit.selector, dayRent));
        canvas.withdrawDeposit(id, uint96(dayRent * 2));

        vm.prank(alice);
        canvas.addDeposit{value: 1 ether}(id);
        vm.prank(alice);
        canvas.setPrice(id, 2 ether);
        assertEq(canvas.pixel(id).price, 2 ether);

        vm.prank(bob);
        vm.expectRevert(CloverCanvas.NotHolder.selector);
        canvas.setColor(id, 1);
    }

    function test_CreateCustomCanvas() public {
        vm.prank(alice);
        uint256 id = canvas.createCanvas{value: 0.01 ether}("Alice board", 10, 300, 7 days, 0.005 ether);
        assertEq(id, 1);
        assertEq(canvas.canvas(1).creator, alice);
        assertEq(canvas.owed(creator), 0.01 ether); // Genesis had no holder: all to its creator

        vm.prank(alice);
        vm.expectRevert(CloverCanvas.InvalidParams.selector);
        canvas.createCanvas{value: 0.01 ether}("Bad", 9, 300, 7 days, 0.005 ether);
    }

    function test_Profile() public {
        vm.prank(alice);
        canvas.setProfile("alice_eth");
        assertEq(canvas.profileOf(alice), "alice_eth");
        vm.prank(alice);
        vm.expectRevert(CloverCanvas.InvalidHandle.selector);
        canvas.setProfile("bad handle");
        vm.prank(alice);
        vm.expectRevert(CloverCanvas.InvalidHandle.selector);
        canvas.setProfile("waytoolonghandle1");
    }

    function test_OnlyLaunchpadCreatesTokenCanvases() public {
        vm.expectRevert(CloverCanvas.NotLaunchpad.selector);
        canvas.createCanvasFor(alice, "x", 7, 500, 1 days, 1, address(0));
    }

    /// @dev Random sequence of actions; the contract always holds what it owes plus live deposits.
    function testFuzz_Solvency(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        for (uint256 step; step < 40; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address u = users[seed % 3];
            uint256 id = pid(G, (seed >> 8) % 6);
            uint256 action = (seed >> 16) % 6;
            vm.warp(block.timestamp + (seed >> 24) % 2 days);
            CloverCanvas.PixelView memory v = canvas.pixel(id);
            if (action <= 1) {
                if (v.state == 1 && (v.holder == u || block.timestamp < v.capturedAt + 15 minutes)) continue;
                capture(u, id, uint96(0.001 ether + (seed >> 40) % 1 ether), 1 + (seed >> 32) % 5);
            } else if (action == 2 && v.state == 1) {
                vm.prank(v.holder);
                canvas.release(id);
            } else if (action == 3) {
                vm.prank(u);
                canvas.fund{value: (seed >> 48) % 1 ether}(G);
            } else if (action == 4) {
                uint256[] memory ids = new uint256[](1);
                ids[0] = id;
                canvas.poke(ids);
            } else {
                vm.prank(u);
                canvas.withdraw();
            }
        }
        uint256[] memory all = new uint256[](6);
        for (uint256 i; i < 6; ++i) all[i] = pid(G, i);
        canvas.poke(all);
        // Reward rounding leaves a few wei of dust in the contract, never a shortfall.
        uint256 due = canvas.totalOwed() + liveDeposits(G);
        assertGe(address(canvas).balance, due);
        assertLe(address(canvas).balance - due, 1_000);
    }
}
