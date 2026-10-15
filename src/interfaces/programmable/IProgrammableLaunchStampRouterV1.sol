// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Tuple definitions copied from programmablehq/PROGRAMMABLE at commit
///         0a7134bbb912222639627fb9078df2f8dd3a6c38 (pinned by the live manifest `launchStampRouter.artifact`),
///         files src/interfaces/IProgrammableCreate2GraphDeployerV1.sol and IProgrammableLaunchStampRouterV1.sol.
///         Only the CustomGraph surface is kept; tuple layouts are unchanged.
interface IProgrammableCreate2GraphDeployerV1 {
    struct GraphAuthorization {
        bytes32 routeNamespace;
        bytes32 routeNonce;
        bytes32 topologyHash;
        bytes32 graphCommitment;
        address authorizedLauncher;
        uint256 totalValue;
    }

    struct Target {
        bytes32 targetIdHash;
        bytes32 applicantSalt;
        uint256 deploymentValue;
        uint256 initializerValue;
        bytes initCode;
        bytes initializerCalldata;
    }

    function deployGraph(GraphAuthorization calldata authorization, Target[] calldata targets)
        external
        payable
        returns (
            address[] memory deployments,
            bytes32[] memory runtimeCodeHashes,
            bytes[] memory runtimeCodes,
            bytes32 graphDeploymentHash
        );

    function computeGraphCommitment(GraphAuthorization calldata authorization, Target[] calldata targets)
        external
        view
        returns (bytes32 commitment, uint256 targetValueSum);

    function effectiveTargetSalt(GraphAuthorization calldata authorization, bytes32 targetIdHash, bytes32 applicantSalt)
        external
        view
        returns (bytes32);

    function predictTarget(GraphAuthorization calldata authorization, Target calldata target)
        external
        view
        returns (address);
}

interface IProgrammableLaunchStampRouterV1 {
    enum LaunchKindV1 {
        Invalid,
        CustomGraph,
        Classic
    }

    enum ComponentKindV1 {
        Other,
        Token,
        Hook
    }

    enum ComponentScopeV1 {
        Invalid,
        Exclusive,
        SharedInfrastructure
    }

    struct ExpectedGraphOutputV1 {
        uint8 targetIndex;
        bytes32 targetIdHash;
        address account;
        bytes32 runtimeCodeHash;
    }

    struct CustomGraphRouteV1 {
        bytes32 routeNamespace;
        bytes32 routeNonce;
        bytes32 topologyHash;
        bytes32 graphCommitment;
        IProgrammableCreate2GraphDeployerV1.Target[] targets;
        ExpectedGraphOutputV1[] expectedOutputs;
        bytes32 expectedGraphDeploymentHash;
    }

    struct ComponentV1 {
        uint8 resultIndex;
        address account;
        bytes32 runtimeCodeHash;
        ComponentKindV1 kind;
        ComponentScopeV1 scope;
    }

    struct StampRequestV1 {
        bytes32 launchId;
        address token;
        bytes32 tokenRuntimeCodeHash;
        PoolKey poolKey;
        bytes32 hookRuntimeCodeHash;
        ComponentV1[] components;
    }

    struct LaunchPermitV1 {
        uint256 chainId;
        address router;
        address launchWallet;
        LaunchKindV1 kind;
        bytes32 routePayloadHash;
        bytes32 expectedResultHash;
        bytes32 stampRequestHash;
        bytes32 nonce;
        uint64 validAfter;
        uint64 deadline;
        uint256 value;
    }

    struct StampRecordV1 {
        LaunchKindV1 kind;
        address launchWallet;
        address token;
        address hook;
        address poolManager;
        bytes32 poolId;
        bytes32 poolKeyHash;
        bytes32 componentSetHash;
        bytes32 routePayloadHash;
        address routeLauncher;
        bytes32 routeLauncherRuntimeCodeHash;
        bytes32 expectedResultHash;
        bytes32 permitDigest;
        bytes32 stampHash;
    }

    event ProgrammableLaunchStampedV1(
        bytes32 indexed launchId,
        address indexed token,
        address indexed hook,
        address poolManager,
        bytes32 poolId,
        bytes32 stampHash
    );

    event ProgrammableLaunchRouteStampedV1(
        bytes32 indexed launchId,
        LaunchKindV1 indexed kind,
        bytes32 indexed routePayloadHash,
        bytes32 expectedResultHash,
        bytes32 permitDigest
    );

    event ProgrammableComponentStampedV1(
        bytes32 indexed launchId, address indexed component, ComponentKindV1 indexed kind, bytes32 runtimeCodeHash
    );

    function launchAndStampV1(
        LaunchPermitV1 calldata permit,
        StampRequestV1 calldata stampRequest,
        bytes calldata routePayload,
        bytes calldata signature
    ) external payable returns (bytes32 stampHash);

    function launchStamp(bytes32 launchId) external view returns (StampRecordV1 memory);
    function launchIdByToken(address token) external view returns (bytes32);
    function launchIdByPool(address poolManager, bytes32 poolId) external view returns (bytes32);
    function stampProof(address component) external view returns (bytes32 launchId, bytes32 stampHash);
    function computeStampRequestHash(StampRequestV1 calldata request) external pure returns (bytes32);
    function permitDigest(LaunchPermitV1 calldata permit) external view returns (bytes32);

    function CHAIN_ID() external view returns (uint256);
    function PERMIT_AUTHORITY() external view returns (address);
    function PERMIT_AUTHORITY_RUNTIME_CODE_HASH() external view returns (bytes32);
    function GRAPH_FACTORY() external view returns (address);
    function GRAPH_FACTORY_RUNTIME_CODE_HASH() external view returns (bytes32);
    function POOL_MANAGER() external view returns (address);
    function POOL_MANAGER_RUNTIME_CODE_HASH() external view returns (bytes32);
}
