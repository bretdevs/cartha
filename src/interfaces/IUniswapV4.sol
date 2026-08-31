// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev ABI-compatible with v4-core's PoolKey (Currency and IHooks are addresses on the wire).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev ABI-compatible with v4-core's SwapParams.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @notice Only the PoolManager functions the harvester needs. `swap` returns the packed
///         BalanceDelta (amount0 in the upper 128 bits, amount1 in the lower 128 bits).
interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

library V4Constants {
    /// @dev TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: the loosest valid price limits.
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;
}
