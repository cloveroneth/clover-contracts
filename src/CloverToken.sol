// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ICloverTransferProtection {
    function recordTransfer(address to, uint256 amount) external;
}

/// @title CloverToken
/// @notice Fixed-supply ERC-20 used for $CLOVER and every token of the launchpad.
/// @dev 1_000_000_000 tokens, 18 decimals, minted once to `LAUNCHPAD`.
///      No owner, no mint function, no transfer tax, no blocklist, no pause.
///      Opening protection: when its pool is created, the Launchpad sets `protection` and `protectionEnds` once
///      (launch + 300 s). Until then, every transfer is reported to `protection`, which caps what any
///      non-infrastructure recipient can receive at 2 % of the supply, cumulatively.
contract CloverToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    address public immutable LAUNCHPAD;
    ICloverTransferProtection public protection;
    uint256 public protectionEnds;

    error NotLaunchpad();

    constructor(string memory name_, string memory symbol_, address launchpad_) ERC20(name_, symbol_) {
        LAUNCHPAD = launchpad_;
        _mint(launchpad_, TOTAL_SUPPLY);
    }

    /// @notice Called once by the Launchpad when the pool is created.
    function startProtection(ICloverTransferProtection protection_, uint256 endsAt) external {
        if (msg.sender != LAUNCHPAD || protectionEnds != 0) revert NotLaunchpad();
        protection = protection_;
        protectionEnds = endsAt;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (block.timestamp < protectionEnds && from != address(0)) protection.recordTransfer(to, value);
    }
}
