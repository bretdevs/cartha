// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CarthaVault} from "../src/CarthaVault.sol";
import {CarthaHarvester} from "../src/CarthaHarvester.sol";
import {IPonsFactory, IPonsCurve, IPonsMemeHook} from "../src/interfaces/IPons.sol";

/// @notice One broadcast, five steps, in this order:
///
///   1. launchToken on the pons v2 factory with the deployer as creator fee recipient.
///   2. deploy CarthaVault(token).
///   3. deploy CarthaHarvester(token, vault, factory, escrow, hook, poolManager, cap, cooldown).
///   4. transferCreatorFeeRecipient(token, harvester): from here on, fees can only go to the harvester.
///   5. buy SEED_ETH of CARTHA on the curve, deposit SEED_CARTHA into the vault, park the vCARTHA at 0x...dEaD.
///
/// Env (see .env.example): PRIVATE_KEY, PONS_FACTORY, PONS_ESCROW, PONS_HOOK, POOL_MANAGER (optional),
/// LAUNCH_CONFIG_ID, CREATOR_TAX_BPS, MAX_BUY_WEI, COOLDOWN_SEC, SEED_ETH_WEI, SEED_CARTHA_WEI,
/// TOKEN_LOGO, TOKEN_DESCRIPTION, TOKEN_TWITTER, TOKEN_WEBSITE, SALT (optional).
///
/// Run:  forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify --verifier blockscout \
///         --verifier-url https://robinhoodchain.blockscout.com/api
contract Deploy is Script {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Cfg {
        uint256 pk;
        address deployer;
        IPonsFactory factory;
        address escrow;
        address hook;
        address poolManager;
        uint256 configId;
        uint16 taxBps;
        uint256 maxBuy;
        uint256 cooldown;
        uint256 seedEth;
        uint256 seedCartha;
        uint256 launchFee;
        bytes32 economics;
        bytes32 salt;
    }

    struct Out {
        address token;
        address curve;
        address vault;
        address harvester;
    }

    function run() external {
        Cfg memory c = _config();

        vm.startBroadcast(c.pk);
        Out memory o;
        (o.token, o.curve) = _launch(c);
        o.vault = address(new CarthaVault(IERC20(o.token)));
        o.harvester = address(
            new CarthaHarvester(o.token, o.vault, address(c.factory), c.escrow, c.hook, c.poolManager, c.maxBuy, c.cooldown)
        );
        // From here on, fees can only go to the harvester. It has no way to point them anywhere else.
        c.factory.transferCreatorFeeRecipient(o.token, o.harvester);
        _seed(c, o);
        vm.stopBroadcast();

        _log(c, o);
        _record(c, o);
    }

    function _config() internal view returns (Cfg memory c) {
        c.pk = vm.envUint("PRIVATE_KEY");
        c.deployer = vm.addr(c.pk);
        c.factory = IPonsFactory(vm.envAddress("PONS_FACTORY"));
        c.escrow = vm.envAddress("PONS_ESCROW");
        c.hook = vm.envAddress("PONS_HOOK");
        c.configId = vm.envOr("LAUNCH_CONFIG_ID", uint256(0));
        c.taxBps = uint16(vm.envOr("CREATOR_TAX_BPS", uint256(300)));
        c.maxBuy = vm.envOr("MAX_BUY_WEI", uint256(0.1 ether));
        c.cooldown = vm.envOr("COOLDOWN_SEC", uint256(5 minutes));
        c.seedEth = vm.envOr("SEED_ETH_WEI", uint256(0.05 ether));
        c.seedCartha = vm.envOr("SEED_CARTHA_WEI", uint256(1_000e18));

        // Pre-flight reads: fail here, not halfway through a broadcast.
        require(c.factory.canLaunch(c.deployer), "deployer cannot launch on pons v2 (whitelist closed?)");
        require(c.taxBps <= c.factory.maxCreatorTaxBps(), "creator tax above pons cap");
        c.launchFee = c.factory.launchFee();
        c.economics = c.factory.previewLaunchEconomics(c.configId, address(0));

        c.poolManager = vm.envOr("POOL_MANAGER", address(0));
        if (c.poolManager == address(0)) c.poolManager = IPonsMemeHook(c.hook).poolManager();
        require(c.poolManager != address(0), "pool manager unknown");

        c.salt = vm.envOr("SALT", keccak256(abi.encodePacked("CARTHA", c.deployer, block.timestamp)));
    }

    function _launch(Cfg memory c) internal returns (address token, address curve) {
        IPonsFactory.TokenParams memory params = IPonsFactory.TokenParams({
            name: "Cartha",
            symbol: "CARTHA",
            logo: vm.envOr("TOKEN_LOGO", string("")),
            description: vm.envOr(
                "TOKEN_DESCRIPTION",
                string(
                    "A vault on Robinhood Chain. Trading fees buy CARTHA into the vault. vCARTHA just gets worth more. No claim step, no owner."
                )
            ),
            socials: IPonsFactory.Socials({
                twitter: vm.envOr("TOKEN_TWITTER", string("")),
                telegram: "",
                discord: "",
                website: vm.envOr("TOKEN_WEBSITE", string("")),
                farcaster: ""
            }),
            creatorFeeRecipient: c.deployer,
            creatorTaxBps: c.taxBps,
            buybackEnabled: false, // pons' buyback vests for five years; ours goes straight to the vault
            expectedEconomics: c.economics,
            salt: c.salt
        });
        (token, curve) = c.factory.launchToken{value: c.launchFee}(params, c.configId, address(0));
    }

    /// @dev Buy on the curve, deposit, park the shares at the dead address. This is the
    ///      inflation-attack defence: the share supply is never tiny.
    function _seed(Cfg memory c, Out memory o) internal {
        if (c.seedEth == 0) return;
        uint256 got = IPonsCurve(o.curve).buy{value: c.seedEth}(c.seedEth, 0, c.deployer);
        uint256 toDeposit = c.seedCartha > got ? got : c.seedCartha;
        IERC20(o.token).approve(o.vault, toDeposit);
        CarthaVault(o.vault).deposit(toDeposit, DEAD);
        console.log("seed buy CARTHA    ", got);
        console.log("seeded CARTHA      ", toDeposit);
    }

    function _log(Cfg memory c, Out memory o) internal pure {
        console.log("deployer          ", c.deployer);
        console.log("pool manager      ", c.poolManager);
        console.log("CARTHA token       ", o.token);
        console.log("curve             ", o.curve);
        console.log("CarthaVault        ", o.vault);
        console.log("CarthaHarvester    ", o.harvester);
    }

    function _record(Cfg memory c, Out memory o) internal {
        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "token", o.token);
        vm.serializeAddress(json, "curve", o.curve);
        vm.serializeAddress(json, "vault", o.vault);
        vm.serializeAddress(json, "harvester", o.harvester);
        vm.serializeAddress(json, "factory", address(c.factory));
        vm.serializeAddress(json, "escrow", c.escrow);
        vm.serializeAddress(json, "hook", c.hook);
        vm.serializeAddress(json, "poolManager", c.poolManager);
        vm.serializeUint(json, "block", block.number);
        string memory out = vm.serializeUint(json, "creatorTaxBps", c.taxBps);
        vm.writeJson(out, "./deployments/robinhood-4663.json");
        console.log("wrote deployments/robinhood-4663.json");
    }
}
