// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICloverHookCreator {
    function tokenConfig(uint256 tokenIndex)
        external
        view
        returns (address creator, uint32 canvasId, uint16 canvasShareBps, uint64 lastDecrease);
}

/// @title CloverOpeningTaxVault
/// @notice Holds the opening buy tax (the part of an early buy fee above the pool's normal rate), apart from the
///         platform fee vault and from the creator / canvas fee balances of the hook.
/// @dev The hook `take`s the tax in native ETH from the PoolManager to this vault, then `record`s it; `record`
///      reverts unless the ETH balance backs everything recorded and unclaimed. `claim` is permissionless and pays
///      the token creator fixed at launch. No owner, no other withdrawal.
contract CloverOpeningTaxVault {
    address public immutable hook;
    address public immutable poolManager;

    mapping(uint256 tokenIndex => uint256) public accrued;
    uint256 public totalAccrued;

    event TaxRecorded(uint256 indexed tokenIndex, uint256 amount);
    event TaxClaimed(uint256 indexed tokenIndex, address indexed creator, uint256 amount);

    error NotHook();
    error NotPoolManager();
    error Unbacked();
    error TransferFailed();

    constructor(address poolManager_) {
        hook = msg.sender;
        poolManager = poolManager_;
    }

    function record(uint256 tokenIndex, uint256 amount) external {
        if (msg.sender != hook) revert NotHook();
        accrued[tokenIndex] += amount;
        totalAccrued += amount;
        if (address(this).balance < totalAccrued) revert Unbacked();
        emit TaxRecorded(tokenIndex, amount);
    }

    /// @notice Pays a token's accrued opening tax to its creator.
    function claim(uint256 tokenIndex) external returns (uint256 amount) {
        amount = accrued[tokenIndex];
        if (amount == 0) return 0;
        accrued[tokenIndex] = 0;
        totalAccrued -= amount;
        (address creator,,,) = ICloverHookCreator(hook).tokenConfig(tokenIndex);
        emit TaxClaimed(tokenIndex, creator, amount);
        (bool ok,) = creator.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Accepts ETH only from the PoolManager (`take`).
    receive() external payable {
        if (msg.sender != poolManager) revert NotPoolManager();
    }
}
