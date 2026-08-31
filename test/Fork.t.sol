// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CarthaVault} from "../src/CarthaVault.sol";
import {CarthaHarvester} from "../src/CarthaHarvester.sol";
import {IPonsFactory, IPonsCurve, IPonsFeeEscrow, IPonsMemeHook} from "../src/interfaces/IPons.sol";
import {IPoolManager} from "../src/interfaces/IUniswapV4.sol";

/// @notice Runs the harvester against the real pons v2 stack on a fork of Robinhood Chain.
///         Skipped unless FORK=1. Run with:
///           FORK=1 forge test --match-contract ForkTest -vv
///         Optional env: FORK_RPC, FORK_POOL_TOKEN (a graduated native launch),
///         FORK_CURVE_TOKEN (a native launch still on its curve).
contract ForkTest is Test {
    address constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address poolToken;
    address curveToken;
    address poolManager;

    function setUp() public {
        if (!vm.envOr("FORK", false)) vm.skip(true);
        vm.createSelectFork(vm.envOr("FORK_RPC", string("https://rpc.mainnet.chain.robinhood.com")));
        // Defaults found on 31 Aug 2026: GHOST (graduated) and a launch still on its curve.
        poolToken = vm.envOr("FORK_POOL_TOKEN", address(0x30c7BCb7572590cAE2AC762c69b1302d31ee13cC));
        curveToken = vm.envOr("FORK_CURVE_TOKEN", address(0xE9090ba8dE1b00A3287396958b12fdc7840da2DF));
        poolManager = IPonsMemeHook(HOOK).poolManager();
    }

    function _deploy(address token) internal returns (CarthaVault vault, CarthaHarvester harvester) {
        vault = new CarthaVault(IERC20(token));
        harvester = new CarthaHarvester(token, address(vault), FACTORY, ESCROW, HOOK, poolManager, 0.05 ether, 5 minutes);
    }

    // ------------------------------------------------------------ surface

    function test_fork_factoryReads() public view {
        IPonsFactory f = IPonsFactory(FACTORY);
        assertEq(block.chainid, 4663);
        assertGt(f.launchFee(), 0);
        assertGe(f.maxCreatorTaxBps(), 300, "3% creator tax must be under the cap");
        assertTrue(f.canLaunch(address(0xBEEF)), "public launches must be open");
        assertTrue(poolManager != address(0), "hook must expose poolManager()");
        assertGt(poolManager.code.length, 0);
    }

    function test_fork_launchRecordShapeMatchesInterface() public view {
        IPonsFactory.LaunchedToken memory l = IPonsFactory(FACTORY).getLaunchedToken(poolToken);
        assertTrue(l.exists);
        assertEq(l.token, poolToken);
        assertEq(l.pairToken, address(0), "pool token must be a native launch");
        assertEq(l.phase, 2, "pool token must be graduated");
        assertEq(l.poolFee, 0, "docs: pool fee field is zero, the hook charges");
        assertGt(l.curve.code.length, 0);

        IPonsFactory.LaunchedToken memory c = IPonsFactory(FACTORY).getLaunchedToken(curveToken);
        assertTrue(c.exists);
        assertEq(c.pairToken, address(0));
        assertEq(c.phase, 0, "curve token must still be on its curve");
    }

    function test_fork_transferCreatorFeeRecipientExistsAndIsGated() public {
        // From a wallet that is not the recipient this must revert with the custom error,
        // which proves the selector exists on the factory. A missing function reverts with empty data.
        vm.prank(address(0xBEEF));
        (bool ok, bytes memory data) = FACTORY.call(
            abi.encodeWithSelector(IPonsFactory.transferCreatorFeeRecipient.selector, poolToken, address(0xCAFE))
        );
        assertFalse(ok);
        assertEq(bytes4(data), bytes4(keccak256("NotCreatorFeeRecipient()")), "unexpected revert from transferCreatorFeeRecipient");
    }

    function test_fork_escrowClaimSelectorExists() public {
        // A fresh address has no balance. claim() should either no-op or revert with a custom error,
        // never with empty revert data (which would mean the selector is not there).
        vm.prank(address(0xBEEF));
        (bool ok, bytes memory data) = ESCROW.call(abi.encodeWithSelector(IPonsFeeEscrow.claim.selector));
        if (!ok) assertGt(data.length, 0, "claim() selector missing on escrow");
        assertEq(IPonsFeeEscrow(ESCROW).balanceOf(address(0xBEEF)), 0);
    }

    function test_fork_sweepSelectorsExist() public {
        IPonsFactory.LaunchedToken memory c = IPonsFactory(FACTORY).getLaunchedToken(curveToken);
        vm.prank(address(0xBEEF));
        (bool ok, bytes memory data) = c.curve.call(abi.encodeWithSelector(IPonsCurve.sweepFees.selector, uint256(0)));
        // Either it worked (nothing to sweep) or it reverted with a custom error. Empty data means no such function.
        if (!ok) assertGt(data.length, 0, "sweepFees(uint256) missing on curve");

        (CarthaVault v, CarthaHarvester h) = _deploy(poolToken);
        v;
        vm.prank(address(0xBEEF));
        (ok, data) = HOOK.call(abi.encodeWithSelector(IPonsMemeHook.sweepPoolFees.selector, h.poolId(), uint256(0), uint256(0)));
        if (!ok) assertGt(data.length, 0, "sweepPoolFees(bytes32,uint256,uint256) missing on hook");
    }

    // --------------------------------------------------------- the paths

    function test_fork_harvestBuysOnLivePool() public {
        (CarthaVault vault, CarthaHarvester harvester) = _deploy(poolToken);

        // Seed like the deploy script, so the ratio is meaningful.
        deal(poolToken, address(this), 1_000e18);
        IERC20(poolToken).approve(address(vault), 1_000e18);
        vault.deposit(1_000e18, DEAD);
        uint256 before = vault.convertToAssets(1e18);
        uint256 vaultBefore = IERC20(poolToken).balanceOf(address(vault));

        vm.deal(address(harvester), 0.02 ether);
        assertEq(harvester.phase(), 2);
        (uint256 ethSpent, uint256 bought) = harvester.harvest(0);

        console.log("pool buy: eth spent", ethSpent, "tokens bought", bought);
        assertEq(ethSpent, 0.02 ether, "exact input must be fully spent");
        assertGt(bought, 0);
        assertEq(IERC20(poolToken).balanceOf(address(vault)) - vaultBefore, bought, "tokens must land in the vault");
        assertEq(address(harvester).balance, 0);
        assertEq(IERC20(poolToken).balanceOf(address(harvester)), 0, "harvester must hold no tokens");
        assertGt(vault.convertToAssets(1e18), before, "ratio must rise");
        assertEq(harvester.ledgerLength(), 1);

        // The keeper's slot0 read must agree with the pool: price implied by the trade is near spot.
        bytes32 stateSlot = keccak256(abi.encodePacked(harvester.poolId(), bytes32(uint256(6))));
        uint256 sqrtPriceX96 = uint256(IPoolManager(poolManager).extsload(stateSlot)) & ((1 << 160) - 1);
        assertGt(sqrtPriceX96, 0, "slot0 read via extsload must be non-zero");
        uint256 priceX96 = (sqrtPriceX96 * sqrtPriceX96) >> 96; // tokens per ETH, Q96
        uint256 spotOut = (0.02 ether * priceX96) >> 96;
        assertGt(bought, spotOut / 2, "received far less than spot");
        assertLt(bought, spotOut * 2, "received far more than spot");
    }

    function test_fork_harvestBuysOnLiveCurve() public {
        IPonsFactory.LaunchedToken memory c = IPonsFactory(FACTORY).getLaunchedToken(curveToken);
        IPonsCurve curve = IPonsCurve(c.curve);
        if (curve.sellableTokens() == 0) vm.skip(true);

        (CarthaVault vault, CarthaHarvester harvester) = _deploy(curveToken);
        vm.deal(address(harvester), 0.01 ether);
        assertEq(harvester.phase(), 0);

        // Quote the way the keeper does, then require most of it.
        (uint256 quoteReserve, uint256 tokenReserve) = curve.getReserves();
        uint256 feeBps = curve.feeBps();
        uint256 taxBps = curve.creatorTaxBps();
        assertEq(curve.currentSnipeTaxBps(address(vault)), 0, "snipe window must be over");
        uint256 net = 0.01 ether - (0.01 ether * feeBps) / 10_000 - (0.01 ether * taxBps) / 10_000;
        uint256 quoted = (net * tokenReserve) / (quoteReserve + net);
        if (quoted > curve.sellableTokens()) quoted = curve.sellableTokens();

        (uint256 ethSpent, uint256 bought) = harvester.harvest((quoted * 97) / 100);
        console.log("curve buy: eth spent", ethSpent, "tokens bought", bought);
        assertGt(bought, 0);
        assertLe(ethSpent, 0.01 ether);
        assertEq(IERC20(curveToken).balanceOf(address(vault)), bought, "tokens must land in the vault");
        assertGe(bought, (quoted * 97) / 100);
        assertLe(bought, quoted, "docs quote must be an upper bound");
    }

    function test_fork_cooldownAndCapHoldOnLivePool() public {
        (, CarthaHarvester harvester) = _deploy(poolToken);
        vm.deal(address(harvester), 0.3 ether);
        (uint256 spent1,) = harvester.harvest(0);
        assertEq(spent1, 0.05 ether, "capped at maxBuyPerHarvest");
        (uint256 spent2,) = harvester.harvest(0);
        assertEq(spent2, 0, "cooldown");
        vm.warp(block.timestamp + 5 minutes);
        (uint256 spent3,) = harvester.harvest(0);
        assertEq(spent3, 0.05 ether);
        assertEq(address(harvester).balance, 0.2 ether);
    }
}
