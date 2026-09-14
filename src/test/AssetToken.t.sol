// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice Steps 1-7: construction, roles, denomination, the registry gate, freeze, pause,
///         issuance, forced transfer and the transfer previews.
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

    // -- issuance and redemption (section 7) ---------------------------------------------

    /// @dev A wholesale issue: 1,000 bonds of EUR 100,000 nominal.
    uint256 internal constant ISSUE_SIZE = 1_000;

    function _issuer() private returns (address) {
        vm.prank(ADMIN);
        bond.grantRole(issuerRole, ISSUER);
        return ISSUER;
    }

    function test_mint_issuesToApprovedRecipient() public {
        _approve(ALICE);

        vm.prank(_issuer());
        bond.mint(ALICE, ISSUE_SIZE);

        assertEq(bond.balanceOf(ALICE), ISSUE_SIZE);
        assertEq(bond.totalSupply(), ISSUE_SIZE);
    }

    /// @dev Closes the gap left by step 2: the `to` branch of _update on the mint path.
    function test_mint_revertsForUnapprovedRecipient() public {
        address issuer = _issuer();

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, ALICE));
        vm.prank(issuer);
        bond.mint(ALICE, ISSUE_SIZE);
    }

    function test_mint_emitsAttributedEvent() public {
        _approve(ALICE);
        address issuer = _issuer();

        vm.expectEmit(true, true, true, true);
        emit AssetToken.Minted(ALICE, ISSUE_SIZE, issuer);
        vm.prank(issuer);
        bond.mint(ALICE, ISSUE_SIZE);
    }

    function test_mint_requiresIssuerRole() public {
        _approve(ALICE);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, issuerRole)
        );
        vm.prank(STRANGER);
        bond.mint(ALICE, ISSUE_SIZE);
    }

    function test_mint_blockedWhilePaused() public {
        _approve(ALICE);
        address issuer = _issuer();

        vm.prank(_pauser());
        bond.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(issuer);
        bond.mint(ALICE, ISSUE_SIZE);
    }

    // -- burn ----------------------------------------------------------------------------

    /// @dev Redemption at maturity: the whole issue comes back to the issuer and is burned.
    function test_burn_redeemsFromIssuerOwnBalance() public {
        address issuer = _issuer();
        _approve(issuer);
        _approve(ALICE);

        vm.prank(issuer);
        bond.mint(ALICE, ISSUE_SIZE);

        // the holder delivers the bonds back
        vm.prank(ALICE);
        bond.transfer(issuer, ISSUE_SIZE);

        vm.expectEmit(true, true, true, true);
        emit AssetToken.Burned(issuer, ISSUE_SIZE, issuer);
        vm.prank(issuer);
        bond.burn(ISSUE_SIZE);

        assertEq(bond.totalSupply(), 0);
    }

    function test_burn_requiresIssuerRole() public {
        _fund(STRANGER, AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, issuerRole)
        );
        vm.prank(STRANGER);
        bond.burn(AMOUNT);
    }

    function test_burn_blockedWhilePaused() public {
        address issuer = _issuer();
        _approve(issuer);
        vm.prank(issuer);
        bond.mint(issuer, AMOUNT);

        vm.prank(_pauser());
        bond.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(issuer);
        bond.burn(AMOUNT);
    }

    /// @dev The invariant section 7 asks to be tested: because a burn skips the sender-side
    ///      checks, ISSUER_ROLE is the whole of the protection on balances. And there is no
    ///      burnFrom at all, so even the issuer cannot burn what it does not hold.
    function test_noPathReducesAnotherHoldersBalance() public {
        _approve(ALICE);
        address issuer = _issuer();
        vm.prank(issuer);
        bond.mint(ALICE, ISSUE_SIZE);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, issuerRole)
        );
        vm.prank(STRANGER);
        bond.burn(ISSUE_SIZE);

        // the issuer holds nothing, so its own burn path has nothing to take
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, issuer, 0, ISSUE_SIZE));
        vm.prank(issuer);
        bond.burn(ISSUE_SIZE);

        assertEq(bond.balanceOf(ALICE), ISSUE_SIZE);
        assertEq(bond.totalSupply(), ISSUE_SIZE);
    }

    // -- forceTransfer: the two-key control, without moving supply (section 8) -----------

    address internal constant NEW_OWNER = address(0x0E0);

    /// @dev Alice holds the issue, is frozen, and the issuer is ready to act.
    function _seizureReady() private returns (address issuer, address officer) {
        _approve(ALICE);
        _approve(NEW_OWNER);
        issuer = _issuer();
        vm.prank(issuer);
        bond.mint(ALICE, ISSUE_SIZE);
        officer = _officer();
        vm.prank(officer);
        bond.freeze(ALICE, REASON);
    }

    function test_forceTransfer_revertsUnlessFrozen() public {
        _approve(ALICE);
        _approve(NEW_OWNER);
        address issuer = _issuer();
        vm.prank(issuer);
        bond.mint(ALICE, ISSUE_SIZE);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.AccountNotFrozen.selector, ALICE));
        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);
    }

    function test_forceTransfer_movesBondsOnceFrozen() public {
        (address issuer,) = _seizureReady();

        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);

        assertEq(bond.balanceOf(ALICE), 0);
        assertEq(bond.balanceOf(NEW_OWNER), ISSUE_SIZE);
    }

    /// @dev The whole point of the section: the issue size never moves.
    function test_forceTransfer_leavesTotalSupplyUnchanged() public {
        (address issuer,) = _seizureReady();
        uint256 before = bond.totalSupply();

        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);

        assertEq(bond.totalSupply(), before);
        assertEq(bond.totalSupply(), ISSUE_SIZE);
    }

    /// @dev Distinguishable from an ordinary payment: a ForcedTransfer alongside the Transfer.
    function test_forceTransfer_emitsBothEvents() public {
        (address issuer,) = _seizureReady();

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(ALICE, NEW_OWNER, ISSUE_SIZE);
        vm.expectEmit(true, true, true, true);
        emit AssetToken.ForcedTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON, issuer);
        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);
    }

    /// @dev The target is typically sanctioned and unapproved by the time a court order
    ///      exists. The sender-side checks are skipped so the function works exactly then.
    function test_forceTransfer_worksOnSanctionedHolder() public {
        (address issuer,) = _seizureReady();
        registry.setSanctioned(ALICE, true);
        assertFalse(registry.isApproved(ALICE));

        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);

        assertEq(bond.balanceOf(NEW_OWNER), ISSUE_SIZE);
    }

    /// @dev super._update would treat a zero recipient as a burn, and a burn is exactly what
    ///      section 8 exists to prevent. The guard _transfer would have supplied is explicit.
    function test_forceTransfer_refusesZeroRecipient() public {
        (address issuer,) = _seizureReady();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(issuer);
        bond.forceTransfer(ALICE, address(0), ISSUE_SIZE, REASON);

        assertEq(bond.totalSupply(), ISSUE_SIZE, "nothing burned");
    }

    /// @dev The mirror image: super._update would treat a zero sender as a mint. freeze has
    ///      no zero-address guard, so the guard has to be here.
    function test_forceTransfer_refusesZeroSender() public {
        (address issuer, address officer) = _seizureReady();

        vm.prank(officer);
        bond.freeze(address(0), REASON);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(issuer);
        bond.forceTransfer(address(0), NEW_OWNER, 100, REASON);

        assertEq(bond.totalSupply(), ISSUE_SIZE, "nothing minted");
    }

    /// @dev The bypass is sender-side only: isApproved(to) still runs.
    function test_forceTransfer_recipientMustStillBeApproved() public {
        (address issuer,) = _seizureReady();
        registry.setApproved(NEW_OWNER, false);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, NEW_OWNER));
        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);
    }

    function test_forceTransfer_requiresIssuerRole() public {
        (, address officer) = _seizureReady();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, officer, issuerRole)
        );
        vm.prank(officer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);
    }

    /// @dev Neither key completes a seizure alone (section 8).
    function test_forceTransfer_neitherRoleAloneCanSeize() public {
        _approve(ALICE);
        _approve(NEW_OWNER);
        address issuer = _issuer();
        vm.prank(issuer);
        bond.mint(ALICE, ISSUE_SIZE);

        // issuer alone: not frozen
        vm.expectRevert(abi.encodeWithSelector(AssetToken.AccountNotFrozen.selector, ALICE));
        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);

        // officer alone: freezes, but cannot move
        address officer = _officer();
        vm.prank(officer);
        bond.freeze(ALICE, REASON);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, officer, issuerRole)
        );
        vm.prank(officer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);

        assertEq(bond.balanceOf(ALICE), ISSUE_SIZE, "untouched by either role alone");
    }

    function test_forceTransfer_blockedWhilePaused() public {
        (address issuer,) = _seizureReady();
        vm.prank(_pauser());
        bond.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);
    }

    // -- the bypass is for that one call only (section 8) ----------------------------------

    /// @dev After a successful forced transfer, an ordinary transfer from a frozen sender
    ///      must still be refused: nothing about the bypass persists.
    function test_forceTransfer_leavesOrdinaryChecksIntactAfterSuccess() public {
        (address issuer,) = _seizureReady();

        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE / 2, REASON);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.SenderFrozen.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(NEW_OWNER, 1);
    }

    /// @dev A forced transfer that reverts on the recipient check must leave nothing behind
    ///      that loosens an ordinary transfer afterwards.
    function test_forceTransfer_leavesOrdinaryChecksIntactAfterRevert() public {
        (address issuer,) = _seizureReady();
        registry.setApproved(NEW_OWNER, false);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, NEW_OWNER));
        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);

        // Same transaction context: if anything leaked, this frozen sender could transfer.
        _approve(BOB);
        vm.expectRevert(abi.encodeWithSelector(AssetToken.SenderFrozen.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(BOB, 1);
    }

    // -- non-cooperative redemption composes from the primitives (section 7) ---------------

    /// @dev forceTransfer to the issuer, then burn. Supply is correct at every step.
    function test_mandatoryRedemption_neverLeavesSupplyWrong() public {
        (address issuer,) = _seizureReady();
        _approve(issuer);

        vm.prank(issuer);
        bond.forceTransfer(ALICE, issuer, ISSUE_SIZE, REASON);
        assertEq(bond.totalSupply(), ISSUE_SIZE, "bonds moved, none destroyed yet");
        assertEq(bond.balanceOf(issuer), ISSUE_SIZE);

        vm.prank(issuer);
        bond.burn(ISSUE_SIZE);
        assertEq(bond.totalSupply(), 0, "supply falls only once the issuer actually holds them");
    }

    // -- previewing the checks (section 3) -----------------------------------------------

    function _selectorOf(bytes memory err) private pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(err, 0x20))
        }
    }

    /// @dev Whatever `canTransfer` reports is exactly what the real call reverts with.
    function _assertPreviewMatchesReality(address from, address to, uint256 value) private {
        (bool ok, bytes4 reason) = bond.canTransfer(from, to, value);

        vm.prank(from);
        (bool succeeded, bytes memory err) =
            address(bond).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));

        assertEq(succeeded, ok, "preview disagreed on whether the call would succeed");
        if (!ok) assertEq(_selectorOf(err), reason, "preview named a different error");
    }

    function test_canTransfer_trueWhenEverythingPasses() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        (bool ok, bytes4 reason) = bond.canTransfer(ALICE, BOB, AMOUNT);

        assertTrue(ok);
        assertEq(reason, bytes4(0));
    }

    function test_canTransfer_reportsUnapprovedSender() public {
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        (bool ok, bytes4 reason) = bond.canTransfer(ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, AssetToken.NotApproved.selector);
        _assertPreviewMatchesReality(ALICE, BOB, AMOUNT);
    }

    function test_canTransfer_reportsFrozenSender() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        vm.prank(_officer());
        bond.freeze(ALICE, REASON);

        (bool ok, bytes4 reason) = bond.canTransfer(ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, AssetToken.SenderFrozen.selector);
        _assertPreviewMatchesReality(ALICE, BOB, AMOUNT);
    }

    function test_canTransfer_reportsPause() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        vm.prank(_pauser());
        bond.pause();

        (bool ok, bytes4 reason) = bond.canTransfer(ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, Pausable.EnforcedPause.selector);
        _assertPreviewMatchesReality(ALICE, BOB, AMOUNT);
    }

    function test_canTransfer_reportsInsufficientBalance() public {
        _approve(ALICE);
        _approve(BOB);

        (bool ok, bytes4 reason) = bond.canTransfer(ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, IERC20Errors.ERC20InsufficientBalance.selector);
        _assertPreviewMatchesReality(ALICE, BOB, AMOUNT);
    }

    /// @dev No tier, no limits: an address the cash leg would refuse with TierUnset previews
    ///      as fine here. Pins the section 4 difference on the preview path too.
    function test_canTransfer_needsNoTier() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        assertEq(uint8(registry.tierOf(ALICE)), 0, "UNSET");

        (bool ok,) = bond.canTransfer(ALICE, BOB, AMOUNT);

        assertTrue(ok);
    }

    function test_canTransfer_doesNotMutateState() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        bond.canTransfer(ALICE, BOB, AMOUNT);

        assertEq(bond.balanceOf(ALICE), AMOUNT);
        assertEq(bond.balanceOf(BOB), 0);
    }

    // -- canTransferFrom ------------------------------------------------------------------

    function test_canTransferFrom_trueForUnapprovedSpender() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        assertFalse(registry.isApproved(SETTLEMENT));

        (bool ok, bytes4 reason) = bond.canTransferFrom(SETTLEMENT, ALICE, BOB, AMOUNT);

        assertTrue(ok, "a settlement contract must preview as able to deliver bonds");
        assertEq(reason, bytes4(0));
    }

    function test_canTransferFrom_reportsSanctionedSpender() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);
        registry.setSanctioned(SETTLEMENT, true);

        (bool ok, bytes4 reason) = bond.canTransferFrom(SETTLEMENT, ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, AssetToken.SpenderSanctioned.selector);
    }

    function test_canTransferFrom_reportsMissingAllowance() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        (bool ok, bytes4 reason) = bond.canTransferFrom(SETTLEMENT, ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, IERC20Errors.ERC20InsufficientAllowance.selector);
    }

    function test_canTransferFrom_sanctionsOutrankMissingAllowance() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        registry.setSanctioned(SETTLEMENT, true);

        (, bytes4 reason) = bond.canTransferFrom(SETTLEMENT, ALICE, BOB, AMOUNT);

        assertEq(reason, AssetToken.SpenderSanctioned.selector);
    }

    function test_canTransferFrom_stillReportsSenderSideFailures() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);
        vm.prank(_officer());
        bond.freeze(ALICE, REASON);

        (bool ok, bytes4 reason) = bond.canTransferFrom(SETTLEMENT, ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, AssetToken.SenderFrozen.selector);
    }

    // -- the preview and a forced transfer cannot disagree ---------------------------------

    /// @dev A preview is never a forced transfer: it reports a frozen sender as frozen, even
    ///      though the issuer could move those bonds with forceTransfer. The preview answers
    ///      "would a transfer work", not "could anyone move this".
    function test_canTransfer_frozenSenderPreviewsAsFrozenNotForceable() public {
        (address issuer,) = _seizureReady();

        (bool ok, bytes4 reason) = bond.canTransfer(ALICE, NEW_OWNER, ISSUE_SIZE);
        assertFalse(ok);
        assertEq(reason, AssetToken.SenderFrozen.selector);

        // and yet the forced path goes through, because it never runs the override a preview does
        vm.prank(issuer);
        bond.forceTransfer(ALICE, NEW_OWNER, ISSUE_SIZE, REASON);
        assertEq(bond.balanceOf(NEW_OWNER), ISSUE_SIZE);
    }

    // -- the preview machinery itself -----------------------------------------------------

    function test_previewTransfer_revertsWithTheRealError() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        vm.prank(_officer());
        bond.freeze(ALICE, REASON);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.SenderFrozen.selector, ALICE));
        bond.previewTransfer(ALICE, BOB, AMOUNT);
    }

    function test_previewTransfer_returnsQuietlyWhenItWouldSucceed() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        bond.previewTransfer(ALICE, BOB, AMOUNT);
    }
}
