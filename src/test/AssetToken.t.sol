// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice Steps 1-4: construction, roles, denomination, the registry gate, freeze and pause.
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

    // -- freeze (section 5) --------------------------------------------------------------

    bytes32 internal constant REASON = bytes32("COURT_ORDER");

    function _officer() private returns (address) {
        vm.prank(ADMIN);
        bond.grantRole(officerRole, OFFICER);
        return OFFICER;
    }

    function test_freeze_blocksOutbound() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(_officer());
        bond.freeze(ALICE, REASON);

        assertTrue(bond.frozen(ALICE));

        vm.expectRevert(abi.encodeWithSelector(AssetToken.SenderFrozen.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    function test_freeze_stillAllowsInbound() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(_officer());
        bond.freeze(BOB, REASON);

        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    function test_unfreeze_restoresSending() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        address officer = _officer();
        vm.prank(officer);
        bond.freeze(ALICE, REASON);
        vm.prank(officer);
        bond.unfreeze(ALICE, REASON);

        assertFalse(bond.frozen(ALICE));

        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    function test_freeze_blocksTransferFrom() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        vm.prank(_officer());
        bond.freeze(ALICE, REASON);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.SenderFrozen.selector, ALICE));
        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);
    }

    /// @dev Freezing does not clear allowances (section 3): the approval survives, unusable
    ///      until the freeze lifts.
    function test_freeze_leavesAllowanceIntact() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        address officer = _officer();
        vm.prank(officer);
        bond.freeze(ALICE, REASON);

        assertEq(bond.allowance(ALICE, SETTLEMENT), AMOUNT, "allowance must survive the freeze");

        vm.prank(officer);
        bond.unfreeze(ALICE, REASON);

        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    function test_freeze_approvalCheckPrecedesFreezeCheck() public {
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(_officer());
        bond.freeze(ALICE, REASON);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    function test_freeze_emitsEventWithReasonAndCaller() public {
        address officer = _officer();

        vm.expectEmit(true, true, true, true);
        emit AssetToken.AccountFrozen(ALICE, REASON, officer);
        vm.prank(officer);
        bond.freeze(ALICE, REASON);

        vm.expectEmit(true, true, true, true);
        emit AssetToken.AccountUnfrozen(ALICE, REASON, officer);
        vm.prank(officer);
        bond.unfreeze(ALICE, REASON);
    }

    function test_freeze_requiresComplianceOfficer() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, officerRole)
        );
        vm.prank(STRANGER);
        bond.freeze(ALICE, REASON);
    }

    function test_unfreeze_requiresComplianceOfficer() public {
        vm.prank(_officer());
        bond.freeze(ALICE, REASON);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, officerRole)
        );
        vm.prank(STRANGER);
        bond.unfreeze(ALICE, REASON);
    }

    // -- pause (section 6) ---------------------------------------------------------------

    function _pauser() private returns (address) {
        vm.prank(ADMIN);
        bond.grantRole(pauserRole, OFFICER);
        return OFFICER;
    }

    function test_pause_blocksTransfer() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(_pauser());
        bond.pause();

        assertTrue(bond.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    function test_pause_blocksTransferFrom() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        vm.prank(_pauser());
        bond.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);
    }

    function test_pause_blocksApprove() public {
        _approve(ALICE);

        vm.prank(_pauser());
        bond.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);
    }

    function test_pause_leavesViewsReadable() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        vm.prank(_pauser());
        bond.pause();

        assertEq(bond.balanceOf(ALICE), AMOUNT);
        assertEq(bond.allowance(ALICE, SETTLEMENT), AMOUNT);
        assertEq(bond.totalSupply(), AMOUNT);
        assertEq(bond.isin(), ISIN);
        assertFalse(bond.frozen(ALICE));
    }

    function test_unpause_restoresTransfers() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        address pauser = _pauser();
        vm.prank(pauser);
        bond.pause();
        vm.prank(pauser);
        bond.unpause();

        assertFalse(bond.paused());

        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    /// @dev A pause is an incident control; it must not disarm the per-address one.
    function test_pause_doesNotBlockFreezing() public {
        vm.prank(_pauser());
        bond.pause();

        vm.prank(_officer());
        bond.freeze(ALICE, REASON);

        assertTrue(bond.frozen(ALICE));
    }

    /// @dev One deployment per issue: pausing this instrument leaves another untouched.
    function test_pause_isPerInstrument() public {
        AssetToken other =
            new AssetToken("Bund 2040", "BUND40", bytes12("DE000A1EWWX8"), IKYCRegistryV2(address(registry)), ADMIN);
        _approve(ALICE);
        _approve(BOB);
        deal(address(other), ALICE, AMOUNT, true);

        vm.prank(_pauser());
        bond.pause();

        vm.prank(ALICE);
        other.transfer(BOB, AMOUNT);

        assertEq(other.balanceOf(BOB), AMOUNT);
        assertFalse(other.paused());
    }

    function test_pause_requiresPauserRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, pauserRole)
        );
        vm.prank(STRANGER);
        bond.pause();
    }

    function test_unpause_requiresPauserRole() public {
        vm.prank(_pauser());
        bond.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, pauserRole)
        );
        vm.prank(STRANGER);
        bond.unpause();
    }

    function test_pause_complianceOfficerCannotPause() public {
        // Hoisted: the helper makes a call of its own, which vm.expectRevert would latch onto.
        address officer = _officer();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, officer, pauserRole)
        );
        vm.prank(officer);
        bond.pause();
    }
}
