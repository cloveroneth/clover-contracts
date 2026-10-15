// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {
    IProgrammableCreate2GraphDeployerV1 as IGraph,
    IProgrammableLaunchStampRouterV1 as IRouter
} from "../src/interfaces/programmable/IProgrammableLaunchStampRouterV1.sol";
import {CloverHook} from "../src/CloverHook.sol";
import {CloverCanvas} from "../src/CloverCanvas.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {CloverToken} from "../src/CloverToken.sol";

/// @title CloverGraph
/// @notice Builds the CLOVER CustomGraph for ProgrammableLaunchStampRouterV1.launchAndStampV1.
/// @dev Never signs and never broadcasts. Every address is read from the Router passed in `Config`
///      (which the caller takes from the live manifest), then derived with the Graph Factory's own view
///      functions (`effectiveTargetSalt`, `predictTarget`, `computeGraphCommitment`).
abstract contract CloverGraph {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint160 internal constant HOOK_FLAGS = 0x28CC;
    uint160 internal constant FLAG_MASK = 0x3FFF;
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;

    uint8 internal constant T_HOOK = 0;
    uint8 internal constant T_CANVAS = 1;
    uint8 internal constant T_LAUNCHPAD = 2;
    uint8 internal constant T_TOKEN = 3;
    uint256 internal constant N_TARGETS = 4;

    struct Config {
        IRouter router;
        address launchWallet;
        address platformRecipient;
        address protocolRecipient;
        bytes32 routeNamespace;
        bytes32 nonce;
        bytes32 launchId;
        uint64 validAfter;
        uint64 deadline;
        string name;
        string symbol;
        uint16 tokenFeeBps;
        uint16 genesisCanvasShareBps;
        uint8 genesisSize;
        uint16 genesisRentBps;
        uint32 genesisFadeTime;
        uint96 genesisStartPrice;
        uint256 devBuy;
        uint256 maxSaltIterations;
    }

    struct Prepared {
        IGraph factory;
        IPoolManager poolManager;
        IGraph.GraphAuthorization authorization;
        IGraph.Target[] targets;
        address[] accounts;
        bytes32[] runtimeCodeHashes;
        bytes32 graphDeploymentHash;
        IRouter.CustomGraphRouteV1 route;
        bytes routePayload;
        IRouter.StampRequestV1 stampRequest;
        IRouter.LaunchPermitV1 permit;
        bytes32 permitDigest;
        bytes32 hookApplicantSalt;
        uint256 saltIterations;
    }

    function targetIdHash(uint8 index) internal pure returns (bytes32) {
        if (index == T_HOOK) return keccak256("clover.v1.CloverHook");
        if (index == T_CANVAS) return keccak256("clover.v1.CloverCanvas");
        if (index == T_LAUNCHPAD) return keccak256("clover.v1.Launchpad");
        return keccak256("clover.v1.CloverToken");
    }

    /// @dev Commits to the constructor dependency order and the initializer order.
    function topologyHash() internal pure returns (bytes32) {
        return keccak256(
            "clover.v1.topology:"
            "ctor[0:CloverHook(poolManager,platformRecipient)]"
            "ctor[1:CloverCanvas(protocolRecipient)]"
            "ctor[2:Launchpad(poolManager,0,1,genesis)]"
            "ctor[3:CloverToken(name,symbol,2)]"
            "init[0.initialize(2,1)]"
            "init[1.initialize(2,0)]"
            "init[2.genesis(3)]"
        );
    }

    // ------------------------------------------------------------------ build

    function buildTargets(Config memory c, Prepared memory p) internal view {
        p.factory = IGraph(c.router.GRAPH_FACTORY());
        p.poolManager = IPoolManager(c.router.POOL_MANAGER());
        p.authorization = IGraph.GraphAuthorization({
            routeNamespace: c.routeNamespace,
            routeNonce: c.nonce,
            topologyHash: topologyHash(),
            graphCommitment: bytes32(0),
            authorizedLauncher: address(c.router),
            totalValue: c.devBuy
        });
        p.targets = new IGraph.Target[](N_TARGETS);
        p.accounts = new address[](N_TARGETS);

        // 0. Hook: init code depends on no project address, so its salt is mined once.
        bytes memory hookInit =
            abi.encodePacked(type(CloverHook).creationCode, abi.encode(p.poolManager, c.platformRecipient));
        (p.hookApplicantSalt, p.saltIterations, p.accounts[T_HOOK]) =
            mineHookSalt(p.factory, p.authorization, targetIdHash(T_HOOK), keccak256(hookInit), c.maxSaltIterations);
        p.targets[T_HOOK] = _target(T_HOOK, p.hookApplicantSalt, hookInit);

        // 1. Canvas(protocolRecipient)
        p.targets[T_CANVAS] =
            _target(T_CANVAS, bytes32(0), abi.encodePacked(type(CloverCanvas).creationCode, abi.encode(c.protocolRecipient)));
        p.accounts[T_CANVAS] = p.factory.predictTarget(p.authorization, p.targets[T_CANVAS]);

        // 2. Launchpad(poolManager, hook, canvas, genesis params)
        p.targets[T_LAUNCHPAD] = _target(T_LAUNCHPAD, bytes32(0), _launchpadInit(c, p));
        p.accounts[T_LAUNCHPAD] = p.factory.predictTarget(p.authorization, p.targets[T_LAUNCHPAD]);

        // 3. CloverToken(name, symbol, launchpad)
        p.targets[T_TOKEN] = _target(
            T_TOKEN,
            bytes32(0),
            abi.encodePacked(type(CloverToken).creationCode, abi.encode(c.name, c.symbol, p.accounts[T_LAUNCHPAD]))
        );
        p.accounts[T_TOKEN] = p.factory.predictTarget(p.authorization, p.targets[T_TOKEN]);

        // Initializers (executed in target order after every constructor).
        p.targets[T_HOOK].initializerCalldata =
            abi.encodeCall(CloverHook.initialize, (p.accounts[T_LAUNCHPAD], CloverCanvas(p.accounts[T_CANVAS])));
        p.targets[T_CANVAS].initializerCalldata =
            abi.encodeCall(CloverCanvas.initialize, (p.accounts[T_LAUNCHPAD], p.accounts[T_HOOK]));
        p.targets[T_LAUNCHPAD].initializerCalldata =
            abi.encodeCall(Launchpad.genesis, (CloverToken(p.accounts[T_TOKEN])));
        p.targets[T_LAUNCHPAD].initializerValue = c.devBuy;

        (bytes32 commitment, uint256 valueSum) = p.factory.computeGraphCommitment(p.authorization, p.targets);
        require(valueSum == p.authorization.totalValue, "value sum");
        p.authorization.graphCommitment = commitment;
    }

    function _launchpadInit(Config memory c, Prepared memory p) private pure returns (bytes memory) {
        return abi.encodePacked(
            type(Launchpad).creationCode,
            abi.encode(
                p.poolManager,
                p.accounts[T_HOOK],
                p.accounts[T_CANVAS],
                c.launchWallet,
                c.tokenFeeBps,
                c.genesisCanvasShareBps,
                c.genesisSize,
                c.genesisRentBps,
                c.genesisFadeTime,
                c.genesisStartPrice
            )
        );
    }

    function _target(uint8 index, bytes32 salt, bytes memory initCode) private pure returns (IGraph.Target memory) {
        return IGraph.Target({
            targetIdHash: targetIdHash(index),
            applicantSalt: salt,
            deploymentValue: 0,
            initializerValue: 0,
            initCode: initCode,
            initializerCalldata: ""
        });
    }

    /// @notice Mines `applicantSalt` so the hook address carries exactly the 0x28CC permission bits.
    /// @dev Effective salt formula of ProgrammableCreate2GraphDeployerV1.effectiveTargetSalt, recomputed locally
    ///      and cross-checked against the factory once found.
    function mineHookSalt(
        IGraph factory,
        IGraph.GraphAuthorization memory auth,
        bytes32 idHash,
        bytes32 initCodeHash,
        uint256 maxIterations
    ) internal view returns (bytes32 salt, uint256 iterations, address account) {
        // Two buffers reused across iterations so the loop does not grow memory:
        // [typehash | chainId | factory | namespace | nonce | idHash | salt | launcher] and
        // [0xff | factory | effective salt | initCodeHash].
        bytes memory buf = _saltBuffer(factory, auth, idHash);
        bytes memory c2 = abi.encodePacked(bytes1(0xff), address(factory), bytes32(0), initCodeHash);
        bytes32 effective;
        for (uint256 i; i < maxIterations; ++i) {
            assembly ("memory-safe") {
                mstore(add(buf, 0xe0), i) // applicantSalt is the 7th word
                effective := keccak256(add(buf, 0x20), mload(buf))
                mstore(add(c2, 0x35), effective)
                account := and(keccak256(add(c2, 0x20), 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
            }
            if (uint160(account) & FLAG_MASK == HOOK_FLAGS && account.code.length == 0) {
                salt = bytes32(i);
                iterations = i + 1;
                break;
            }
        }
        require(iterations != 0, "hook salt not found");
        require(factory.effectiveTargetSalt(auth, idHash, salt) == effective, "salt formula mismatch");
    }

    function _saltBuffer(IGraph factory, IGraph.GraphAuthorization memory auth, bytes32 idHash)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(
            keccak256(
                "ProgrammableCreate2GraphTargetSaltV1(uint256 chainId,address factory,bytes32 routeNamespace,bytes32 routeNonce,bytes32 targetIdHash,bytes32 applicantSalt,address authorizedLauncher)"
            ),
            block.chainid,
            address(factory),
            auth.routeNamespace,
            auth.routeNonce,
            idHash,
            bytes32(0),
            auth.authorizedLauncher
        );
    }

    function _create2(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    // ------------------------------------------------------------------ simulation

    /// @notice Runs the exact graph through the factory as the Router would, on a state snapshot, to obtain
    ///         post-initialization runtime code hashes and the graph deployment hash. State is reverted.
    function simulateGraph(Config memory c, Prepared memory p) internal {
        uint256 snap = VM.snapshotState();
        VM.deal(address(c.router), p.authorization.totalValue);
        VM.prank(address(c.router));
        (address[] memory deployments, bytes32[] memory hashes,, bytes32 graphHash) =
            p.factory.deployGraph{value: p.authorization.totalValue}(p.authorization, p.targets);
        for (uint256 i; i < N_TARGETS; ++i) {
            require(deployments[i] == p.accounts[i], "predicted address mismatch");
        }
        p.runtimeCodeHashes = hashes;
        p.graphDeploymentHash = graphHash;
        VM.revertToState(snap);
    }

    function assemble(Config memory c, Prepared memory p) internal view {
        IRouter.ExpectedGraphOutputV1[] memory outputs = new IRouter.ExpectedGraphOutputV1[](N_TARGETS);
        for (uint8 i; i < N_TARGETS; ++i) {
            outputs[i] = IRouter.ExpectedGraphOutputV1({
                targetIndex: i,
                targetIdHash: targetIdHash(i),
                account: p.accounts[i],
                runtimeCodeHash: p.runtimeCodeHashes[i]
            });
        }
        p.route = IRouter.CustomGraphRouteV1({
            routeNamespace: c.routeNamespace,
            routeNonce: c.nonce,
            topologyHash: p.authorization.topologyHash,
            graphCommitment: p.authorization.graphCommitment,
            targets: p.targets,
            expectedOutputs: outputs,
            expectedGraphDeploymentHash: p.graphDeploymentHash
        });
        p.routePayload = abi.encode(p.route);

        p.stampRequest.launchId = c.launchId;
        p.stampRequest.token = p.accounts[T_TOKEN];
        p.stampRequest.tokenRuntimeCodeHash = p.runtimeCodeHashes[T_TOKEN];
        p.stampRequest.poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(p.accounts[T_TOKEN]),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(p.accounts[T_HOOK])
        });
        p.stampRequest.hookRuntimeCodeHash = p.runtimeCodeHashes[T_HOOK];
        p.stampRequest.components = _sortedComponents(p);

        p.permit = IRouter.LaunchPermitV1({
            chainId: 1,
            router: address(c.router),
            launchWallet: c.launchWallet,
            kind: IRouter.LaunchKindV1.CustomGraph,
            routePayloadHash: keccak256(p.routePayload),
            expectedResultHash: expectedResultHash(outputs, p.graphDeploymentHash),
            stampRequestHash: c.router.computeStampRequestHash(p.stampRequest),
            nonce: c.nonce,
            validAfter: c.validAfter,
            deadline: c.deadline,
            value: p.authorization.totalValue
        });
        require(c.deadline > c.validAfter && c.deadline - c.validAfter <= 1 hours, "permit window");
        p.permitDigest = c.router.permitDigest(p.permit);
    }

    function _sortedComponents(Prepared memory p) private pure returns (IRouter.ComponentV1[] memory comps) {
        comps = new IRouter.ComponentV1[](N_TARGETS);
        for (uint8 i; i < N_TARGETS; ++i) {
            IRouter.ComponentKindV1 kind = i == T_TOKEN
                ? IRouter.ComponentKindV1.Token
                : (i == T_HOOK ? IRouter.ComponentKindV1.Hook : IRouter.ComponentKindV1.Other);
            comps[i] = IRouter.ComponentV1({
                resultIndex: i,
                account: p.accounts[i],
                runtimeCodeHash: p.runtimeCodeHashes[i],
                kind: kind,
                scope: IRouter.ComponentScopeV1.Exclusive
            });
        }
        // Insertion sort by increasing address.
        for (uint256 i = 1; i < N_TARGETS; ++i) {
            IRouter.ComponentV1 memory x = comps[i];
            uint256 j = i;
            while (j > 0 && comps[j - 1].account > x.account) {
                comps[j] = comps[j - 1];
                --j;
            }
            comps[j] = x;
        }
    }

    /// @dev Router `_expectedGraphResultHash`, recomputed from the pinned source.
    function expectedResultHash(IRouter.ExpectedGraphOutputV1[] memory outputs, bytes32 graphHash)
        internal
        pure
        returns (bytes32)
    {
        bytes32 outputTypeHash = keccak256(
            "ProgrammableExpectedGraphOutputV1(uint8 targetIndex,bytes32 targetIdHash,address account,bytes32 runtimeCodeHash)"
        );
        bytes32[] memory hashes = new bytes32[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(
                    outputTypeHash, outputs[i].targetIndex, outputs[i].targetIdHash, outputs[i].account, outputs[i].runtimeCodeHash
                )
            );
        }
        return keccak256(
            abi.encode(
                keccak256("ProgrammableExpectedGraphResultV1(bytes32 expectedOutputsHash,bytes32 graphDeploymentHash)"),
                keccak256(abi.encodePacked(hashes)),
                graphHash
            )
        );
    }

    /// @notice Full pipeline: targets, salt mining, graph simulation, route, stamp request, permit.
    function prepare(Config memory c) internal returns (Prepared memory p) {
        buildTargets(c, p);
        simulateGraph(c, p);
        assemble(c, p);
    }

    /// @notice Fork simulation of the complete authorized transaction. The Programmable EIP-1271 authority is
    ///         mocked to accept the digest; the real authorization must come from Programmable.
    function simulateLaunchWithMockedAuthority(Config memory c, Prepared memory p)
        internal
        returns (bytes32 stampHash, Vm.Log[] memory logs)
    {
        address authority = c.router.PERMIT_AUTHORITY();
        VM.mockCall(
            authority,
            abi.encodeWithSelector(ERC1271_MAGIC, p.permitDigest, hex"01"),
            abi.encode(ERC1271_MAGIC)
        );
        VM.warp(c.validAfter + 1);
        VM.deal(c.launchWallet, c.launchWallet.balance + p.permit.value);
        VM.recordLogs();
        VM.prank(c.launchWallet);
        stampHash = c.router.launchAndStampV1{value: p.permit.value}(p.permit, p.stampRequest, p.routePayload, hex"01");
        logs = VM.getRecordedLogs();
        VM.clearMockedCalls();
    }
}
