// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CloverToken
/// @notice Fixed-supply ERC-20 used for $CLOVER and every token of the launchpad.
/// @dev 1_000_000_000 tokens, 18 decimals, minted once to `recipient` (the Launchpad).
///      No owner, no mint function, no transfer tax, no blocklist, no pause.
contract CloverToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor(string memory name_, string memory symbol_, address recipient) ERC20(name_, symbol_) {
        _mint(recipient, TOTAL_SUPPLY);
    }
}
