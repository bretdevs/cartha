// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CarthaVault} from "../src/CarthaVault.sol";
import {MockCARTHA} from "./mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CarthaVaultTest is Test {
    MockCARTHA still;
    CarthaVault vault;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SEED = 1_000e18;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address harvester = makeAddr("harvester");

    function setUp() public {
        still = new MockCARTHA();
        vault = new CarthaVault(IERC20(address(still)));

        // Deploy-time seed: deposit and park the shares at the dead address.
        still.mint(address(this), SEED);
        still.approve(address(vault), SEED);
        vault.deposit(SEED, DEAD);
    }

    function ratio() internal view returns (uint256) {
        return vault.convertToAssets(1e18);
    }

    // ---------------------------------------------------------------- shape

    function test_metadata() public view {
        assertEq(vault.name(), "Cartha Vault Share");
        assertEq(vault.symbol(), "vCARTHA");
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(still));
        assertEq(vault.totalAssets(), SEED);
        assertEq(vault.totalSupply(), SEED);
        assertEq(vault.balanceOf(DEAD), SEED);
    }

    function test_ratioStartsAtOne() public view {
        // Virtual offset makes it (SEED + 1) / (SEED + 1) scaled, i.e. exactly 1e18.
        assertEq(ratio(), 1e18);
    }

    function test_depositRedeemRoundTrip() public {
        still.mint(alice, 500e18);
        vm.startPrank(alice);
        still.approve(address(vault), 500e18);
        uint256 shares = vault.deposit(500e18, alice);
        assertEq(shares, 500e18);
        uint256 assets = vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertEq(assets, 500e18);
        assertEq(still.balanceOf(alice), 500e18);
    }

    // ------------------------------------------------------------- accrual

    function test_donationRaisesRatioWithoutMintingShares() public {
        uint256 supplyBefore = vault.totalSupply();
        still.mint(address(vault), 100e18); // what a harvest does
        assertEq(vault.totalSupply(), supplyBefore);
        // 1,100 CARTHA over 1,000 vCARTHA
        assertApproxEqRel(ratio(), 1.1e18, 1e12);
    }

    function test_balanceNeverMovesButRedeemsForMore() public {
        still.mint(alice, 1_000e18);
        vm.startPrank(alice);
        still.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18, alice);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);
        still.mint(address(vault), 200e18); // harvest

        assertEq(vault.balanceOf(alice), aliceShares, "share balance must not move");
        // 2,200 CARTHA over 2,000 vCARTHA: alice's 1,000 shares redeem for ~1,100
        assertApproxEqRel(vault.previewRedeem(aliceShares), 1_100e18, 1e12);
    }

    function test_lateDepositorGetsFewerShares() public {
        still.mint(address(vault), 1_000e18); // ratio 2.0
        still.mint(bob, 100e18);
        vm.startPrank(bob);
        still.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, bob);
        vm.stopPrank();
        assertApproxEqRel(shares, 50e18, 1e12);
    }

    // ------------------------------------------------------ the invariant

    /// @dev CARTHA per vCARTHA never decreases across any interleaving of deposits, mints,
    ///      withdrawals, redemptions and harvests. This is the property the whole site rests on.
    function testFuzz_ratioNeverDecreases(uint8[16] memory ops, uint96[16] memory amounts) public {
        still.mint(alice, type(uint128).max);
        vm.prank(alice);
        still.approve(address(vault), type(uint256).max);

        uint256 last = ratio();
        for (uint256 i = 0; i < ops.length; i++) {
            uint256 amount = uint256(amounts[i]) + 1;
            uint8 op = ops[i] % 5;

            if (op == 0) {
                vm.prank(alice);
                vault.deposit(amount, alice);
            } else if (op == 1) {
                vm.prank(alice);
                vault.mint(amount, alice);
            } else if (op == 2) {
                uint256 max = vault.maxRedeem(alice);
                if (max > 0) {
                    vm.prank(alice);
                    vault.redeem(amount % max + 1, alice, alice);
                }
            } else if (op == 3) {
                uint256 max = vault.maxWithdraw(alice);
                if (max > 0) {
                    vm.prank(alice);
                    vault.withdraw(amount % max + 1, alice, alice);
                }
            } else {
                still.mint(address(vault), amount % 1_000_000e18); // harvest
            }

            uint256 now_ = ratio();
            assertGe(now_, last, "ratio decreased");
            last = now_;
        }
    }

    // ----------------------------------------------------- inflation attack

    /// @dev With the dead seed in place, the classic first-depositor inflation attack costs the
    ///      attacker more than it takes from the victim, and the victim's loss is dust.
    function test_inflationAttackIsUnprofitableAfterSeed() public {
        address attacker = makeAddr("attacker");
        uint256 donation = 1_000_000e18;

        // Attacker takes a tiny position and inflates totalAssets.
        still.mint(attacker, 1 + donation);
        vm.startPrank(attacker);
        still.approve(address(vault), 1);
        uint256 attackerShares = vault.deposit(1, attacker);
        still.transfer(address(vault), donation);
        vm.stopPrank();

        // Victim deposits after the inflation.
        uint256 victimIn = 10e18;
        still.mint(bob, victimIn);
        vm.startPrank(bob);
        still.approve(address(vault), victimIn);
        uint256 victimShares = vault.deposit(victimIn, bob);
        uint256 victimOut = vault.redeem(victimShares, bob, bob);
        vm.stopPrank();

        // Attacker exits.
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);

        assertGt(victimShares, 0, "victim must receive shares");
        assertGe(victimOut, victimIn - 1e6, "victim loss must be dust"); // at most ~1e6 wei on 10 CARTHA
        assertLt(attackerOut, donation / 2, "attacker must lose most of the donation to the dead seed");
    }

    // ------------------------------------------------------------- surface

    function test_noAdminSurface() public {
        // These selectors do not exist on the vault. Calls must revert with no fallback.
        bytes4[4] memory sels = [bytes4(keccak256("owner()")), bytes4(keccak256("pause()")), bytes4(keccak256("setFee(uint256)")), bytes4(keccak256("upgradeTo(address)"))];
        for (uint256 i = 0; i < sels.length; i++) {
            (bool ok,) = address(vault).call(abi.encodeWithSelector(sels[i], uint256(0)));
            assertFalse(ok, "unexpected admin selector");
        }
    }
}
