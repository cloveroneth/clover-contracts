// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IProgrammableLaunchStampRouterV1 as IRouter} from
    "../../src/interfaces/programmable/IProgrammableLaunchStampRouterV1.sol";
import {CloverGraph} from "../../script/CloverGraph.sol";
import {CloverHook} from "../../src/CloverHook.sol";
import {CloverCanvas} from "../../src/CloverCanvas.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {CloverToken} from "../../src/CloverToken.sol";
import {EthereumNativeFeeVaultV3} from "../../src/programmable/EthereumNativeFeeVaultV3.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Mainnet fork: full Router launch with a mocked EIP-1271 authority, then swaps with empty hookData
///         through the canonical Uniswap Universal Router (external router) and through the router used by
///         programmable.market `/api/swap/ethereum/prepare` with the native30 (pool-enforced) command shape
///         0x10 V4_SWAP + 0x04 SWEEP, i.e. no route fee transfer. Skipped when ETH_RPC_URL is not set.
///
/// Every check reads the exact deltas of `feeVault.platformAccrued()`, of the vault's PoolManager native claim
/// balance (backing) and of the fixed recipient's ETH balance after `feeVault.claimPlatform()`.
contract CloverLaunchForkTest is Test, CloverGraph {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Live manifest values (launchStampRouter, bindings, events).
    address constant ROUTER = 0x8622DD5bAb44185f2A458ac90384Ac99248f8d56;
    bytes32 constant ROUTER_RUNTIME = 0x40e27ecf201761d5eb66bc4f2d5c6124831ef078d7baf458ca5f41b1a8108546;
    address constant GRAPH_FACTORY = 0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887;
    bytes32 constant GRAPH_FACTORY_RUNTIME = 0xd23692fae59331592048e71a96d4963e170ee56e449683dc9f7fa3f9470018b8;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 constant POOL_MANAGER_RUNTIME = 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    address constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    bytes32 constant TOPIC_LAUNCH = 0x6cf479a102f1eebc9244f48f8d68f6aa52b4c5a4516318df58ba46614a5b14f2;
    bytes32 constant TOPIC_ROUTE = 0x45e7cc355b63ca67d6278a0d8d23470ce2a0741a9c60283d7dee712df7a877a5;
    bytes32 constant TOPIC_COMPONENT = 0x8147265e7396d6400cee8d049456a1f7438fdfbe2a7c81c976d51ba67e52ff4b;

    // Uniswap canonical mainnet deployments.
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Router in the transactions returned by programmable.market `/api/swap/ethereum/prepare`.
    address constant PROGRAMMABLE_SWAP_ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    address constant MSG_SENDER = address(1);
    address constant ADDRESS_THIS = address(2);

    address launchWallet = makeAddr("launchWallet");
    address trader = makeAddr("trader");
    address exemptWallet = makeAddr("exemptWallet");
    bool forked;
    uint256 recipientBeforeLaunch;
    Snap snapBefore;
    uint256 lastGross;
    uint256 lastPlat;

    Config cfg;
    Prepared prep;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function _config() internal view returns (Config memory c) {
        c.router = IRouter(ROUTER);
        c.launchWallet = launchWallet;
        c.platformRecipient = PLATFORM_RECIPIENT;
        c.protocolRecipient = launchWallet;
        c.routeNamespace = keccak256("clover.v1");
        c.nonce = keccak256(abi.encode("clover.v1.nonce", block.number));
        c.launchId = keccak256(abi.encode("clover.v1.launch", block.number));
        c.validAfter = uint64(block.timestamp);
        c.deadline = uint64(block.timestamp + 50 minutes);
        c.name = "CLOVER";
        c.symbol = "CLOVER";
        c.tokenFeeBps = 300;
        c.genesisCanvasShareBps = 2000;
        c.genesisSize = 12;
        c.genesisRentBps = 500;
        c.genesisFadeTime = 3 days;
        c.genesisStartPrice = 0.002 ether;
        c.genesisExempt = new address[](1);
        c.genesisExempt[0] = exemptWallet;
        c.devBuy = 0.05 ether;
        c.maxSaltIterations = 400_000;
    }

    function test_fork_bindingsMatchManifest() public onlyFork {
        assertEq(ROUTER.codehash, ROUTER_RUNTIME, "router runtime");
        IRouter r = IRouter(ROUTER);
        assertEq(r.CHAIN_ID(), 1);
        assertEq(r.GRAPH_FACTORY(), GRAPH_FACTORY);
        assertEq(r.GRAPH_FACTORY_RUNTIME_CODE_HASH(), GRAPH_FACTORY_RUNTIME);
        assertEq(GRAPH_FACTORY.codehash, GRAPH_FACTORY_RUNTIME);
        assertEq(r.POOL_MANAGER(), POOL_MANAGER);
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_RUNTIME);
        assertEq(r.PERMIT_AUTHORITY().codehash, r.PERMIT_AUTHORITY_RUNTIME_CODE_HASH());
    }

    function test_fork_launchAndStamp_thenPoolEnforcedPlatformFee() public onlyFork {
        cfg = _config();
        Prepared memory p = prepare(cfg);
        emit log_named_uint("hook salt iterations", p.saltIterations);
        emit log_named_address("hook", p.accounts[T_HOOK]);
        emit log_named_address("CLOVER", p.accounts[T_TOKEN]);

        // Pool must be uninitialized before the Router call.
        (uint160 sqrtBefore,,,) = IPoolManager(POOL_MANAGER).getSlot0(p.stampRequest.poolKey.toId());
        assertEq(sqrtBefore, 0);

        recipientBeforeLaunch = PLATFORM_RECIPIENT.balance;
        (bytes32 stampHash, Vm.Log[] memory logs) = simulateLaunchWithMockedAuthority(cfg, p);
        assertTrue(stampHash != bytes32(0));
        _checkInitialBuyFee(p);

        // Runtime hashes predicted in the graph simulation match the deployed code.
        for (uint256 i; i < N_TARGETS; ++i) {
            assertEq(p.accounts[i].codehash, p.runtimeCodeHashes[i], "runtime hash");
        }

        // Events from the canonical Router with the manifest topics.
        uint256 nLaunch;
        uint256 nRoute;
        uint256 nComponent;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != ROUTER) continue;
            bytes32 t0 = logs[i].topics[0];
            if (t0 == TOPIC_LAUNCH) {
                nLaunch++;
                assertEq(logs[i].topics[1], cfg.launchId);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), p.accounts[T_TOKEN]);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), p.accounts[T_HOOK]);
            } else if (t0 == TOPIC_ROUTE) {
                nRoute++;
                assertEq(uint256(logs[i].topics[2]), 1, "kind CustomGraph");
                assertEq(logs[i].topics[3], keccak256(p.routePayload));
            } else if (t0 == TOPIC_COMPONENT) {
                nComponent++;
            }
        }
        assertEq(nLaunch, 1);
        assertEq(nRoute, 1);
        assertEq(nComponent, N_TARGETS);

        // Router getters agree.
        IRouter r = IRouter(ROUTER);
        assertEq(r.launchIdByToken(p.accounts[T_TOKEN]), cfg.launchId);
        (bytes32 lid, bytes32 sh) = r.stampProof(p.accounts[T_HOOK]);
        assertEq(lid, cfg.launchId);
        assertEq(sh, stampHash);
        assertEq(r.launchIdByPool(POOL_MANAGER, PoolId.unwrap(p.stampRequest.poolKey.toId())), cfg.launchId);

        // Genesis state: canvas 0 owned by the launch wallet, dev buy done, pool above the start tick.
        CloverCanvas canvas = CloverCanvas(p.accounts[T_CANVAS]);
        assertEq(canvas.canvasCount(), 1);
        assertEq(canvas.canvas(0).creator, launchWallet);
        assertGt(CloverToken(p.accounts[T_TOKEN]).balanceOf(launchWallet), 0);

        // A pixel can be captured on the Genesis canvas.
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        canvas.capture{value: 0.002 ether + 0.01 ether}(0, 0.002 ether, 0.05 ether, 0x7bc043);
        assertEq(canvas.ownerOf(0), trader);

        _openingProtection(p);
        _fourQuadrants(p, UNIVERSAL_ROUTER, "external Uniswap UR");
        _fourQuadrants(p, PROGRAMMABLE_SWAP_ROUTER, "Programmable swap router");
        _secondUserAfterTime(p);
        _claim(p);
        _childLaunch(p);
    }

    /// @notice Initial buy (0.05 ETH) inside the launch transaction: ceil 30 bps accrued once, backed.
    function _checkInitialBuyFee(Prepared memory p) internal {
        CloverHook hook = CloverHook(payable(p.accounts[T_HOOK]));
        EthereumNativeFeeVaultV3 vault = hook.feeVault();
        assertEq(vault.kernel(), address(hook), "vault kernel");
        assertEq(vault.PLATFORM_RECIPIENT(), PLATFORM_RECIPIENT, "vault recipient");
        assertEq(address(vault.poolManager()), POOL_MANAGER);
        assertEq(PLATFORM_RECIPIENT.balance, recipientBeforeLaunch, "nothing sent outside the pool fee");
        uint256 expected = (cfg.devBuy * 30 + 9_999) / 10_000;
        emit log_named_uint("initial buy gross wei", cfg.devBuy);
        emit log_named_uint("initial buy platformAccrued delta wei", vault.platformAccrued());
        emit log_named_uint("initial buy vault PoolManager native claims wei", IPoolManager(POOL_MANAGER).balanceOf(address(vault), 0));
        assertEq(vault.platformAccrued(), expected, "initial buy fee");
        assertEq(IPoolManager(POOL_MANAGER).balanceOf(address(vault), 0), expected, "backing");
    }

    /// @notice Opening protection right after the launch transaction, through the canonical Uniswap UR:
    ///         99 % buy fee decaying over 30 s (platform fee still ceil 30 bps of the gross), exempt wallets at the
    ///         normal rate, 2 % per-wallet buy limit for 300 s even for exempt wallets.
    function _openingProtection(Prepared memory p) internal {
        CloverHook hook = CloverHook(payable(p.accounts[T_HOOK]));
        PoolKey memory key = p.stampRequest.poolKey;
        uint256 t0 = block.timestamp;
        emit log_string("opening protection");
        _openingBuy(p, trader, 0.01 ether, 990_000, "  t+0s non-exempt");
        vm.warp(t0 + 15);
        _openingBuy(p, trader, 0.01 ether, 990_000 - (990_000 - 33_000) * 15 / 30, "  t+15s non-exempt");
        _openingBuy(p, exemptWallet, 0.01 ether, 33_000, "  t+15s exempt wallet");
        _openingBuy(p, launchWallet, 0.01 ether, 33_000, "  t+15s creator");
        // 2 % of the supply is ~0.17 ETH at the start; 0.5 ETH exceeds it, exempt or not.
        vm.deal(exemptWallet, 1 ether);
        vm.prank(exemptWallet, exemptWallet);
        vm.expectRevert();
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 0.5 ether}(
            hex"10", _v4ExactInSingle(key, true, 0.5 ether), block.timestamp
        );
        assertLe(hook.openingBought(key.toId(), exemptWallet), hook.OPENING_MAX_BUY());
        vm.warp(t0 + 30);
        _openingBuy(p, trader, 0.01 ether, 33_000, "  t+30s non-exempt");
        // After 300 s the limit is gone.
        vm.warp(t0 + 300);
        vm.deal(exemptWallet, 1 ether);
        vm.prank(exemptWallet, exemptWallet);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 0.5 ether}(
            hex"10", _v4ExactInSingle(key, true, 0.5 ether), block.timestamp
        );
    }

    function _openingBuy(Prepared memory p, address who, uint128 amount, uint256 ratePips, string memory label) internal {
        CloverHook hook = CloverHook(payable(p.accounts[T_HOOK]));
        uint256 accrued0 = hook.platformAccrued();
        vm.deal(who, who.balance + amount);
        vm.recordLogs();
        vm.prank(who, who);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: amount}(
            hex"10", _v4ExactInSingle(p.stampRequest.poolKey, true, amount), block.timestamp
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FeeTaken(bytes32,address,bool,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != topic) continue;
            (, uint256 gross, uint256 plat, uint256 tokenFee) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            emit log_string(label);
            emit log_named_uint("    total fee rate (pips)", ratePips);
            emit log_named_uint("    platform fee wei", plat);
            emit log_named_uint("    token fee wei", tokenFee);
            assertEq(gross, amount);
            assertEq(plat, (gross * 30 + 9_999) / 10_000, "platform ceil 30 bps");
            assertEq(tokenFee, gross * (ratePips - 3_000) / 1_000_000, "opening rate");
            assertEq(hook.platformAccrued() - accrued0, plat);
            return;
        }
        revert("no FeeTaken");
    }

    struct Snap {
        uint256 accrued;
        uint256 backing;
        uint256 traderEth;
        uint256 traderClover;
        uint256 recipientEth;
    }

    function _snap(EthereumNativeFeeVaultV3 vault, CloverToken clover) internal view returns (Snap memory s_) {
        s_ = Snap(
            vault.platformAccrued(),
            IPoolManager(POOL_MANAGER).balanceOf(address(vault), 0),
            trader.balance,
            clover.balanceOf(trader),
            PLATFORM_RECIPIENT.balance
        );
    }

    /// @notice Buy/sell, exact-in/exact-out, two sizes each, through `router` with empty hookData.
    function _fourQuadrants(Prepared memory p, address router, string memory label) internal {
        CloverToken clover = CloverToken(p.accounts[T_TOKEN]);
        vm.deal(trader, 100 ether);
        vm.startPrank(trader);
        clover.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(clover), router, type(uint160).max, uint48(block.timestamp + 1 hours));
        vm.stopPrank();
        uint128[2] memory sizes = [uint128(0.01 ether), uint128(1 ether)];
        for (uint256 i; i < 2; ++i) {
            _trade(p, router, label, 0, sizes[i]); // buy exact-in
            _trade(p, router, label, 1, sizes[i]); // buy exact-out (ETH max)
            _trade(p, router, label, 2, sizes[i]); // sell exact-in (half the bag)
            _trade(p, router, label, 3, sizes[i] / 8); // sell exact-out (ETH out)
        }
    }

    /// @dev kind 0 buy exact-in `amount` ETH; 1 buy exact-out of a quarter of the bag + 1 token; 2 sell
    ///      exact-in half the bag; 3 sell exact-out `amount` ETH.
    function _trade(Prepared memory p, address router, string memory label, uint256 kind, uint128 amount) internal {
        EthereumNativeFeeVaultV3 vault = CloverHook(payable(p.accounts[T_HOOK])).feeVault();
        CloverToken clover = CloverToken(p.accounts[T_TOKEN]);
        snapBefore = _snap(vault, clover);
        (bytes[] memory inputs, uint256 value) = _build(p, router, kind, amount);
        vm.recordLogs();
        vm.prank(trader);
        IUniversalRouter(router).execute{value: value}(
            router == PROGRAMMABLE_SWAP_ROUTER ? bytes(hex"1004") : bytes(hex"10"), inputs, block.timestamp
        );
        (lastGross, lastPlat) = _feeTaken(vm.getRecordedLogs(), p.accounts[T_HOOK]);
        _check(snapBefore, _snap(vault, clover), kind, label);
    }

    function _build(Prepared memory p, address router, uint256 kind, uint128 amount)
        internal
        view
        returns (bytes[] memory inputs, uint256 value)
    {
        PoolKey memory key = p.stampRequest.poolKey;
        address clover = p.accounts[T_TOKEN];
        uint256 bag = CloverToken(clover).balanceOf(trader);
        if (kind == 0) {
            inputs = _withSweep(router, _v4Input(key, true, amount, address(0), clover, 0x0f, address(0)));
            value = amount;
        } else if (kind == 1) {
            inputs = _withSweep(router, _v4ExactOut(key, true, uint128(bag / 4 + 1e18), 10 ether, address(0), clover));
            value = 10 ether;
        } else if (kind == 2) {
            inputs = _withSweep(router, _v4Input(key, false, uint128(bag / 2), clover, address(0), 0x0f, address(0)));
        } else {
            inputs = _withSweep(router, _v4ExactOut(key, false, amount, type(uint128).max, clover, address(0)));
        }
    }

    function _check(Snap memory a, Snap memory b, uint256 kind, string memory label) internal {
        uint256 gross = lastGross;
        uint256 plat = lastPlat;
        string[4] memory names = [" | buy exact-in", " | buy exact-out", " | sell exact-in", " | sell exact-out"];
        uint256 expected = (gross * 30 + 9_999) / 10_000;
        emit log_string(string.concat(label, names[kind]));
        emit log_named_uint("  gross native wei", gross);
        emit log_named_uint("  platformAccrued delta wei", b.accrued - a.accrued);
        emit log_named_uint("  vault backing delta wei", b.backing - a.backing);
        emit log_named_uint("  recipient ETH delta (route charge) wei", b.recipientEth - a.recipientEth);
        assertGt(gross, 0);
        assertEq(plat, expected, "ceil 30 bps of gross");
        assertEq(b.accrued - a.accrued, expected, "accrued once");
        assertEq(b.backing - a.backing, expected, "backed");
        assertEq(b.recipientEth, a.recipientEth, "no second charge by the route");
        if (kind < 2) assertGt(b.traderClover, a.traderClover);
        else assertGt(b.traderEth, a.traderEth);
    }

    /// @notice Another wallet trades after time passes; the fee is unchanged.
    function _secondUserAfterTime(Prepared memory p) internal {
        address second = makeAddr("second");
        vm.warp(block.timestamp + 9 days);
        vm.roll(block.number + 60_000);
        address saved = trader;
        trader = second;
        vm.deal(second, 5 ether);
        _trade(p, UNIVERSAL_ROUTER, "second user after 9 days", 0, 0.3 ether);
        trader = saved;
    }

    /// @notice Permissionless claim pays exactly the accrued amount to the fixed recipient and burns the backing.
    function _claim(Prepared memory p) internal {
        EthereumNativeFeeVaultV3 vault = CloverHook(payable(p.accounts[T_HOOK])).feeVault();
        uint256 accrued = vault.platformAccrued();
        uint256 r0 = PLATFORM_RECIPIENT.balance;
        vm.prank(makeAddr("anyone"));
        vault.claimPlatform();
        emit log_named_uint("claimPlatform paid to 0xD885...79da wei", PLATFORM_RECIPIENT.balance - r0);
        assertEq(PLATFORM_RECIPIENT.balance - r0, accrued);
        assertEq(vault.platformAccrued(), 0);
        assertEq(IPoolManager(POOL_MANAGER).balanceOf(address(vault), 0), 0);
    }

    function _feeTaken(Vm.Log[] memory logs, address hook) internal pure returns (uint256 gross, uint256 plat) {
        bytes32 topic = keccak256("FeeTaken(bytes32,address,bool,uint256,uint256,uint256)");
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == hook && logs[i].topics[0] == topic) {
                (, gross, plat,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
                ++n;
            }
        }
        require(n == 1, "one FeeTaken per swap");
    }

    function _withSweep(address router, bytes memory v4) internal pure returns (bytes[] memory inputs) {
        if (router == PROGRAMMABLE_SWAP_ROUTER) {
            inputs = new bytes[](2);
            inputs[1] = abi.encode(address(0), MSG_SENDER, uint256(0));
        } else {
            inputs = new bytes[](1);
        }
        inputs[0] = v4;
    }

    /// @dev V4_SWAP input: SWAP_EXACT_OUT_SINGLE (0x08), SETTLE_ALL (0x0c), TAKE_ALL (0x0f).
    function _v4ExactOut(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint128 amountInMax,
        address inCur,
        address outCur
    ) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(0x08), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactOutputSingleParams(key, zeroForOne, amountOut, amountInMax, ""));
        params[1] = abi.encode(inCur, uint256(amountInMax));
        params[2] = abi.encode(outCur, uint256(amountOut));
        return abi.encode(actions, params);
    }

    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    function _childLaunch(Prepared memory p) internal {
        Launchpad lp = Launchpad(p.accounts[T_LAUNCHPAD]);
        vm.deal(trader, 10 ether);
        uint256 value = lp.LAUNCH_FEE() + 0.1 ether;
        Launchpad.LaunchParams memory lp_ = Launchpad.LaunchParams({
            name: "Child",
            symbol: "CHLD",
            tokenFeeBps: 300,
            canvasShareBps: 5_000,
            canvasName: "Child board",
            size: 10,
            rentBps: 500,
            fadeTime: 1 days,
            startPrice: 0.001 ether,
            devBuyMinOut: 0,
            exemptWallets: new address[](0)
        });
        vm.prank(trader);
        uint256 g0 = gasleft();
        (uint256 idx, address token, uint256 canvasId) = lp.launchWithCanvas{value: value}(lp_);
        emit log_named_uint("gas child launch", g0 - gasleft());
        assertEq(idx, 1);
        assertEq(canvasId, 1);
        assertGt(CloverToken(token).balanceOf(trader), 0);
        // Child pools on the same hook pay the same pool-enforced 30 bps into the same vault.
        CloverHook hook = CloverHook(payable(p.accounts[T_HOOK]));
        vm.warp(block.timestamp + hook.OPENING_LIMIT_PERIOD());
        uint256 plat0 = hook.platformAccrued();
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 0.5 ether}(
            hex"10", _v4ExactInSingle(lp.poolKeyOf(token), true, 0.5 ether), block.timestamp
        );
        assertEq(hook.platformAccrued() - plat0, 0.0015 ether);
    }

    /// @dev V4_SWAP input: SWAP_EXACT_IN_SINGLE (0x06), SETTLE_ALL (0x0c), then TAKE_ALL (0x0f, min 0) or
    ///      TAKE (0x0e, full open delta to `takeTo`).
    function _v4Input(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        address inCur,
        address outCur,
        uint8 takeAction,
        address takeTo
    ) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), takeAction);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amountIn, 0, ""));
        params[1] = abi.encode(inCur, uint256(amountIn));
        params[2] = takeAction == 0x0f ? abi.encode(outCur, uint256(0)) : abi.encode(outCur, takeTo, uint256(0));
        return abi.encode(actions, params);
    }

    /// @dev V4_SWAP input: actions SWAP_EXACT_IN_SINGLE (0x06), SETTLE_ALL (0x0c), TAKE_ALL (0x0f).
    function _v4ExactInSingle(PoolKey memory key, bool zeroForOne, uint128 amountIn)
        internal
        pure
        returns (bytes[] memory inputs)
    {
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amountIn, 0, ""));
        (address inCur, address outCur) = zeroForOne
            ? (address(0), address(uint160(uint256(bytes32(abi.encode(key.currency1))))))
            : (address(uint160(uint256(bytes32(abi.encode(key.currency1))))), address(0));
        params[1] = abi.encode(inCur, uint256(amountIn));
        params[2] = abi.encode(outCur, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }
}
