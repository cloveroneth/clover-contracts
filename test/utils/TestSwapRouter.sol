// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice Minimal router for tests: any direction, exact-in or exact-out, empty hookData.
contract TestSwapRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    /// @notice The account that called `swap`, during the swap (like the v4 periphery routers).
    address public msgSender;

    struct Ctx {
        address payer;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @param amountSpecified negative = exact input, positive = exact output (v4 convention).
    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        external
        payable
        returns (BalanceDelta delta)
    {
        msgSender = msg.sender;
        delta = abi.decode(
            manager.unlock(abi.encode(Ctx(msg.sender, key, zeroForOne, amountSpecified))), (BalanceDelta)
        );
        msgSender = address(0);
        uint256 leftover = address(this).balance;
        if (leftover != 0) {
            (bool ok,) = msg.sender.call{value: leftover}("");
            require(ok, "refund");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "pm");
        Ctx memory c = abi.decode(data, (Ctx));
        BalanceDelta delta = manager.swap(
            c.key,
            IPoolManager.SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: c.amountSpecified,
                sqrtPriceLimitX96: c.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) manager.settle{value: uint256(uint128(-a0))}();
        if (a1 < 0) {
            manager.sync(c.key.currency1);
            IERC20(Currency.unwrap(c.key.currency1)).transferFrom(c.payer, address(manager), uint256(uint128(-a1)));
            manager.settle();
        }
        if (a0 > 0) manager.take(c.key.currency0, c.payer, uint256(uint128(a0)));
        if (a1 > 0) manager.take(c.key.currency1, c.payer, uint256(uint128(a1)));
        return abi.encode(delta);
    }

    receive() external payable {}
}
