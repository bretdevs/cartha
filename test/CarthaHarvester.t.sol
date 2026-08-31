// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CarthaVault} from "../src/CarthaVault.sol";
import {CarthaHarvester} from "../src/CarthaHarvester.sol";
import {IPonsFactory} from "../src/interfaces/IPons.sol";
import {PoolKey} from "../src/interfaces/IUniswapV4.sol";
import {MockCARTHA, MockEscrow, MockCurve, MockFactory, MockHook, MockPoolManager} from "./mocks/Mocks.sol";

contract CarthaHarvesterTest is Test {
    MockCARTHA still;
    CarthaVault vault;
    MockEscrow escrow;
    MockCurve curve;
    MockFactory factory;
    MockHook hook;
    MockPoolManager pm;
    CarthaHarvester harvester;

    uint256 constant MAX_BUY = 0.1 ether;
    uint256 constant COOLDOWN = 5 minutes;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address keeper = makeAddr("keeper");
    address depositor = makeAddr("depositor");

    function setUp() public {
        still = new MockCARTHA();
        vault = new CarthaVault(IERC20(address(still)));
        escrow = new MockEscrow();
        factory = new MockFactory();
        pm = new MockPoolManager(still);

        curve = new MockCurve(still, escrow, address(0));
        hook = new MockHook(escrow, address(pm), address(0));

        factory.set(
            IPonsFactory.LaunchedToken({
                token: address(still),
                curve: address(curve),
                deployer: address(this),
                creatorFeeRecipient: address(0),
                pairToken: address(0),
                graduationThreshold: 4.2 ether,
                poolFee: 0,
                tickSpacing: 60,
                creatorTaxBps: 300,
                buybackEnabled: false,
                phase: 0,
                sweptQuote: 0,
                sweptTokens: 0,
                sweptAt: 0,
                exists: true
            })
        );

        harvester = new CarthaHarvester(
            address(still), address(vault), address(factory), address(escrow), address(hook), address(pm), MAX_BUY, COOLDOWN
        );
        // Mirror the deploy script: the launch is created first, then fees are pointed at the harvester.
        curve.setFeeRecipient(address(harvester));
        hook.setFeeRecipient(address(harvester));

        // Seed the vault the way the deploy script does, plus one real depositor.
        still.mint(address(this), 1_000e18);
        still.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18, DEAD);

        still.mint(depositor, 1_000e18);
        vm.startPrank(depositor);
        still.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18, depositor);
        vm.stopPrank();

        vm.deal(address(this), 100 ether);
        vm.warp(1_800_000_000);
    }

    function ratio() internal view returns (uint256) {
        return vault.convertToAssets(1e18);
    }

    // --------------------------------------------------------- construction

    function test_constructorRejectsNonNativePair() public {
        IPonsFactory.LaunchedToken memory l = factory.getLaunchedToken(address(still));
        l.pairToken = address(0xBEEF);
        MockFactory other = new MockFactory();
        other.set(l);
        vm.expectRevert(CarthaHarvester.NativePairOnly.selector);
        new CarthaHarvester(address(still), address(vault), address(other), address(escrow), address(hook), address(pm), MAX_BUY, COOLDOWN);
    }

    function test_constructorRejectsUnknownLaunch() public {
        MockFactory empty = new MockFactory();
        vm.expectRevert(CarthaHarvester.UnknownLaunch.selector);
        new CarthaHarvester(address(still), address(vault), address(empty), address(escrow), address(hook), address(pm), MAX_BUY, COOLDOWN);
    }

    function test_poolKeyAndId() public view {
        PoolKey memory key = harvester.poolKey();
        assertEq(key.currency0, address(0));
        assertEq(key.currency1, address(still));
        assertEq(key.fee, 0);
        assertEq(key.tickSpacing, 60);
        assertEq(key.hooks, address(hook));
        assertEq(harvester.poolId(), keccak256(abi.encode(key)));
    }

    // -------------------------------------------------------- curve phase

    function test_harvestClaimsAndBuysOnCurve() public {
        escrow.credit{value: 0.05 ether}(address(harvester));
        uint256 before = ratio();
        uint256 depositorShares = vault.balanceOf(depositor);

        vm.prank(keeper);
        (uint256 ethSpent, uint256 bought) = harvester.harvest(0);

        assertEq(ethSpent, 0.05 ether);
        assertEq(bought, 50_000e18); // 1 ETH -> 1,000,000 CARTHA on the mock curve
        assertEq(still.balanceOf(address(vault)), 2_000e18 + 50_000e18);
        assertEq(address(harvester).balance, 0);
        assertGt(ratio(), before, "ratio must rise");
        assertEq(vault.balanceOf(depositor), depositorShares, "depositor balance must not move");
        assertEq(harvester.totalEthSpent(), 0.05 ether);
        assertEq(harvester.totalCarthaBought(), 50_000e18);
        assertEq(harvester.lastBuyAt(), block.timestamp);
        assertEq(harvester.ledgerLength(), 1);

        CarthaHarvester.Entry[] memory entries = harvester.recent(5);
        assertEq(entries.length, 1);
        assertEq(entries[0].ethSpent, 0.05 ether);
        assertEq(entries[0].carthaBought, 50_000e18);
        assertEq(entries[0].ratioAfter, ratio());
    }

    function test_harvestEmitsEvent() public {
        escrow.credit{value: 0.02 ether}(address(harvester));
        vm.expectEmit(true, false, false, false);
        emit CarthaHarvester.Harvest(keeper, 0.02 ether, 20_000e18, 0);
        vm.prank(keeper);
        harvester.harvest(0);
    }

    function test_capLeavesRemainderHeld() public {
        escrow.credit{value: 1 ether}(address(harvester));
        (uint256 ethSpent,) = harvester.harvest(0);
        assertEq(ethSpent, MAX_BUY);
        assertEq(address(harvester).balance, 0.9 ether);
        (uint256 claimable, uint256 held) = harvester.pending();
        assertEq(claimable, 0);
        assertEq(held, 0.9 ether);
    }

    function test_cooldownBlocksSecondBuyButStillClaims() public {
        escrow.credit{value: 0.05 ether}(address(harvester));
        harvester.harvest(0);

        escrow.credit{value: 0.03 ether}(address(harvester));
        (uint256 ethSpent, uint256 bought) = harvester.harvest(0);
        assertEq(ethSpent, 0);
        assertEq(bought, 0);
        assertEq(address(harvester).balance, 0.03 ether, "claimed but not spent");
        assertEq(harvester.ledgerLength(), 1);

        vm.warp(block.timestamp + COOLDOWN);
        (ethSpent, bought) = harvester.harvest(0);
        assertEq(ethSpent, 0.03 ether);
        assertEq(bought, 30_000e18);
        assertEq(harvester.ledgerLength(), 2);
    }

    function test_curveRefundIsNotCountedAsSpent() public {
        curve.setRefundBps(2_000); // clamped final buy hands 20% back
        escrow.credit{value: 0.1 ether}(address(harvester));
        (uint256 ethSpent, uint256 bought) = harvester.harvest(0);
        assertEq(ethSpent, 0.08 ether);
        assertEq(bought, 80_000e18);
        assertEq(address(harvester).balance, 0.02 ether);
    }

    function test_curveSlippageRevertsBubbleUp() public {
        escrow.credit{value: 0.01 ether}(address(harvester));
        vm.expectRevert(bytes("curve: SlippageExceeded"));
        harvester.harvest(10_001e18);
    }

    function test_sweepOnCurveFeedsSameHarvest() public {
        curve.addUnsweptFees{value: 0.04 ether}();
        (uint256 ethSpent,) = harvester.harvest(0);
        assertEq(ethSpent, 0.04 ether);
    }

    function test_sweepRevertDoesNotBreakHarvest() public {
        curve.setSweepReverts(true);
        curve.addUnsweptFees{value: 1 ether}();
        escrow.credit{value: 0.02 ether}(address(harvester));
        (uint256 ethSpent,) = harvester.harvest(0);
        assertEq(ethSpent, 0.02 ether);
    }

    function test_claimFailureIsReportedNotFatal() public {
        escrow.credit{value: 0.02 ether}(address(harvester));
        escrow.setClaimReverts(true);
        vm.deal(address(harvester), 0.01 ether); // something already held
        vm.expectEmit(false, false, false, true);
        emit CarthaHarvester.ClaimFailed(0.02 ether);
        (uint256 ethSpent,) = harvester.harvest(0);
        assertEq(ethSpent, 0.01 ether);
    }

    function test_nothingToDoIsANoOp() public {
        (uint256 ethSpent, uint256 bought) = harvester.harvest(0);
        assertEq(ethSpent, 0);
        assertEq(bought, 0);
        assertEq(harvester.ledgerLength(), 0);
    }

    // ---------------------------------------------------- swept / rescued

    function test_sweptPhaseHoldsEth() public {
        factory.setPhase(1);
        escrow.credit{value: 0.05 ether}(address(harvester));
        (uint256 ethSpent,) = harvester.harvest(0);
        assertEq(ethSpent, 0);
        assertEq(address(harvester).balance, 0.05 ether);
        assertEq(harvester.lastBuyAt(), 0);
    }

    function test_rescuedPhaseHoldsEth() public {
        factory.setPhase(3);
        escrow.credit{value: 0.05 ether}(address(harvester));
        (uint256 ethSpent,) = harvester.harvest(0);
        assertEq(ethSpent, 0);
        assertEq(address(harvester).balance, 0.05 ether);
    }

    // ---------------------------------------------------------- pool phase

    function test_harvestBuysOnPoolAfterGraduation() public {
        factory.setPhase(2);
        escrow.credit{value: 0.05 ether}(address(harvester));
        uint256 before = ratio();

        vm.prank(keeper);
        (uint256 ethSpent, uint256 bought) = harvester.harvest(0);

        assertEq(ethSpent, 0.05 ether);
        assertEq(bought, 40_000e18); // 1 ETH -> 800,000 CARTHA on the mock pool
        assertEq(still.balanceOf(address(vault)), 2_000e18 + 40_000e18);
        assertEq(address(harvester).balance, 0);
        assertGt(ratio(), before);

        // The swap was shaped correctly.
        (address c0, address c1, uint24 fee, int24 spacing, address hooks) = pm.lastKey();
        assertEq(c0, address(0));
        assertEq(c1, address(still));
        assertEq(fee, 0);
        assertEq(spacing, 60);
        assertEq(hooks, address(hook));
        (bool zeroForOne, int256 amountSpecified, uint160 limit) = pm.lastParams();
        assertTrue(zeroForOne);
        assertEq(amountSpecified, -int256(0.05 ether));
        assertEq(limit, 4295128740);
    }

    function test_poolSlippageReverts() public {
        factory.setPhase(2);
        escrow.credit{value: 0.05 ether}(address(harvester));
        vm.expectRevert(abi.encodeWithSelector(CarthaHarvester.Slippage.selector, 40_000e18, 40_001e18));
        harvester.harvest(40_001e18);
    }

    function test_poolSweepFeedsSameHarvest() public {
        factory.setPhase(2);
        hook.setSweepReverts(false);
        hook.addUnsweptFees{value: 0.03 ether}();
        (uint256 ethSpent, uint256 bought) = harvester.harvest(0);
        assertEq(ethSpent, 0.03 ether);
        assertEq(bought, 24_000e18);
    }

    function test_unlockCallbackOnlyFromPoolManager() public {
        vm.expectRevert(CarthaHarvester.NotPoolManager.selector);
        harvester.unlockCallback(abi.encode(uint256(1), uint256(0)));
    }

    // -------------------------------------------------------- long horizon

    function test_manyHarvestsRatioMonotonic() public {
        uint256 last = ratio();
        for (uint256 i = 0; i < 40; i++) {
            if (i == 20) factory.setPhase(2);
            escrow.credit{value: 0.01 ether + i * 0.001 ether}(address(harvester));
            vm.warp(block.timestamp + COOLDOWN);
            harvester.harvest(0);
            uint256 r = ratio();
            assertGe(r, last);
            last = r;
        }
        assertEq(harvester.ledgerLength(), 40);
        CarthaHarvester.Entry[] memory entries = harvester.recent(3);
        assertEq(entries.length, 3);
        assertGe(entries[0].ratioAfter, entries[1].ratioAfter);
        assertGe(entries[1].ratioAfter, entries[2].ratioAfter);
    }

    function test_noAdminSurface() public {
        bytes4[5] memory sels = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("rescue(address)")),
            bytes4(keccak256("setVault(address)"))
        ];
        for (uint256 i = 0; i < sels.length; i++) {
            (bool ok,) = address(harvester).call(abi.encodeWithSelector(sels[i], uint256(0)));
            assertFalse(ok, "unexpected admin selector");
        }
    }
}
