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
///         canonical Universal Router with empty hookData. Skipped when ETH_RPC_URL is not set.
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

    address launchWallet = makeAddr("launchWallet");
    address trader = makeAddr("trader");
    bool forked;

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
        c.tokenFeeBps = 500;
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

    function test_fork_launchAndStamp_thenUniversalRouterSwaps() public onlyFork {
        cfg = _config();
        Prepared memory p = prepare(cfg);
        emit log_named_uint("hook salt iterations", p.saltIterations);
        emit log_named_address("hook", p.accounts[T_HOOK]);
        emit log_named_address("CLOVER", p.accounts[T_TOKEN]);

        // Pool must be uninitialized before the Router call.
        (uint160 sqrtBefore,,,) = IPoolManager(POOL_MANAGER).getSlot0(p.stampRequest.poolKey.toId());
        assertEq(sqrtBefore, 0);

        (bytes32 stampHash, Vm.Log[] memory logs) = simulateLaunchWithMockedAuthority(cfg, p);
        assertTrue(stampHash != bytes32(0));

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

        _universalRouterSwaps(p);
        _childLaunch(p);
    }

    function _universalRouterSwaps(Prepared memory p) internal {
        PoolKey memory key = p.stampRequest.poolKey;
        CloverHook hook = CloverHook(payable(p.accounts[T_HOOK]));
        CloverToken pxa = CloverToken(p.accounts[T_TOKEN]);
        vm.deal(trader, 10 ether);

        // Buy: exact input 1 ETH, empty hookData.
        uint256 plat0 = hook.platformAccrued();
        vm.prank(trader);
        uint256 g0 = gasleft();
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 1 ether}(
            hex"10", _v4ExactInSingle(key, true, 1 ether), block.timestamp
        );
        emit log_named_uint("gas UR buy exact-in", g0 - gasleft());
        uint256 bought = pxa.balanceOf(trader);
        assertGt(bought, 0);
        assertEq(hook.platformAccrued() - plat0, 0.003 ether, "30 bps on 1 ETH");
        // 5 % token fee on 1 ETH is pending for the Genesis canvas, and flush funds it.
        assertGe(hook.canvasPending(0), 0.05 ether);
        hook.flush(0);
        assertEq(hook.canvasPending(0), 0);

        // Sell: exact input, Permit2 allowance, empty hookData.
        vm.startPrank(trader);
        pxa.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(pxa), UNIVERSAL_ROUTER, type(uint160).max, uint48(block.timestamp + 1 hours));
        uint256 eth0 = trader.balance;
        g0 = gasleft();
        IUniversalRouter(UNIVERSAL_ROUTER).execute(hex"10", _v4ExactInSingle(key, false, uint128(bought)), block.timestamp);
        emit log_named_uint("gas UR sell exact-in", g0 - gasleft());
        vm.stopPrank();
        assertGt(trader.balance, eth0);
        assertEq(pxa.balanceOf(trader), 0);

        // Platform claim pays the manifest recipient.
        uint256 r0 = PLATFORM_RECIPIENT.balance;
        uint256 accrued = hook.platformAccrued();
        hook.claimPlatform();
        assertEq(PLATFORM_RECIPIENT.balance - r0, accrued);
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
        // Child token can be bought through the Universal Router too.
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 0.5 ether}(
            hex"10", _v4ExactInSingle(lp.poolKeyOf(token), true, 0.5 ether), block.timestamp
        );
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
