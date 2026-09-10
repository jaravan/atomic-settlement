// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice Steps 1-2: construction, roles, denomination, and the registry gate.
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

    /// @dev Balances are written directly: mint arrives in step 5.
    function _fund(address who, uint256 amount) private {
        deal(address(cash), who, amount, true);
    }

    function _approve(address who) private {
        registry.setApproved(who, true);
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
}
