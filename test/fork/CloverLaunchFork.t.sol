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

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Mainnet fork: full Router launch with a mocked EIP-1271 authority, then swaps through the
///         Programmable routed trade path (the router used by programmable.market prepare) and the canonical
///         Uniswap Universal Router, with empty hookData. Skipped when ETH_RPC_URL is not set.
///
/// Programmable route calldata: the buy copies a live `POST /api/swap/ethereum/prepare` response for a
/// `programmable_routed` pool (commands 0x05 TRANSFER fee, 0x10 V4_SWAP net, 0x04 SWEEP). For the sell, the
/// fee is taken from the gross ETH output: 0x10 V4_SWAP with TAKE to the router, 0x06 PAY_PORTION 30 bps, 0x04 SWEEP.
/// @dev Expected values come from the live manifest (manifestVersion 12). The prepare script re-reads it.
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
    uint256 constant ROUTED_FEE_BPS = 30;
    address constant MSG_SENDER = address(1);
    address constant ADDRESS_THIS = address(2);

    address launchWallet = makeAddr("launchWallet");
    address trader = makeAddr("trader");
    bool forked;
    uint256 recipientBeforeLaunch;

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

    function test_fork_launchAndStamp_thenProgrammableRoutedSwaps() public onlyFork {
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

        _programmableRoutedSwaps(p);
        _externalSwapNoSecondFee(p);
        _childLaunch(p);
    }

    /// @notice Initial buy (0.05 ETH): exactly 30 bps floored to the Programmable recipient, once.
    function _checkInitialBuyFee(Prepared memory p) internal {
        uint256 initialFee = PLATFORM_RECIPIENT.balance - recipientBeforeLaunch;
        emit log_named_uint("initial buy gross wei", cfg.devBuy);
        emit log_named_uint("initial buy Programmable recipient delta wei", initialFee);
        assertEq(initialFee, cfg.devBuy * ROUTED_FEE_BPS / 10_000, "initial buy fee");
        assertEq(CloverHook(payable(p.accounts[T_HOOK])).platformAccrued(), 0, "no hook platform fee on Genesis");
    }

    function _programmableRoutedSwaps(Prepared memory p) internal {
        PoolKey memory key = p.stampRequest.poolKey;
        CloverHook hook = CloverHook(payable(p.accounts[T_HOOK]));
        CloverToken clover = CloverToken(p.accounts[T_TOKEN]);
        address token = p.accounts[T_TOKEN];
        assertGt(PROGRAMMABLE_SWAP_ROUTER.code.length, 0, "Programmable swap router");
        vm.deal(trader, 10 ether);

        // Buy 1 ETH through the Programmable route.
        uint256 amountIn = 1 ether;
        uint256 fee = amountIn * ROUTED_FEE_BPS / 10_000;
        uint256 r0 = PLATFORM_RECIPIENT.balance;
        uint256 plat0 = hook.platformAccrued();
        uint256 canvas0 = hook.canvasPending(0);
        uint256 creator0 = hook.creatorOwed(launchWallet);
        uint256 t0 = trader.balance;
        {
            bytes[] memory inputs = new bytes[](3);
            inputs[0] = abi.encode(address(0), PLATFORM_RECIPIENT, fee);
            inputs[1] = _v4Input(key, true, uint128(amountIn - fee), address(0), token, 0x0f, address(0));
            inputs[2] = abi.encode(address(0), MSG_SENDER, uint256(0));
            vm.prank(trader);
            IUniversalRouter(PROGRAMMABLE_SWAP_ROUTER).execute{value: amountIn}(hex"051004", inputs, block.timestamp);
        }
        uint256 bought = clover.balanceOf(trader);
        emit log_named_uint("routed buy gross wei", amountIn);
        emit log_named_uint("routed buy Programmable recipient delta wei", PLATFORM_RECIPIENT.balance - r0);
        emit log_named_uint("routed buy hook platformAccrued delta wei", hook.platformAccrued() - plat0);
        emit log_named_uint("routed buy trader ETH spent wei", t0 - trader.balance);
        emit log_named_uint("routed buy CLOVER received", bought);
        assertEq(PLATFORM_RECIPIENT.balance - r0, 0.003 ether, "routed buy: 30 bps once");
        assertEq(hook.platformAccrued(), plat0, "routed buy: no second platform fee");
        assertEq(t0 - trader.balance, amountIn);
        assertGt(bought, 0);
        // 3 % CLOVER fee on the 0.997 ETH that reached the pool: 20 % canvas, 80 % creator.
        uint256 tokenFee = (amountIn - fee) * 30_000 / 1_000_000;
        assertEq(hook.canvasPending(0) - canvas0, tokenFee * 2_000 / 10_000);
        assertEq(hook.creatorOwed(launchWallet) - creator0, tokenFee - tokenFee * 2_000 / 10_000);

        // Sell everything through the Programmable route: fee on the gross ETH output.
        vm.startPrank(trader);
        clover.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(token, PROGRAMMABLE_SWAP_ROUTER, type(uint160).max, uint48(block.timestamp + 1 hours));
        vm.stopPrank();
        r0 = PLATFORM_RECIPIENT.balance;
        plat0 = hook.platformAccrued();
        t0 = trader.balance;
        vm.recordLogs();
        {
            bytes[] memory inputs = new bytes[](3);
            inputs[0] = _v4Input(key, false, uint128(bought), token, address(0), 0x0e, ADDRESS_THIS);
            inputs[1] = abi.encode(address(0), PLATFORM_RECIPIENT, ROUTED_FEE_BPS);
            inputs[2] = abi.encode(address(0), MSG_SENDER, uint256(0));
            vm.prank(trader);
            IUniversalRouter(PROGRAMMABLE_SWAP_ROUTER).execute(hex"100604", inputs, block.timestamp);
        }
        uint256 grossOut = _sellGrossToTaker(vm.getRecordedLogs(), hook);
        uint256 sellFee = PLATFORM_RECIPIENT.balance - r0;
        emit log_named_uint("routed sell CLOVER in", bought);
        emit log_named_uint("routed sell gross ETH output credit wei", grossOut);
        emit log_named_uint("routed sell Programmable recipient delta wei", sellFee);
        emit log_named_uint("routed sell hook platformAccrued delta wei", hook.platformAccrued() - plat0);
        emit log_named_uint("routed sell trader ETH received wei", trader.balance - t0);
        assertEq(clover.balanceOf(trader), 0);
        assertEq(sellFee, grossOut * ROUTED_FEE_BPS / 10_000, "routed sell: 30 bps of gross output once");
        assertEq(trader.balance - t0, grossOut - sellFee);
        assertEq(hook.platformAccrued(), plat0, "routed sell: no second platform fee");
        hook.flush(0);
        assertEq(hook.canvasPending(0), 0);
    }

    /// @dev ETH credited to the router by the pool on the sell = hook FeeTaken gross minus the CLOVER fee.
    function _sellGrossToTaker(Vm.Log[] memory logs, CloverHook hook) internal pure returns (uint256) {
        bytes32 topic = keccak256("FeeTaken(bytes32,address,bool,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) {
                (bool isBuy, uint256 gross, uint256 platform, uint256 tokenFee) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
                require(!isBuy, "sell expected");
                return gross - platform - tokenFee;
            }
        }
        revert("FeeTaken not found");
    }

    /// @notice A trade outside the Programmable route (canonical Uniswap Universal Router) pays the CLOVER fee
    ///         only: neither the route nor the hook charges a platform fee on the Genesis pool.
    function _externalSwapNoSecondFee(Prepared memory p) internal {
        PoolKey memory key = p.stampRequest.poolKey;
        CloverHook hook = CloverHook(payable(p.accounts[T_HOOK]));
        vm.deal(trader, 1 ether);
        uint256 r0 = PLATFORM_RECIPIENT.balance;
        uint256 plat0 = hook.platformAccrued();
        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 0.5 ether}(
            hex"10", _v4ExactInSingle(key, true, 0.5 ether), block.timestamp
        );
        assertEq(PLATFORM_RECIPIENT.balance, r0);
        assertEq(hook.platformAccrued(), plat0);
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
            devBuyMinOut: 0
        });
        vm.prank(trader);
        uint256 g0 = gasleft();
        (uint256 idx, address token, uint256 canvasId) = lp.launchWithCanvas{value: value}(lp_);
        emit log_named_uint("gas child launch", g0 - gasleft());
        assertEq(idx, 1);
        assertEq(canvasId, 1);
        assertGt(CloverToken(token).balanceOf(trader), 0);
        // Child pools are not Programmable launches: the hook charges the 30 bps itself, claimable to the recipient.
        CloverHook hook = CloverHook(payable(p.accounts[T_HOOK]));
        uint256 plat0 = hook.platformAccrued();
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 0.5 ether}(
            hex"10", _v4ExactInSingle(lp.poolKeyOf(token), true, 0.5 ether), block.timestamp
        );
        assertEq(hook.platformAccrued() - plat0, 0.0015 ether);
        uint256 r0 = PLATFORM_RECIPIENT.balance;
        uint256 accrued = hook.platformAccrued();
        hook.claimPlatform();
        assertEq(PLATFORM_RECIPIENT.balance - r0, accrued);
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
