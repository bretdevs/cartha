// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPonsFactory, IPonsCurve, IPonsFeeEscrow, IPonsMemeHook} from "./interfaces/IPons.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, V4Constants} from "./interfaces/IUniswapV4.sol";

interface ICarthaVaultView {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title CarthaHarvester
/// @notice The creator fee recipient for the CARTHA launch on pons v2. It has no owner.
///
///         Every CARTHA trade on pons pays a fee in ETH. That fee is credited to this contract in the
///         pons fee escrow. `harvest()` is permissionless: it claims the ETH, buys CARTHA (on the curve
///         before graduation, on the Uniswap v4 pool after) and sends the CARTHA straight to the vault.
///         The vault mints nothing for it, so CARTHA per vCARTHA rises.
///
///         Two constants bound what a hostile caller can do with a bad `minCarthaOut`:
///         - maxBuyPerHarvest caps the ETH spent in one call, so a sandwich can only ever act on that much.
///         - cooldown spaces buys out, so the cap is a rate, not a one-off.
///         Anything above the cap simply waits here for the next harvest.
///
///         This contract never holds user deposits. The only value that passes through it is fee ETH
///         in transit. The vault is a separate contract and does not know this one exists.
contract CarthaHarvester is IUnlockCallback {
    IERC20 public immutable still;
    address public immutable vault;
    IPonsFactory public immutable factory;
    IPonsFeeEscrow public immutable escrow;
    IPonsCurve public immutable curve;
    address public immutable hook;
    IPoolManager public immutable poolManager;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    uint256 public immutable maxBuyPerHarvest;
    uint256 public immutable cooldown;

    struct Entry {
        uint40 blockNumber;
        uint40 timestamp;
        uint112 ethSpent;
        uint112 carthaBought;
        uint112 ratioAfter; // CARTHA per 1e18 vCARTHA, after this harvest
    }

    Entry[] private _ledger;
    uint256 public lastBuyAt;
    uint256 public totalEthSpent;
    uint256 public totalCarthaBought;
    uint256 private _entered;

    event Harvest(address indexed caller, uint256 ethSpent, uint256 carthaBought, uint256 ratioAfter);
    event ClaimFailed(uint256 claimable);

    error NotPoolManager();
    error Reentrant();
    error Slippage(uint256 received, uint256 minimum);
    error NativePairOnly();
    error UnknownLaunch();

    constructor(
        address still_,
        address vault_,
        address factory_,
        address escrow_,
        address hook_,
        address poolManager_,
        uint256 maxBuyPerHarvest_,
        uint256 cooldown_
    ) {
        IPonsFactory.LaunchedToken memory launch = IPonsFactory(factory_).getLaunchedToken(still_);
        if (!launch.exists) revert UnknownLaunch();
        if (launch.pairToken != address(0)) revert NativePairOnly();

        still = IERC20(still_);
        vault = vault_;
        factory = IPonsFactory(factory_);
        escrow = IPonsFeeEscrow(escrow_);
        curve = IPonsCurve(launch.curve);
        hook = hook_;
        poolManager = IPoolManager(poolManager_);
        poolFee = launch.poolFee;
        tickSpacing = launch.tickSpacing;
        maxBuyPerHarvest = maxBuyPerHarvest_;
        cooldown = cooldown_;
    }

    /// @dev Escrow claims, curve refunds and unspent swap input all arrive here.
    receive() external payable {}

    // ---------------------------------------------------------------- views

    /// @notice ETH owed to this contract in the escrow, and ETH already sitting here.
    function pending() external view returns (uint256 claimable, uint256 held) {
        claimable = escrow.balanceOf(address(this));
        held = address(this).balance;
    }

    function canBuy() public view returns (bool) {
        return block.timestamp >= lastBuyAt + cooldown;
    }

    /// @notice Current pons phase for CARTHA: 0 curve, 1 swept, 2 pool, 3 rescued.
    function phase() public view returns (uint8) {
        return factory.getLaunchedToken(address(still)).phase;
    }

    /// @notice The graduated pool key. ETH is the zero address, so it is always currency0.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({currency0: address(0), currency1: address(still), fee: poolFee, tickSpacing: tickSpacing, hooks: hook});
    }

    function poolId() public view returns (bytes32) {
        return keccak256(abi.encode(poolKey()));
    }

    function ledgerLength() external view returns (uint256) {
        return _ledger.length;
    }

    /// @notice The last `n` harvests, newest first. One call for the site.
    function recent(uint256 n) external view returns (Entry[] memory out) {
        uint256 len = _ledger.length;
        if (n > len) n = len;
        out = new Entry[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _ledger[len - 1 - i];
        }
    }

    // -------------------------------------------------------------- harvest

    /// @notice Sweep and claim what is owed, then buy up to `maxBuyPerHarvest` of CARTHA into the vault.
    /// @param minCarthaOut Minimum CARTHA the buy must return. Keepers compute this from a quote.
    /// @return ethSpent ETH actually spent on the buy (0 if the cooldown has not passed or nothing is held).
    /// @return carthaBought CARTHA delivered to the vault.
    function harvest(uint256 minCarthaOut) external returns (uint256 ethSpent, uint256 carthaBought) {
        if (_entered == 1) revert Reentrant();
        _entered = 1;

        _sweepAndClaim();

        uint256 held = address(this).balance;
        if (held > 0 && canBuy()) {
            uint256 budget = held > maxBuyPerHarvest ? maxBuyPerHarvest : held;
            uint8 p = phase();
            if (p == 0) {
                (ethSpent, carthaBought) = _buyOnCurve(budget, minCarthaOut);
            } else if (p == 2) {
                (ethSpent, carthaBought) = _buyOnPool(budget, minCarthaOut);
            }
            // phase 1 (swept, pool not yet created) and 3 (rescued): nothing to buy from. ETH waits.

            if (carthaBought > 0) {
                lastBuyAt = block.timestamp;
                totalEthSpent += ethSpent;
                totalCarthaBought += carthaBought;
                uint256 ratio = ICarthaVaultView(vault).convertToAssets(1e18);
                _ledger.push(
                    Entry({
                        blockNumber: uint40(block.number),
                        timestamp: uint40(block.timestamp),
                        ethSpent: uint112(ethSpent),
                        carthaBought: uint112(carthaBought),
                        ratioAfter: uint112(ratio)
                    })
                );
                emit Harvest(msg.sender, ethSpent, carthaBought, ratio);
            }
        }

        _entered = 0;
    }

    /// @dev Move fees from the curve or the hook into the escrow where pons lets us, then claim.
    ///      Sweeps that need an internal swap are operator-only on pons' side and revert for us;
    ///      those fees reach the escrow when pons sweeps. Every call here is best effort.
    function _sweepAndClaim() internal {
        uint8 p = phase();
        if (p == 0) {
            try curve.sweepFees(0) {} catch {}
        } else if (p == 2) {
            try IPonsMemeHook(hook).sweepPoolFees(poolId(), 0, 0) {} catch {}
        }

        uint256 claimable = escrow.balanceOf(address(this));
        if (claimable > 0) {
            try escrow.claim() {}
            catch {
                emit ClaimFailed(claimable);
            }
        }
    }

    function _buyOnCurve(uint256 budget, uint256 minCarthaOut) internal returns (uint256 ethSpent, uint256 carthaBought) {
        uint256 before = address(this).balance;
        carthaBought = curve.buy{value: budget}(budget, minCarthaOut, vault);
        // A buy that crosses the curve's reserved allocation is clamped and the difference refunded.
        ethSpent = before - address(this).balance;
    }

    function _buyOnPool(uint256 budget, uint256 minCarthaOut) internal returns (uint256 ethSpent, uint256 carthaBought) {
        bytes memory result = poolManager.unlock(abi.encode(budget, minCarthaOut));
        (ethSpent, carthaBought) = abi.decode(result, (uint256, uint256));
    }

    /// @dev Called back by the PoolManager inside `unlock`. Exact-input swap, ETH in, CARTHA out,
    ///      CARTHA taken directly to the vault.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 budget, uint256 minCarthaOut) = abi.decode(data, (uint256, uint256));

        int256 delta = poolManager.swap(
            poolKey(),
            SwapParams({zeroForOne: true, amountSpecified: -int256(budget), sqrtPriceLimitX96: V4Constants.MIN_SQRT_PRICE_LIMIT}),
            ""
        );

        // BalanceDelta packs amount0 in the upper 128 bits and amount1 in the lower 128 bits.
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        uint256 owed = amount0 < 0 ? uint256(uint128(-amount0)) : 0;
        uint256 received = amount1 > 0 ? uint256(uint128(amount1)) : 0;
        if (received < minCarthaOut) revert Slippage(received, minCarthaOut);

        poolManager.settle{value: owed}();
        poolManager.take(address(still), vault, received);

        return abi.encode(owed, received);
    }
}
