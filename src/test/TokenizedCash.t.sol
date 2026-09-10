// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";

/// @notice Step 1: construction, immutables, roles and denomination.
contract TokenizedCashTest is Test {
    TokenizedCash internal cash;

    IKYCRegistryV2 internal constant REGISTRY = IKYCRegistryV2(address(0xCEC15));
    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant STRANGER = address(0x5747);

    bytes3 internal constant EUR = bytes3("EUR");

    // Cached because reading one off the contract is itself a call, which would consume a
    // pending vm.prank before the call under test ever runs.
    bytes32 internal adminRole;
    bytes32 internal issuerRole;
    bytes32 internal officerRole;
    bytes32 internal pauserRole;

    function setUp() public {
        cash = new TokenizedCash("Tokenized Euro", "tEUR", EUR, REGISTRY, ADMIN);

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
        assertEq(address(cash.registry()), address(REGISTRY));
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
        new TokenizedCash("Tokenized Euro", "tEUR", EUR, REGISTRY, address(0));
    }

    function test_constructor_revertsOnZeroCurrency() public {
        vm.expectRevert(TokenizedCash.InvalidConfiguration.selector);
        new TokenizedCash("Tokenized Euro", "tEUR", bytes3(0), REGISTRY, ADMIN);
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
}
