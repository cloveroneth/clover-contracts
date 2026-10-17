// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Chainlink-like ETH / USD feed for local tests, deployed at the mainnet feed address.
contract MockEthUsdFeed {
    int256 public answer = 2_400e8;
    /// @dev 0: report `block.timestamp` (always fresh).
    uint256 public updatedAt;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 t = updatedAt == 0 ? block.timestamp : updatedAt;
        return (1, answer, t, t, 1);
    }
}
