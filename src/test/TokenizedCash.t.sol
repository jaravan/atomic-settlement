// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice Steps 1-7: construction, roles, the registry gate, freeze, pause, supply, limits
///         and the transfer previews.
contract TokenizedCashTest is Test {
    TokenizedCash internal cash;
    MockKYCRegistry internal registry;
    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant STRANGER = address(0x5747);
    address internal constant ALICE = address(0xA11);
    address internal constant BOB = address(0xB0B);
    address internal constant SETTLEMENT = address(0x5E77);

    bytes3 internal constant EUR = bytes3("EUR");

    // Cached because reading one off the contract is itself a call, which would consume a
    // pending vm.prank before the call under test ever runs.
    bytes32 internal adminRole;
    bytes32 internal issuerRole;
    bytes32 internal officerRole;
    bytes32 internal pauserRole;

    function setUp() public {
        registry = new MockKYCRegistry();
        cash = new TokenizedCash("Tokenized Euro", "tEUR", EUR, IKYCRegistryV2(address(registry)), ADMIN);

        // Uncapped by default so tests that are not about limits are not about limits.
        vm.startPrank(ADMIN);
        cash.setTierLimits(Tier.RETAIL, cash.NO_LIMIT(), cash.NO_LIMIT());
        cash.setTierLimits(Tier.INSTITUTIONAL, cash.NO_LIMIT(), cash.NO_LIMIT());
        cash.setTierLimits(Tier.CROSS_BORDER, cash.NO_LIMIT(), cash.NO_LIMIT());
        vm.stopPrank();

        adminRole = cash.DEFAULT_ADMIN_ROLE();
        issuerRole = cash.ISSUER_ROLE();
        officerRole = cash.COMPLIANCE_OFFICER_ROLE();
        pauserRole = cash.PAUSER_ROLE();
    }

    // -- construction ------------------------------------------------------------------

    function test_constructor_setsMetadata() public view {
        assertEq(cash.name(), "Tokenized Euro");
        assertEq(cash.symbol(), "tEUR");
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(cash.registry()), address(registry));
        assertEq(cash.currency(), EUR);
    }

    function test_constructor_startsWithNoSupply() public view {
        assertEq(cash.totalSupply(), 0);
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(TokenizedCash.InvalidConfiguration.selector);
        new TokenizedCash("Tokenized Euro", "tEUR", EUR, IKYCRegistryV2(address(0)), ADMIN);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(TokenizedCash.InvalidConfiguration.selector);
        new TokenizedCash("Tokenized Euro", "tEUR", EUR, IKYCRegistryV2(address(registry)), address(0));
    }

    function test_constructor_revertsOnZeroCurrency() public {
        vm.expectRevert(TokenizedCash.InvalidConfiguration.selector);
        new TokenizedCash("Tokenized Euro", "tEUR", bytes3(0), IKYCRegistryV2(address(registry)), ADMIN);
    }

    // -- denomination (section 8) --------------------------------------------------------

    function test_decimals_isSix() public view {
        assertEq(cash.decimals(), 6);
    }

    // -- roles (section 2) ---------------------------------------------------------------

    function test_roleIdentifiers() public view {
        assertEq(adminRole, bytes32(0));
        assertEq(issuerRole, keccak256("ISSUER_ROLE"));
        assertEq(officerRole, keccak256("COMPLIANCE_OFFICER_ROLE"));
        assertEq(pauserRole, keccak256("PAUSER_ROLE"));
    }

    function test_adminHoldsAdminRole() public view {
        assertTrue(cash.hasRole(adminRole, ADMIN));
    }

    function test_deployerHoldsNoRole() public view {
        assertFalse(cash.hasRole(adminRole, address(this)));
    }

    function test_operationalRolesStartUnheld() public view {
        assertFalse(cash.hasRole(issuerRole, ADMIN));
        assertFalse(cash.hasRole(officerRole, ADMIN));
        assertFalse(cash.hasRole(pauserRole, ADMIN));
    }

    /// @dev Admin is the role admin for all three, per the section 2 diagram.
    function test_adminGrantsEachOperationalRole() public {
        vm.startPrank(ADMIN);
        cash.grantRole(issuerRole, ISSUER);
        cash.grantRole(officerRole, OFFICER);
        cash.grantRole(pauserRole, OFFICER);
        vm.stopPrank();

        assertTrue(cash.hasRole(issuerRole, ISSUER));
        assertTrue(cash.hasRole(officerRole, OFFICER));
        assertTrue(cash.hasRole(pauserRole, OFFICER));
    }

    function test_adminRevokesRole() public {
        vm.prank(ADMIN);
        cash.grantRole(issuerRole, ISSUER);

        vm.prank(ADMIN);
        cash.revokeRole(issuerRole, ISSUER);

        assertFalse(cash.hasRole(issuerRole, ISSUER));
    }

    function test_strangerCannotGrantRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, adminRole)
        );
        vm.prank(STRANGER);
        cash.grantRole(issuerRole, ISSUER);
    }

    /// @dev Roles are procedurally separated, not cryptographically: admin can self-grant,
    ///      but the grant lands as a visible event first (section 2).
    function test_adminCanSelfGrantIssuer() public {
        vm.prank(ADMIN);
        cash.grantRole(issuerRole, ADMIN);

        assertTrue(cash.hasRole(issuerRole, ADMIN));
    }

    // -- the registry gate (sections 1, 3) -----------------------------------------------

    uint256 internal constant AMOUNT = 100e6;

    /// @dev Written directly rather than minted, because several tests need a holder whose
    ///      approval has lapsed -- a state mint cannot produce but the registry can.
    function _fund(address who, uint256 amount) private {
        deal(address(cash), who, amount, true);
    }

    function _approve(address who) private {
        registry.setApproved(who, true);
        registry.setTier(who, Tier.RETAIL);
    }

    /// @dev Approved but unclassified: the state section 4 says must revert, not default.
    function _approveWithoutTier(address who) private {
        registry.setApproved(who, true);
    }

    function _setLimits(Tier tier, uint256 perTx, uint256 perDay) private {
        vm.prank(ADMIN);
        cash.setTierLimits(tier, perTx, perDay);
    }

    function test_transfer_succeedsWhenBothApproved() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);

        assertEq(cash.balanceOf(ALICE), 0);
        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    function test_transfer_revertsWhenSenderNotApproved() public {
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    function test_transfer_revertsWhenRecipientNotApproved() public {
        _approve(ALICE);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, BOB));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    /// @dev A sanctioned holder fails isApproved, so it is stopped as an unapproved sender
    ///      rather than by a separate sanctions check (section 3).
    function test_transfer_revertsWhenSenderSanctioned() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        registry.setSanctioned(ALICE, true);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    function test_transfer_gatesZeroValue() public {
        _approve(ALICE);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, BOB));
        vm.prank(ALICE);
        cash.transfer(BOB, 0);
    }

    // -- transferFrom: the spender (section 3) -------------------------------------------

    /// @dev The property the whole settlement design rests on: the spender is never asked
    ///      to be isApproved, because a contract can never be.
    function test_transferFrom_spenderNeedNotBeApproved() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        assertFalse(registry.isApproved(SETTLEMENT), "settlement contract is deliberately unapproved");

        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);

        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    function test_transferFrom_revertsWhenSpenderSanctioned() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        registry.setSanctioned(SETTLEMENT, true);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.SpenderSanctioned.selector, SETTLEMENT));
        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);
    }

    /// @dev The spender check runs before the allowance is consulted, so a sanctioned
    ///      spender is named as sanctioned rather than as merely unapproved for the amount.
    function test_transferFrom_spenderCheckPrecedesAllowance() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        registry.setSanctioned(SETTLEMENT, true);

        assertEq(cash.allowance(ALICE, SETTLEMENT), 0);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.SpenderSanctioned.selector, SETTLEMENT));
        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);
    }

    function test_transferFrom_stillGatesBothParties() public {
        _approve(ALICE);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, BOB));
        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);
    }

    // -- freeze (section 5) --------------------------------------------------------------

    bytes32 internal constant REASON = bytes32("SANCTIONS_HIT");

    function _officer() private returns (address) {
        vm.prank(ADMIN);
        cash.grantRole(officerRole, OFFICER);
        return OFFICER;
    }

    function test_freeze_blocksOutbound() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        assertTrue(cash.frozen(ALICE));

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.SenderFrozen.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    /// @dev Matches a frozen bank account: incoming payments land, nothing moves out.
    function test_freeze_stillAllowsInbound() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(_officer());
        cash.freeze(BOB, REASON);

        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);

        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    function test_unfreeze_restoresSending() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        address officer = _officer();
        vm.prank(officer);
        cash.freeze(ALICE, REASON);
        vm.prank(officer);
        cash.unfreeze(ALICE, REASON);

        assertFalse(cash.frozen(ALICE));

        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);

        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    function test_freeze_blocksTransferFrom() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.SenderFrozen.selector, ALICE));
        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);
    }

    /// @dev Freezing does not clear allowances (section 3): the approval survives, unusable
    ///      until the freeze lifts.
    function test_freeze_leavesAllowanceIntact() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        address officer = _officer();
        vm.prank(officer);
        cash.freeze(ALICE, REASON);

        assertEq(cash.allowance(ALICE, SETTLEMENT), AMOUNT, "allowance must survive the freeze");

        vm.prank(officer);
        cash.unfreeze(ALICE, REASON);

        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);

        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    /// @dev The unapproved check runs first, so a frozen-and-unapproved account reports the
    ///      registry problem rather than the freeze.
    function test_freeze_approvalCheckPrecedesFreezeCheck() public {
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    function test_freeze_emitsEventWithReasonAndCaller() public {
        address officer = _officer();

        vm.expectEmit(true, true, true, true);
        emit TokenizedCash.AccountFrozen(ALICE, REASON, officer);
        vm.prank(officer);
        cash.freeze(ALICE, REASON);

        vm.expectEmit(true, true, true, true);
        emit TokenizedCash.AccountUnfrozen(ALICE, REASON, officer);
        vm.prank(officer);
        cash.unfreeze(ALICE, REASON);
    }

    function test_freeze_isIdempotent() public {
        address officer = _officer();
        vm.prank(officer);
        cash.freeze(ALICE, REASON);
        vm.prank(officer);
        cash.freeze(ALICE, REASON);

        assertTrue(cash.frozen(ALICE));
    }

    function test_freeze_requiresComplianceOfficer() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, officerRole)
        );
        vm.prank(STRANGER);
        cash.freeze(ALICE, REASON);
    }

    /// @dev Admin holds the role-granting root but not the freeze power itself (section 2).
    function test_freeze_adminCannotFreezeWithoutGrantingItself() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, officerRole)
        );
        vm.prank(ADMIN);
        cash.freeze(ALICE, REASON);
    }

    function test_unfreeze_requiresComplianceOfficer() public {
        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, officerRole)
        );
        vm.prank(STRANGER);
        cash.unfreeze(ALICE, REASON);
    }

    // -- pause (section 6) ---------------------------------------------------------------

    function _pauser() private returns (address) {
        vm.prank(ADMIN);
        cash.grantRole(pauserRole, OFFICER);
        return OFFICER;
    }

    function test_pause_blocksTransfer() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(_pauser());
        cash.pause();

        assertTrue(cash.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    function test_pause_blocksTransferFrom() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        vm.prank(_pauser());
        cash.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);
    }

    /// @dev Blocked so a pause cannot be used to stage a drain for the moment it lifts.
    function test_pause_blocksApprove() public {
        _approve(ALICE);

        vm.prank(_pauser());
        cash.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);
    }

    /// @dev Views stay readable while paused (section 6).
    function test_pause_leavesViewsReadable() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        vm.prank(_pauser());
        cash.pause();

        assertEq(cash.balanceOf(ALICE), AMOUNT);
        assertEq(cash.allowance(ALICE, SETTLEMENT), AMOUNT);
        assertEq(cash.totalSupply(), AMOUNT);
        assertEq(cash.decimals(), 6);
        assertFalse(cash.frozen(ALICE));
    }

    function test_unpause_restoresTransfers() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        address pauser = _pauser();
        vm.prank(pauser);
        cash.pause();
        vm.prank(pauser);
        cash.unpause();

        assertFalse(cash.paused());

        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);

        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    /// @dev A pause is a network-incident control; it must not disarm the per-address one.
    function test_pause_doesNotBlockFreezing() public {
        vm.prank(_pauser());
        cash.pause();

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        assertTrue(cash.frozen(ALICE));
    }

    function test_pause_requiresPauserRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, pauserRole)
        );
        vm.prank(STRANGER);
        cash.pause();
    }

    function test_unpause_requiresPauserRole() public {
        vm.prank(_pauser());
        cash.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, pauserRole)
        );
        vm.prank(STRANGER);
        cash.unpause();
    }

    /// @dev The compliance officer role does not carry the emergency stop (section 2).
    function test_pause_complianceOfficerCannotPause() public {
        // Hoisted: the helper makes a call of its own, which vm.expectRevert would latch onto.
        address officer = _officer();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, officer, pauserRole)
        );
        vm.prank(officer);
        cash.pause();
    }

    // -- supply (section 7) --------------------------------------------------------------

    function _issuer() private returns (address) {
        vm.prank(ADMIN);
        cash.grantRole(issuerRole, ISSUER);
        return ISSUER;
    }

    function test_mint_creditsApprovedRecipient() public {
        _approve(ALICE);

        vm.prank(_issuer());
        cash.mint(ALICE, AMOUNT);

        assertEq(cash.balanceOf(ALICE), AMOUNT);
        assertEq(cash.totalSupply(), AMOUNT);
    }

    /// @dev Closes the gap left by step 2: the `to` branch of _update had no coverage on the
    ///      mint path, because nothing could mint yet.
    function test_mint_revertsForUnapprovedRecipient() public {
        address issuer = _issuer();

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, ALICE));
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);
    }

    function test_mint_emitsAttributedEvent() public {
        _approve(ALICE);
        address issuer = _issuer();

        vm.expectEmit(true, true, true, true);
        emit TokenizedCash.Minted(ALICE, AMOUNT, issuer);
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);
    }

    function test_mint_requiresIssuerRole() public {
        _approve(ALICE);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, issuerRole)
        );
        vm.prank(STRANGER);
        cash.mint(ALICE, AMOUNT);
    }

    function test_mint_blockedWhilePaused() public {
        _approve(ALICE);
        address issuer = _issuer();

        vm.prank(_pauser());
        cash.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);
    }

    // -- burn --------------------------------------------------------------------------

    function test_burn_takesFromIssuerOwnBalance() public {
        address issuer = _issuer();
        _approve(issuer);

        vm.prank(issuer);
        cash.mint(issuer, AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit TokenizedCash.Burned(issuer, AMOUNT, issuer);
        vm.prank(issuer);
        cash.burn(AMOUNT);

        assertEq(cash.balanceOf(issuer), 0);
        assertEq(cash.totalSupply(), 0);
    }

    function test_burn_requiresIssuerRole() public {
        _fund(STRANGER, AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, issuerRole)
        );
        vm.prank(STRANGER);
        cash.burn(AMOUNT);
    }

    // -- burnFrom: the two-key seizure control (sections 7, 9) ---------------------------

    function test_burnFrom_revertsUnlessFrozen() public {
        _approve(ALICE);
        address issuer = _issuer();
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.AccountNotFrozen.selector, ALICE));
        vm.prank(issuer);
        cash.burnFrom(ALICE, AMOUNT, REASON);
    }

    function test_burnFrom_succeedsOnceFrozen() public {
        _approve(ALICE);
        address issuer = _issuer();
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        vm.expectEmit(true, true, true, true);
        emit TokenizedCash.ForcedBurn(ALICE, AMOUNT, REASON, issuer);
        vm.prank(issuer);
        cash.burnFrom(ALICE, AMOUNT, REASON);

        assertEq(cash.balanceOf(ALICE), 0);
        assertEq(cash.totalSupply(), 0);
    }

    /// @dev A seizure target is typically sanctioned. Requiring isApproved would disable the
    ///      function exactly when it is needed, which is why a burn skips sender checks.
    function test_burnFrom_worksOnSanctionedHolder() public {
        _approve(ALICE);
        address issuer = _issuer();
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);
        registry.setSanctioned(ALICE, true);

        assertFalse(registry.isApproved(ALICE));

        vm.prank(issuer);
        cash.burnFrom(ALICE, AMOUNT, REASON);

        assertEq(cash.balanceOf(ALICE), 0);
    }

    function test_burnFrom_requiresIssuerRole() public {
        _fund(ALICE, AMOUNT);
        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OFFICER, issuerRole)
        );
        vm.prank(OFFICER);
        cash.burnFrom(ALICE, AMOUNT, REASON);
    }

    /// @dev The two keys must be two roles: an officer alone can freeze but not destroy, and
    ///      an issuer alone cannot burn what has not been frozen.
    function test_burnFrom_neitherRoleAloneCanSeize() public {
        _approve(ALICE);
        address issuer = _issuer();
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);

        // issuer alone: not frozen
        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.AccountNotFrozen.selector, ALICE));
        vm.prank(issuer);
        cash.burnFrom(ALICE, AMOUNT, REASON);

        // officer alone: freezes, but cannot burn
        address officer = _officer();
        vm.prank(officer);
        cash.freeze(ALICE, REASON);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, officer, issuerRole)
        );
        vm.prank(officer);
        cash.burnFrom(ALICE, AMOUNT, REASON);

        assertEq(cash.balanceOf(ALICE), AMOUNT, "balance untouched by either role alone");
    }

    function test_burnFrom_blockedWhilePaused() public {
        _approve(ALICE);
        address issuer = _issuer();
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);
        vm.prank(_pauser());
        cash.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(issuer);
        cash.burnFrom(ALICE, AMOUNT, REASON);
    }

    /// @dev The invariant section 7 asks to be tested explicitly: because a burn skips the
    ///      sender-side checks, ISSUER_ROLE is the whole of the protection on balances.
    function test_noPublicPathReducesAnotherHoldersBalance() public {
        _approve(ALICE);
        address issuer = _issuer();
        vm.prank(issuer);
        cash.mint(ALICE, AMOUNT);

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        // every supply-reducing entry point, called by someone without ISSUER_ROLE
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, issuerRole)
        );
        vm.prank(STRANGER);
        cash.burnFrom(ALICE, AMOUNT, REASON);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, issuerRole)
        );
        vm.prank(STRANGER);
        cash.burn(AMOUNT);

        assertEq(cash.balanceOf(ALICE), AMOUNT);
        assertEq(cash.totalSupply(), AMOUNT);
    }

    // -- transfer limits (section 4) -----------------------------------------------------

    uint256 internal constant PER_TX = 50e6;
    uint256 internal constant PER_DAY = 120e6;

    uint256 internal constant SOME_TIME = 1_700_000_000;

    /// @dev `ts` must be a typed variable: with two literals Solidity evaluates `/` as exact
    ///      rational arithmetic at compile time, so it would not truncate to a day boundary.
    function _nextUtcMidnightAfter(uint256 ts) private pure returns (uint256) {
        return (ts / 1 days + 1) * 1 days;
    }

    /// @dev Per-transaction uncapped, so a test about the daily window is only about that.
    function _retailPairDailyOnly() private {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, 1_000e6);
        _setLimits(Tier.RETAIL, cash.NO_LIMIT(), PER_DAY);
    }

    function _retailPair() private {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, 1_000e6);
        _setLimits(Tier.RETAIL, PER_TX, PER_DAY);
    }

    function test_limits_perTransactionAllowsExactly() public {
        _retailPair();

        vm.prank(ALICE);
        cash.transfer(BOB, PER_TX);

        assertEq(cash.balanceOf(BOB), PER_TX);
    }

    function test_limits_perTransactionRejectsOneOver() public {
        _retailPair();

        vm.expectRevert(
            abi.encodeWithSelector(TokenizedCash.TransactionLimitExceeded.selector, ALICE, PER_TX + 1, PER_TX)
        );
        vm.prank(ALICE);
        cash.transfer(BOB, PER_TX + 1);
    }

    function test_limits_dailyAccumulates() public {
        _retailPair();

        vm.startPrank(ALICE);
        cash.transfer(BOB, 50e6);
        assertEq(cash.dailySpent(ALICE), 50e6);
        cash.transfer(BOB, 50e6);
        assertEq(cash.dailySpent(ALICE), 100e6);
        vm.stopPrank();
    }

    function test_limits_dailyAllowsExactly() public {
        _retailPair();

        vm.startPrank(ALICE);
        cash.transfer(BOB, 50e6);
        cash.transfer(BOB, 50e6);
        cash.transfer(BOB, 20e6);
        vm.stopPrank();

        assertEq(cash.dailySpent(ALICE), PER_DAY);
        assertEq(cash.balanceOf(BOB), PER_DAY);
    }

    function test_limits_dailyRejectsOneOver() public {
        _retailPair();

        vm.startPrank(ALICE);
        cash.transfer(BOB, 50e6);
        cash.transfer(BOB, 50e6);
        cash.transfer(BOB, 20e6);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.DailyLimitExceeded.selector, ALICE, 1, PER_DAY, PER_DAY));
        cash.transfer(BOB, 1);
        vm.stopPrank();
    }

    /// @dev A calendar day, not a rolling 24 hours: crossing midnight UTC resets the total.
    function test_limits_dailyResetsAtUtcMidnight() public {
        _retailPairDailyOnly();

        vm.warp(SOME_TIME);

        vm.prank(ALICE);
        cash.transfer(BOB, PER_DAY);
        assertEq(cash.dailySpent(ALICE), PER_DAY);

        // the first second of the next UTC day
        vm.warp(_nextUtcMidnightAfter(SOME_TIME));
        assertEq(cash.dailySpent(ALICE), 0, "stale day must read as zero");

        vm.prank(ALICE);
        cash.transfer(BOB, PER_DAY);
        assertEq(cash.dailySpent(ALICE), PER_DAY);
    }

    /// @dev Section 4 states this openly: two days' allowance can be used either side of
    ///      midnight, because that is two days' limits used on two days.
    function test_limits_twiceTheCapAcrossMidnightIsIntended() public {
        _retailPairDailyOnly();

        uint256 lastSecond = _nextUtcMidnightAfter(SOME_TIME) - 1;
        vm.warp(lastSecond);
        vm.prank(ALICE);
        cash.transfer(BOB, PER_DAY);

        vm.warp(lastSecond + 1);
        vm.prank(ALICE);
        cash.transfer(BOB, PER_DAY);

        assertEq(cash.balanceOf(BOB), 2 * PER_DAY);
    }

    function test_limits_areTrackedPerSenderNotGlobally() public {
        _retailPairDailyOnly();
        _approve(SETTLEMENT);
        _fund(SETTLEMENT, 1_000e6);

        vm.prank(ALICE);
        cash.transfer(BOB, PER_DAY);

        assertEq(cash.dailySpent(SETTLEMENT), 0);

        vm.prank(SETTLEMENT);
        cash.transfer(BOB, PER_DAY);

        assertEq(cash.dailySpent(ALICE), PER_DAY);
        assertEq(cash.dailySpent(SETTLEMENT), PER_DAY);
    }

    // -- NO_LIMIT and failing closed -----------------------------------------------------

    function test_limits_noLimitTierIsUncapped() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, type(uint128).max);
        _setLimits(Tier.RETAIL, cash.NO_LIMIT(), cash.NO_LIMIT());

        vm.prank(ALICE);
        cash.transfer(BOB, type(uint128).max);

        assertEq(cash.balanceOf(BOB), type(uint128).max);
    }

    /// @dev An uncapped tier never pays for the accumulator it does not use.
    function test_limits_noLimitSkipsTheAccumulator() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, 1_000e6);
        _setLimits(Tier.RETAIL, cash.NO_LIMIT(), cash.NO_LIMIT());

        vm.prank(ALICE);
        cash.transfer(BOB, 100e6);

        assertEq(cash.dailySpent(ALICE), 0, "no accumulator write for an uncapped tier");
    }

    /// @dev Zero means zero: an unconfigured tier blocks rather than silently uncapping.
    function test_limits_unconfiguredTierFailsClosed() public {
        _approve(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);
        _setLimits(Tier.RETAIL, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.TransactionLimitExceeded.selector, ALICE, AMOUNT, 0));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    function test_limits_unsetTierReverts() public {
        _approveWithoutTier(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.TierUnset.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    // -- supply paths ignore limits (section 3) ------------------------------------------

    function test_limits_doNotApplyToMintOrBurn() public {
        _approve(ALICE);
        address issuer = _issuer();
        _approve(issuer);
        _setLimits(Tier.RETAIL, PER_TX, PER_DAY);

        vm.prank(issuer);
        cash.mint(ALICE, 10_000e6);

        assertEq(cash.balanceOf(ALICE), 10_000e6);
        assertEq(cash.dailySpent(ALICE), 0, "a mint consumes no allowance");

        vm.prank(_officer());
        cash.freeze(ALICE, REASON);
        vm.prank(issuer);
        cash.burnFrom(ALICE, 10_000e6, REASON);

        assertEq(cash.totalSupply(), 0);
    }

    // -- setTierLimits (section 2, 4) ----------------------------------------------------

    function test_setTierLimits_storesAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit TokenizedCash.TierLimitsSet(Tier.INSTITUTIONAL, PER_TX, PER_DAY, ADMIN);
        _setLimits(Tier.INSTITUTIONAL, PER_TX, PER_DAY);

        (uint256 perTx, uint256 perDay) = cash.tierLimits(Tier.INSTITUTIONAL);
        assertEq(perTx, PER_TX);
        assertEq(perDay, PER_DAY);
    }

    function test_setTierLimits_rejectsUnsetTier() public {
        vm.expectRevert(TokenizedCash.CannotConfigureUnsetTier.selector);
        vm.prank(ADMIN);
        cash.setTierLimits(Tier.UNSET, PER_TX, PER_DAY);
    }

    /// @dev The daily cap must fit the uint216 accumulator, or the narrowing would truncate.
    function test_setTierLimits_rejectsDailyCapAboveAccumulator() public {
        uint256 tooLarge = uint256(type(uint216).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.DailyLimitTooLarge.selector, tooLarge));
        vm.prank(ADMIN);
        cash.setTierLimits(Tier.RETAIL, PER_TX, tooLarge);
    }

    function test_setTierLimits_acceptsNoLimitAboveAccumulator() public {
        _setLimits(Tier.RETAIL, cash.NO_LIMIT(), cash.NO_LIMIT());

        (, uint256 perDay) = cash.tierLimits(Tier.RETAIL);
        assertEq(perDay, cash.NO_LIMIT());
    }

    /// @dev Limit policy is admin's, not compliance's: bundling them would let one hot key
    ///      raise every cap and silently disable the mechanism (section 2).
    function test_setTierLimits_complianceOfficerCannotSetThem() public {
        address officer = _officer();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, officer, adminRole)
        );
        vm.prank(officer);
        cash.setTierLimits(Tier.RETAIL, PER_TX, PER_DAY);
    }

    function test_setTierLimits_requiresAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, adminRole)
        );
        vm.prank(STRANGER);
        cash.setTierLimits(Tier.RETAIL, PER_TX, PER_DAY);
    }

    // -- previewing the checks (section 3) -----------------------------------------------

    function _selectorOf(bytes memory err) private pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(err, 0x20))
        }
    }

    /// @dev The property the previews exist for: whatever `canTransfer` reports is exactly
    ///      what the real call reverts with. Runs both and compares.
    function _assertPreviewMatchesReality(address from, address to, uint256 value) private {
        (bool ok, bytes4 reason) = cash.canTransfer(from, to, value);

        vm.prank(from);
        (bool succeeded, bytes memory err) =
            address(cash).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));

        assertEq(succeeded, ok, "preview disagreed on whether the call would succeed");
        if (!ok) assertEq(_selectorOf(err), reason, "preview named a different error");
    }

    function test_canTransfer_trueWhenEverythingPasses() public {
        _retailPair();

        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, PER_TX);

        assertTrue(ok);
        assertEq(reason, bytes4(0));
    }

    function test_canTransfer_reportsUnapprovedSender() public {
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, TokenizedCash.NotApproved.selector);
        _assertPreviewMatchesReality(ALICE, BOB, AMOUNT);
    }

    function test_canTransfer_reportsFrozenSender() public {
        _retailPair();
        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, PER_TX);

        assertFalse(ok);
        assertEq(reason, TokenizedCash.SenderFrozen.selector);
        _assertPreviewMatchesReality(ALICE, BOB, PER_TX);
    }

    function test_canTransfer_reportsTransactionLimit() public {
        _retailPair();

        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, PER_TX + 1);

        assertFalse(ok);
        assertEq(reason, TokenizedCash.TransactionLimitExceeded.selector);
        _assertPreviewMatchesReality(ALICE, BOB, PER_TX + 1);
    }

    function test_canTransfer_reportsDailyLimit() public {
        _retailPairDailyOnly();

        vm.prank(ALICE);
        cash.transfer(BOB, PER_DAY);

        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, 1);

        assertFalse(ok);
        assertEq(reason, TokenizedCash.DailyLimitExceeded.selector);
        _assertPreviewMatchesReality(ALICE, BOB, 1);
    }

    function test_canTransfer_reportsUnsetTier() public {
        _approveWithoutTier(ALICE);
        _approve(BOB);
        _fund(ALICE, AMOUNT);

        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, TokenizedCash.TierUnset.selector);
        _assertPreviewMatchesReality(ALICE, BOB, AMOUNT);
    }

    function test_canTransfer_reportsPause() public {
        _retailPair();
        vm.prank(_pauser());
        cash.pause();

        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, PER_TX);

        assertFalse(ok);
        assertEq(reason, Pausable.EnforcedPause.selector);
        _assertPreviewMatchesReality(ALICE, BOB, PER_TX);
    }

    /// @dev Not a compliance failure: the preview answers the whole question (section 3).
    function test_canTransfer_reportsInsufficientBalance() public {
        _approve(ALICE);
        _approve(BOB);
        _setLimits(Tier.RETAIL, cash.NO_LIMIT(), cash.NO_LIMIT());

        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, AMOUNT);

        assertFalse(ok);
        assertEq(reason, IERC20Errors.ERC20InsufficientBalance.selector);
        _assertPreviewMatchesReality(ALICE, BOB, AMOUNT);
    }

    /// @dev A view over state that can change next block: it must not write anything.
    function test_canTransfer_doesNotMutateState() public {
        _retailPair();

        cash.canTransfer(ALICE, BOB, PER_TX);

        assertEq(cash.dailySpent(ALICE), 0, "a preview must not consume allowance");
        assertEq(cash.balanceOf(ALICE), 1_000e6);
    }

    // -- canTransferFrom ------------------------------------------------------------------

    function test_canTransferFrom_trueForUnapprovedSpender() public {
        _retailPair();
        vm.prank(ALICE);
        cash.approve(SETTLEMENT, PER_TX);

        assertFalse(registry.isApproved(SETTLEMENT));

        (bool ok, bytes4 reason) = cash.canTransferFrom(SETTLEMENT, ALICE, BOB, PER_TX);

        assertTrue(ok, "a settlement contract must preview as able to move cash");
        assertEq(reason, bytes4(0));
    }

    function test_canTransferFrom_reportsSanctionedSpender() public {
        _retailPair();
        vm.prank(ALICE);
        cash.approve(SETTLEMENT, PER_TX);
        registry.setSanctioned(SETTLEMENT, true);

        (bool ok, bytes4 reason) = cash.canTransferFrom(SETTLEMENT, ALICE, BOB, PER_TX);

        assertFalse(ok);
        assertEq(reason, TokenizedCash.SpenderSanctioned.selector);
    }

    function test_canTransferFrom_reportsMissingAllowance() public {
        _retailPair();

        (bool ok, bytes4 reason) = cash.canTransferFrom(SETTLEMENT, ALICE, BOB, PER_TX);

        assertFalse(ok);
        assertEq(reason, IERC20Errors.ERC20InsufficientAllowance.selector);
    }

    /// @dev The spender check precedes the allowance check, mirroring the real call.
    function test_canTransferFrom_sanctionsOutrankMissingAllowance() public {
        _retailPair();
        registry.setSanctioned(SETTLEMENT, true);

        assertEq(cash.allowance(ALICE, SETTLEMENT), 0);

        (, bytes4 reason) = cash.canTransferFrom(SETTLEMENT, ALICE, BOB, PER_TX);

        assertEq(reason, TokenizedCash.SpenderSanctioned.selector);
    }

    function test_canTransferFrom_stillReportsSenderSideFailures() public {
        _retailPair();
        vm.prank(ALICE);
        cash.approve(SETTLEMENT, PER_TX);
        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        (bool ok, bytes4 reason) = cash.canTransferFrom(SETTLEMENT, ALICE, BOB, PER_TX);

        assertFalse(ok);
        assertEq(reason, TokenizedCash.SenderFrozen.selector);
    }

    // -- the preview machinery itself -----------------------------------------------------

    function test_previewTransfer_revertsWithTheRealError() public {
        _retailPair();
        vm.prank(_officer());
        cash.freeze(ALICE, REASON);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.SenderFrozen.selector, ALICE));
        cash.previewTransfer(ALICE, BOB, PER_TX);
    }

    function test_previewTransfer_returnsQuietlyWhenItWouldSucceed() public {
        _retailPair();
        cash.previewTransfer(ALICE, BOB, PER_TX);
    }
}
