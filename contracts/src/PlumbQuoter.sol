// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {ICLPool} from "./interfaces/IMezoCL.sol";

/// @title PlumbQuoter
/// @notice Prices a sale against a concentrated pool by running the real swap and reverting.
///         It is meant to be called with eth_call, optionally without being deployed (the
///         caller passes this contract's bytecode as a state override), and at any block, so
///         anyone can recompute "what would selling N MUSD have paid at block B".
contract PlumbQuoter {
    error Quote(int256 amount0, int256 amount1, int24 tickAfter);
    error NotPool();

    address private _expectedPool;

    /// @notice Output for selling `amountIn` of one side of `pool`.
    /// @param zeroForOne true to sell token0 for token1
    /// @return amountOut tokens the seller would receive
    /// @return tickAfter pool tick after the sale
    function quoteExactIn(ICLPool pool, bool zeroForOne, uint256 amountIn)
        public
        returns (uint256 amountOut, int24 tickAfter)
    {
        _expectedPool = address(pool);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        try pool.swap(address(this), zeroForOne, int256(amountIn), limit, "") {
            revert("quote: swap did not revert");
        } catch (bytes memory reason) {
            if (reason.length != 100 || bytes4(reason) != Quote.selector) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
            int256 a0;
            int256 a1;
            assembly {
                a0 := mload(add(reason, 36))
                a1 := mload(add(reason, 68))
                tickAfter := mload(add(reason, 100))
            }
            amountOut = uint256(-(zeroForOne ? a1 : a0));
        }
    }

    /// @notice Quotes several sizes in one call, for a depth curve.
    function quoteCurve(ICLPool pool, bool zeroForOne, uint256[] calldata sizes)
        external
        returns (uint256[] memory outs)
    {
        outs = new uint256[](sizes.length);
        for (uint256 i; i < sizes.length; i++) {
            (outs[i],) = quoteExactIn(pool, zeroForOne, sizes[i]);
        }
    }

    /// @dev Slipstream calls this mid-swap. Reverting here undoes the swap and carries the amounts out.
    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external view {
        if (msg.sender != _expectedPool) revert NotPool();
        // The pool writes its new price before calling back, so slot0 already shows the result.
        (, int24 tickAfter,,,,) = ICLPool(msg.sender).slot0();
        revert Quote(amount0, amount1, tickAfter);
    }
}
