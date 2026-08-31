// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title CarthaVault (vCARTHA)
/// @notice OpenZeppelin's ERC-4626, with a name. There is no other code.
///
///         - totalAssets() is this contract's CARTHA balance. CARTHA sent here by the harvester
///           (or anyone) raises what every existing share redeems for. No shares are minted for it.
///         - No owner, no pause, no upgrade, no fee switch, no hooks, no rebase, no queue.
///         - Rounding always favours the vault, so CARTHA per vCARTHA can never decrease.
///
///         Inflation-attack defence is a deploy-time seed: the deployer deposits CARTHA and sends the
///         resulting vCARTHA to 0x...dEaD, so the share supply is never tiny. See test/CarthaVault.t.sol.
contract CarthaVault is ERC4626, ERC20Permit {
    constructor(IERC20 still)
        ERC20("Cartha Vault Share", "vCARTHA")
        ERC20Permit("Cartha Vault Share")
        ERC4626(still)
    {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}
