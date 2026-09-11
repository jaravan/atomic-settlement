// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice Steps 1-2: construction, roles, denomination, and the registry gate.
contract AssetTokenTest is Test {
    AssetToken internal bond;
    MockKYCRegistry internal registry;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant STRANGER = address(0x5747);
    address internal constant ALICE = address(0xA11);
    address internal constant BOB = address(0xB0B);
    address internal constant SETTLEMENT = address(0x5E77);

    bytes12 internal constant ISIN = bytes12("DE000A1EWWW0");

    // Cached because reading one off the contract is itself a call, which would consume a
    // pending vm.prank before the call under test ever runs.
    bytes32 internal adminRole;
    bytes32 internal issuerRole;
    bytes32 internal officerRole;
    bytes32 internal pauserRole;

    function setUp() public {
        registry = new MockKYCRegistry();
        bond = new AssetToken("Bund 2035", "BUND35", ISIN, IKYCRegistryV2(address(registry)), ADMIN);

        adminRole = bond.DEFAULT_ADMIN_ROLE();
        issuerRole = bond.ISSUER_ROLE();
        officerRole = bond.COMPLIANCE_OFFICER_ROLE();
        pauserRole = bond.PAUSER_ROLE();
    }

    // -- construction ------------------------------------------------------------------

    function test_constructor_setsMetadata() public view {
        assertEq(bond.name(), "Bund 2035");
        assertEq(bond.symbol(), "BUND35");
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(bond.registry()), address(registry));
        assertEq(bond.isin(), ISIN);
    }

    function test_constructor_startsWithNoSupply() public view {
        assertEq(bond.totalSupply(), 0);
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(AssetToken.InvalidConfiguration.selector);
        new AssetToken("Bund 2035", "BUND35", ISIN, IKYCRegistryV2(address(0)), ADMIN);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(AssetToken.InvalidConfiguration.selector);
        new AssetToken("Bund 2035", "BUND35", ISIN, IKYCRegistryV2(address(registry)), address(0));
    }

    function test_constructor_revertsOnZeroIsin() public {
        vm.expectRevert(AssetToken.InvalidConfiguration.selector);
        new AssetToken("Bund 2035", "BUND35", bytes12(0), IKYCRegistryV2(address(registry)), ADMIN);
    }

    // -- denomination (section 9) --------------------------------------------------------

    /// @dev Zero, not six: divisibility is a property a bond must not have.
    function test_decimals_isZero() public view {
        assertEq(bond.decimals(), 0);
    }

    // -- roles (section 2) ---------------------------------------------------------------

    function test_roleIdentifiers() public view {
        assertEq(adminRole, bytes32(0));
        assertEq(issuerRole, keccak256("ISSUER_ROLE"));
        assertEq(officerRole, keccak256("COMPLIANCE_OFFICER_ROLE"));
        assertEq(pauserRole, keccak256("PAUSER_ROLE"));
    }

    function test_adminHoldsAdminRole() public view {
        assertTrue(bond.hasRole(adminRole, ADMIN));
    }

    function test_deployerHoldsNoRole() public view {
        assertFalse(bond.hasRole(adminRole, address(this)));
    }

    function test_operationalRolesStartUnheld() public view {
        assertFalse(bond.hasRole(issuerRole, ADMIN));
        assertFalse(bond.hasRole(officerRole, ADMIN));
        assertFalse(bond.hasRole(pauserRole, ADMIN));
    }

    function test_adminGrantsEachOperationalRole() public {
        vm.startPrank(ADMIN);
        bond.grantRole(issuerRole, ISSUER);
        bond.grantRole(officerRole, OFFICER);
        bond.grantRole(pauserRole, OFFICER);
        vm.stopPrank();

        assertTrue(bond.hasRole(issuerRole, ISSUER));
        assertTrue(bond.hasRole(officerRole, OFFICER));
        assertTrue(bond.hasRole(pauserRole, OFFICER));
    }

    function test_adminRevokesRole() public {
        vm.prank(ADMIN);
        bond.grantRole(issuerRole, ISSUER);

        vm.prank(ADMIN);
        bond.revokeRole(issuerRole, ISSUER);

        assertFalse(bond.hasRole(issuerRole, ISSUER));
    }

    function test_strangerCannotGrantRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, adminRole)
        );
        vm.prank(STRANGER);
        bond.grantRole(issuerRole, ISSUER);
    }

    // -- the registry gate (sections 1, 3) -----------------------------------------------

    /// @dev Whole bonds: decimals() is 0.
    uint256 internal constant AMOUNT = 100;

    /// @dev Written directly rather than minted, because several tests need a holder whose
    ///      approval has lapsed -- a state mint cannot produce but the registry can.
    function _fund(address who, uint256 amount) private {
        deal(address(bond), who, amount, true);
    }

    /// @dev No tier is set: this token never reads one, and the tests should prove it.
    function _approve(address who) private {
        registry.setApproved(who, true);
    }

    function test_transfer_succeedsWhenBothApproved() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);

        assertEq(bond.balanceOf(ALICE), 0);
        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    /// @dev The asset leg has no limits, so an approved address with no tier transacts.
    ///      On the cash leg this same setup reverts with TierUnset (section 4).
    function test_transfer_needsNoTier() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        assertEq(uint8(registry.tierOf(ALICE)), 0, "UNSET");

        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    function test_transfer_revertsWhenSenderNotApproved() public {
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    function test_transfer_revertsWhenRecipientNotApproved() public {
        _approve(ALICE);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, BOB));
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    function test_transfer_revertsWhenSenderSanctioned() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        registry.setSanctioned(ALICE, true);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    function test_transfer_gatesZeroValue() public {
        _approve(ALICE);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, BOB));
        vm.prank(ALICE);
        bond.transfer(BOB, 0);
    }

    // -- transferFrom: the spender (section 3) -------------------------------------------

    /// @dev The property the settlement design rests on: the spender is never asked to be
    ///      isApproved, because a contract can never be.
    function test_transferFrom_spenderNeedNotBeApproved() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        assertFalse(registry.isApproved(SETTLEMENT), "settlement contract is deliberately unapproved");

        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    function test_transferFrom_revertsWhenSpenderSanctioned() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        registry.setSanctioned(SETTLEMENT, true);

        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.SpenderSanctioned.selector, SETTLEMENT));
        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);
    }

    function test_transferFrom_spenderCheckPrecedesAllowance() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        registry.setSanctioned(SETTLEMENT, true);

        assertEq(bond.allowance(ALICE, SETTLEMENT), 0);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.SpenderSanctioned.selector, SETTLEMENT));
        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);
    }

    function test_transferFrom_stillGatesBothParties() public {
        _approve(ALICE);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, BOB));
        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);
    }
}
