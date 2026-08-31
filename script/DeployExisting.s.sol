// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CarthaVault} from "../src/CarthaVault.sol";
import {CarthaHarvester} from "../src/CarthaHarvester.sol";
import {IPonsFactory, IPonsCurve} from "../src/interfaces/IPons.sol";

/// @notice Deploy the vault and harvester for a CARTHA token that was already
///         launched on pons (through the pons website or otherwise), instead of
///         launching from this script.
///
///         Flow:
///           1. Read the launch record for TOKEN from the pons factory. Reverts if the
///              launch does not exist, is not a native-ETH pair, or has a zero creator
///              tax (the vault's yield depends on it and it cannot be raised later).
///           2. Deploy CarthaVault and CarthaHarvester against it.
///           3. If the broadcasting wallet is the current creator fee recipient (i.e.
///              the wallet that launched), transferCreatorFeeRecipient to the
///              harvester. Otherwise, print the exact call the launch wallet must make.
///           4. Seed the vault (mandatory, audit L-01): buy on the curve, deposit,
///              park the shares at 0x...dEaD.
///
///         Env, on top of .env: TOKEN (the launched CARTHA address). PRIVATE_KEY pays
///         gas and the seed; use the launch wallet's key to get step 3 done in the
///         same run.
contract DeployExisting is Script {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Cfg {
        uint256 pk;
        address deployer;
        address token;
        IPonsFactory factory;
        address escrow;
        address hook;
        address poolManager;
        uint256 maxBuy;
        uint256 cooldown;
        uint256 seedEth;
        uint256 seedCartha;
    }

    struct Out {
        address vault;
        address harvester;
        bool feesWired;
        uint256 seeded;
    }

    function run() external {
        Cfg memory c = _config();
        IPonsFactory.LaunchedToken memory launch = c.factory.getLaunchedToken(c.token);
        _validate(c, launch);

        Out memory o;
        vm.startBroadcast(c.pk);
        o.vault = address(new CarthaVault(IERC20(c.token)));
        o.harvester = address(
            new CarthaHarvester(c.token, o.vault, address(c.factory), c.escrow, c.hook, c.poolManager, c.maxBuy, c.cooldown)
        );
        if (launch.creatorFeeRecipient == c.deployer) {
            // From here on, fees can only go to the harvester. It has no way to point them anywhere else.
            c.factory.transferCreatorFeeRecipient(c.token, o.harvester);
            o.feesWired = true;
        }
        o.seeded = _seed(c, launch, o.vault);
        vm.stopBroadcast();

        _log(c, launch, o);
        _record(c, launch, o);
    }

    function _config() internal view returns (Cfg memory c) {
        c.pk = vm.envUint("PRIVATE_KEY");
        c.deployer = vm.addr(c.pk);
        c.token = vm.envAddress("TOKEN");
        c.factory = IPonsFactory(vm.envAddress("PONS_FACTORY"));
        c.escrow = vm.envAddress("PONS_ESCROW");
        c.hook = vm.envAddress("PONS_HOOK");
        c.poolManager = vm.envOr("POOL_MANAGER", address(0));
        c.maxBuy = vm.envOr("MAX_BUY_WEI", uint256(0.1 ether));
        c.cooldown = vm.envOr("COOLDOWN_SEC", uint256(5 minutes));
        c.seedEth = vm.envOr("SEED_ETH_WEI", uint256(0.05 ether));
        c.seedCartha = vm.envOr("SEED_CARTHA_WEI", uint256(1_000e18));
    }

    function _validate(Cfg memory c, IPonsFactory.LaunchedToken memory launch) internal pure {
        require(launch.exists, "TOKEN is not a pons launch on this factory");
        require(launch.pairToken == address(0), "launch is not a native-ETH pair");
        require(launch.creatorTaxBps > 0, "creator tax is zero: the vault would earn only the pons fee share, forever");
        require(launch.phase == 0 || launch.phase == 2, "launch is swept or rescued: nothing to buy from yet");
        require(c.seedEth > 0 && c.seedCartha > 0, "L-01: seed is mandatory");
    }

    /// @dev Buy on the curve pre-graduation; post-graduation the deployer must already
    ///      hold the CARTHA to seed with. Shares are parked at the dead address.
    function _seed(Cfg memory c, IPonsFactory.LaunchedToken memory launch, address vault)
        internal
        returns (uint256 toDeposit)
    {
        if (launch.phase == 0) {
            uint256 got = IPonsCurve(launch.curve).buy{value: c.seedEth}(c.seedEth, 0, c.deployer);
            toDeposit = c.seedCartha > got ? got : c.seedCartha;
        } else {
            require(
                IERC20(c.token).balanceOf(c.deployer) >= c.seedCartha,
                "post-graduation seed: deployer holds too little CARTHA"
            );
            toDeposit = c.seedCartha;
        }
        IERC20(c.token).approve(vault, toDeposit);
        CarthaVault(vault).deposit(toDeposit, DEAD);
        require(CarthaVault(vault).balanceOf(DEAD) >= 1e18, "L-01: dead-address shares below minimum");
    }

    function _log(Cfg memory c, IPonsFactory.LaunchedToken memory launch, Out memory o) internal pure {
        console.log("deployer          ", c.deployer);
        console.log("CARTHA token       ", c.token);
        console.log("curve             ", launch.curve);
        console.log("CarthaVault        ", o.vault);
        console.log("CarthaHarvester    ", o.harvester);
        console.log("seeded CARTHA      ", o.seeded);
        if (!o.feesWired) {
            console.log("");
            console.log("FEES NOT WIRED. The wallet that launched must call, on the factory:");
            console.log("  transferCreatorFeeRecipient(token, harvester)");
            console.log("  factory  ", address(c.factory));
            console.log("  harvester", o.harvester);
            console.log("Until then, creator fees keep accruing to the launch wallet, not the vault.");
        }
    }

    function _record(Cfg memory c, IPonsFactory.LaunchedToken memory launch, Out memory o) internal {
        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "token", c.token);
        vm.serializeAddress(json, "curve", launch.curve);
        vm.serializeAddress(json, "vault", o.vault);
        vm.serializeAddress(json, "harvester", o.harvester);
        vm.serializeAddress(json, "factory", address(c.factory));
        vm.serializeAddress(json, "escrow", c.escrow);
        vm.serializeAddress(json, "hook", c.hook);
        vm.serializeAddress(json, "poolManager", c.poolManager);
        vm.serializeUint(json, "block", block.number);
        string memory out = vm.serializeUint(json, "creatorTaxBps", launch.creatorTaxBps);
        vm.writeJson(out, "./deployments/robinhood-4663.json");
        console.log("wrote deployments/robinhood-4663.json");
    }
}
