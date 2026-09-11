// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {KYCRegistryFixture} from "./helpers/KYCRegistryFixture.sol";

/// @notice AssetToken against the real KYC registry, on the shared registry fixture.
abstract contract AssetTokenRegistryFixture is KYCRegistryFixture {
    AssetToken internal bond;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant ALICE = address(0xA11);
    address internal constant BOB = address(0xB0B);
    address internal constant SETTLEMENT = address(0x5E77);

    uint256 internal constant ISSUE_SIZE = 1_000;
    uint256 internal constant AMOUNT = 100;
    bytes32 internal constant REASON = bytes32("COURT_ORDER");

    function setUp() public virtual override {
        super.setUp();

        bond = new AssetToken("Bund 2035", "BUND35", bytes12("DE000A1EWWW0"), IKYCRegistryV2(address(registry)), ADMIN);

        bytes32 issuerRole = bond.ISSUER_ROLE();
        bytes32 officerRole = bond.COMPLIANCE_OFFICER_ROLE();
        vm.startPrank(ADMIN);
        bond.grantRole(issuerRole, ISSUER);
        bond.grantRole(officerRole, OFFICER);
        vm.stopPrank();
    }

    function _fund(address account, uint256 value) internal {
        vm.prank(ISSUER);
        bond.mint(account, value);
    }
}

/// @notice The states the mock cannot express, reached the way production reaches them.
contract AssetTokenRegistryTest is AssetTokenRegistryFixture {
    // -- the happy path, end to end -------------------------------------------------------

    function test_onboardedHolderCanTransfer() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    /// @dev The asset leg reads no tier. An approved but unclassified holder transacts here
    ///      where the cash leg refuses with TierUnset (section 4).
    function test_approvedButUnclassifiedCanTransfer() public {
        vm.startPrank(ORG_OFFICER);
        registry.approve(ALICE, expiry, ORG);
        registry.approve(BOB, expiry, ORG);
        vm.stopPrank();
        assertEq(uint8(registry.tierOf(ALICE)), uint8(Tier.UNSET));
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    function test_unonboardedAddressCannotReceive() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, BOB));
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    // -- states the mock cannot express ---------------------------------------------------

    function test_expiredApprovalStopsTransfers() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, AMOUNT);

        vm.warp(uint256(expiry) + 1);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(BOB, 1);
    }

    function test_renewalRestoresTransfers() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, AMOUNT);

        vm.warp(uint256(expiry) + 1);
        uint64 newExpiry = uint64(block.timestamp + 365 days);
        vm.startPrank(ORG_OFFICER);
        registry.renew(ALICE, newExpiry);
        registry.renew(BOB, newExpiry);
        vm.stopPrank();

        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    function test_suspensionStopsTransfers() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, AMOUNT);

        vm.prank(ORG_OFFICER);
        registry.suspend(ALICE);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    // -- sanctions ------------------------------------------------------------------------

    function test_sanctionedHolderCannotSend() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, AMOUNT);

        vm.prank(SANCTIONS_OFFICER);
        registry.setSanctioned(ALICE);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        bond.transfer(BOB, AMOUNT);
    }

    function test_sanctionedSpenderCannotDirectAtransfer() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, AMOUNT);
        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        vm.prank(SANCTIONS_OFFICER);
        registry.setSanctioned(SETTLEMENT);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.SpenderSanctioned.selector, SETTLEMENT));
        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);
    }

    function test_unapprovedSettlementContractCanStillDeliverBonds() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, AMOUNT);
        vm.prank(ALICE);
        bond.approve(SETTLEMENT, AMOUNT);

        assertFalse(registry.isApproved(SETTLEMENT), "never onboarded, and cannot be");

        vm.prank(SETTLEMENT);
        bond.transferFrom(ALICE, BOB, AMOUNT);

        assertEq(bond.balanceOf(BOB), AMOUNT);
    }

    // -- the court-order flow, end to end (section 8) --------------------------------------

    /// @dev Sanctioned, frozen, then moved -- and the issue size never changes.
    function test_seizureOfSanctionedHolderKeepsSupplyFixed() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, ISSUE_SIZE);

        vm.prank(SANCTIONS_OFFICER);
        registry.setSanctioned(ALICE);
        vm.prank(OFFICER);
        bond.freeze(ALICE, REASON);

        vm.prank(ISSUER);
        bond.forceTransfer(ALICE, BOB, ISSUE_SIZE, REASON);

        assertEq(bond.balanceOf(BOB), ISSUE_SIZE);
        assertEq(bond.totalSupply(), ISSUE_SIZE, "a fixed issue must not move");
    }

    /// @dev A seizure still needs an approved recipient: the court cannot order bonds into
    ///      the hands of someone the registry does not know.
    function test_seizureToUnonboardedRecipientReverts() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _fund(ALICE, ISSUE_SIZE);
        vm.prank(OFFICER);
        bond.freeze(ALICE, REASON);

        vm.expectRevert(abi.encodeWithSelector(AssetToken.NotApproved.selector, BOB));
        vm.prank(ISSUER);
        bond.forceTransfer(ALICE, BOB, ISSUE_SIZE, REASON);
    }

    /// @dev Mandatory redemption of a holder whose approval has lapsed: forceTransfer to the
    ///      issuer, then burn. Supply is right at every step.
    function test_mandatoryRedemptionOfExpiredHolder() public {
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(ISSUER, Tier.INSTITUTIONAL);
        _fund(ALICE, ISSUE_SIZE);

        vm.warp(uint256(expiry) + 1);
        vm.prank(ORG_OFFICER);
        registry.renew(ISSUER, uint64(block.timestamp + 365 days));
        assertFalse(registry.isApproved(ALICE), "lapsed");

        vm.prank(OFFICER);
        bond.freeze(ALICE, REASON);
        vm.prank(ISSUER);
        bond.forceTransfer(ALICE, ISSUER, ISSUE_SIZE, REASON);
        assertEq(bond.totalSupply(), ISSUE_SIZE);

        vm.prank(ISSUER);
        bond.burn(ISSUE_SIZE);
        assertEq(bond.totalSupply(), 0);
    }
}

/// @notice The real-registry counterpart to AssetGasTest, cold from setUp.
contract AssetTokenRegistryGasTest is AssetTokenRegistryFixture {
    function setUp() public override {
        super.setUp();
        _onboard(ALICE, Tier.INSTITUTIONAL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, ISSUE_SIZE);
        _fund(BOB, 1);
    }

    function test_gas_transferAgainstRealRegistry() public {
        vm.startPrank(ALICE);
        uint256 g = gasleft();
        bond.transfer(BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        bond.transfer(BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        emit log_named_uint("asset, real registry, transfer cold", cold);
        emit log_named_uint("asset, real registry, transfer warm", warm);
    }
}
