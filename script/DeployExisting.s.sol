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

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address token = vm.envAddress("TOKEN");
        IPonsFactory factory = IPonsFactory(vm.envAddress("PONS_FACTORY"));
        address escrow = vm.envAddress("PONS_ESCROW");
        address hook = vm.envAddress("PONS_HOOK");
        address poolManager = vm.envOr("POOL_MANAGER", address(0));
        uint256 maxBuy = vm.envOr("MAX_BUY_WEI", uint256(0.1 ether));
        uint256 cooldown = vm.envOr("COOLDOWN_SEC", uint256(5 minutes));
        uint256 seedEth = vm.envOr("SEED_ETH_WEI", uint256(0.05 ether));
        uint256 seedCartha = vm.envOr("SEED_CARTHA_WEI", uint256(1_000e18));

        // Pre-flight: the launch must exist and match what the harvester expects.
        IPonsFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        require(launch.exists, "TOKEN is not a pons launch on this factory");
        require(launch.pairToken == address(0), "launch is not a native-ETH pair");
        require(launch.creatorTaxBps > 0, "creator tax is zero: the vault would earn only the pons fee share, forever");
        require(launch.phase == 0 || launch.phase == 2, "launch is swept or rescued: nothing to buy from yet");
        require(seedEth > 0 && seedCartha > 0, "L-01: seed is mandatory");

        vm.startBroadcast(pk);
        address vault = address(new CarthaVault(IERC20(token)));
        address harvester =
            address(new CarthaHarvester(token, vault, address(factory), escrow, hook, poolManager, maxBuy, cooldown));

        bool feesWired = false;
        if (launch.creatorFeeRecipient == deployer) {
            // From here on, fees can only go to the harvester. It has no way to point them anywhere else.
            factory.transferCreatorFeeRecipient(token, harvester);
            feesWired = true;
        }

        // Seed (audit L-01): buy on the curve pre-graduation, or transfer-in post-graduation
        // is not supported here; on phase 2 the deployer must already hold CARTHA to seed with.
        uint256 toDeposit;
        if (launch.phase == 0) {
            uint256 got = IPonsCurve(launch.curve).buy{value: seedEth}(seedEth, 0, deployer);
            toDeposit = seedCartha > got ? got : seedCartha;
        } else {
            require(IERC20(token).balanceOf(deployer) >= seedCartha, "post-graduation seed: deployer holds too little CARTHA");
            toDeposit = seedCartha;
        }
        IERC20(token).approve(vault, toDeposit);
        CarthaVault(vault).deposit(toDeposit, DEAD);
        require(CarthaVault(vault).balanceOf(DEAD) >= 1e18, "L-01: dead-address shares below minimum");
        vm.stopBroadcast();

        console.log("deployer          ", deployer);
        console.log("CARTHA token       ", token);
        console.log("curve             ", launch.curve);
        console.log("CarthaVault        ", vault);
        console.log("CarthaHarvester    ", harvester);
        console.log("seeded CARTHA      ", toDeposit);
        if (!feesWired) {
            console.log("");
            console.log("FEES NOT WIRED. The wallet that launched must call, on the factory:");
            console.log("  transferCreatorFeeRecipient(token, harvester)");
            console.log("  factory  ", address(factory));
            console.log("  token    ", token);
            console.log("  harvester", harvester);
            console.log("Until then, creator fees keep accruing to the launch wallet, not the vault.");
        }

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "token", token);
        vm.serializeAddress(json, "curve", launch.curve);
        vm.serializeAddress(json, "vault", vault);
        vm.serializeAddress(json, "harvester", harvester);
        vm.serializeAddress(json, "factory", address(factory));
        vm.serializeAddress(json, "escrow", escrow);
        vm.serializeAddress(json, "hook", hook);
        vm.serializeAddress(json, "poolManager", poolManager);
        vm.serializeUint(json, "block", block.number);
        string memory out = vm.serializeUint(json, "creatorTaxBps", launch.creatorTaxBps);
        vm.writeJson(out, "./deployments/robinhood-4663.json");
        console.log("wrote deployments/robinhood-4663.json");
    }
}
