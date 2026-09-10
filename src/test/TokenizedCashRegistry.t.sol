// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {KYCRegistryFixture} from "./helpers/KYCRegistryFixture.sol";

/// @notice TokenizedCash against the real KYC registry. Adds the token on top of the shared
///         registry fixture; the asset leg gets its own suite on the same base.
abstract contract TokenizedCashRegistryFixture is KYCRegistryFixture {
    TokenizedCash internal cash;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant ALICE = address(0xA11);
    address internal constant BOB = address(0xB0B);
    address internal constant SETTLEMENT = address(0x5E77);

    uint256 internal constant AMOUNT = 100e6;

    function setUp() public virtual override {
        super.setUp();

        cash = new TokenizedCash("Tokenized Euro", "tEUR", bytes3("EUR"), IKYCRegistryV2(address(registry)), ADMIN);

        bytes32 issuerRole = cash.ISSUER_ROLE();
        bytes32 officerRole = cash.COMPLIANCE_OFFICER_ROLE();
        vm.startPrank(ADMIN);
        cash.grantRole(issuerRole, ISSUER);
        cash.grantRole(officerRole, OFFICER);
        cash.setTierLimits(Tier.RETAIL, 500e6, 1_000e6);
        cash.setTierLimits(Tier.INSTITUTIONAL, cash.NO_LIMIT(), cash.NO_LIMIT());
        vm.stopPrank();
    }

    function _fund(address account, uint256 value) internal {
        vm.prank(ISSUER);
        cash.mint(account, value);
    }
}

/// @notice Covers the states the mock cannot express -- expiry, suspension, org ownership --
///         and the onboarding sequence a holder actually goes through.
contract TokenizedCashRegistryTest is TokenizedCashRegistryFixture {
    // -- the happy path, end to end -------------------------------------------------------

    function test_onboardedHolderCanTransfer() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);

        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    function test_unonboardedAddressCannotReceive() public {
        _onboard(ALICE, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, BOB));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    /// @dev Approval without classification is not enough to transact (section 4).
    function test_approvedButUnclassifiedCannotSend() public {
        vm.prank(ORG_OFFICER);
        registry.approve(ALICE, expiry, ORG);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.TierUnset.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    // -- states the mock cannot express ---------------------------------------------------

    /// @dev The one the mock never modelled: approval lapses on its own, with no transaction.
    function test_expiredApprovalStopsTransfers() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.warp(uint256(expiry) + 1);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, 1);
    }

    /// @dev Renewing the sender alone is not enough: both parties must be current, and the
    ///      error names whichever one is not.
    function test_renewalRestoresTransfers() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.warp(uint256(expiry) + 1);
        uint64 newExpiry = uint64(block.timestamp + 365 days);

        vm.prank(ORG_OFFICER);
        registry.renew(ALICE, newExpiry);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, BOB));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);

        vm.prank(ORG_OFFICER);
        registry.renew(BOB, newExpiry);

        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);

        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    /// @dev A holder whose approval expired keeps a balance it cannot move -- the state the
    ///      token tests reproduce with `deal`, here reached the way production reaches it.
    function test_expiredHolderKeepsBalanceButCannotMoveIt() public {
        _onboard(ALICE, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.warp(uint256(expiry) + 1);

        assertEq(cash.balanceOf(ALICE), AMOUNT);
        (bool ok, bytes4 reason) = cash.canTransfer(ALICE, BOB, AMOUNT);
        assertFalse(ok);
        assertEq(reason, TokenizedCash.NotApproved.selector);
    }

    function test_suspensionStopsTransfers() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.prank(ORG_OFFICER);
        registry.suspend(ALICE);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    // -- sanctions, applied network-wide by a different role ------------------------------

    function test_sanctionedHolderCannotSend() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.prank(SANCTIONS_OFFICER);
        registry.setSanctioned(ALICE);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, ALICE));
        vm.prank(ALICE);
        cash.transfer(BOB, AMOUNT);
    }

    /// @dev A sanctioned spender is blocked even though it is nobody's client and so could
    ///      never be isApproved (section 3).
    function test_sanctionedSpenderCannotDirectAtransfer() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        vm.prank(SANCTIONS_OFFICER);
        registry.setSanctioned(SETTLEMENT);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.SpenderSanctioned.selector, SETTLEMENT));
        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);
    }

    function test_unapprovedSettlementContractCanStillMoveCash() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.prank(ALICE);
        cash.approve(SETTLEMENT, AMOUNT);

        assertFalse(registry.isApproved(SETTLEMENT), "never onboarded, and cannot be");

        vm.prank(SETTLEMENT);
        cash.transferFrom(ALICE, BOB, AMOUNT);

        assertEq(cash.balanceOf(BOB), AMOUNT);
    }

    /// @dev A seizure still works when the target is sanctioned and unapproved, which is the
    ///      situation it exists for (sections 7, 9).
    function test_seizureWorksOnSanctionedHolder() public {
        _onboard(ALICE, Tier.RETAIL);
        _fund(ALICE, AMOUNT);

        vm.prank(SANCTIONS_OFFICER);
        registry.setSanctioned(ALICE);
        vm.prank(OFFICER);
        cash.freeze(ALICE, bytes32("SANCTIONS_HIT"));

        vm.prank(ISSUER);
        cash.burnFrom(ALICE, AMOUNT, bytes32("SANCTIONS_HIT"));

        assertEq(cash.totalSupply(), 0);
    }

    // -- the tier actually drives the limit ------------------------------------------------

    function test_tierFromRegistrySelectsTheLimit() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.INSTITUTIONAL);
        _fund(ALICE, 10_000e6);
        _fund(BOB, 10_000e6);

        // RETAIL is capped at 500e6 per transaction
        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.TransactionLimitExceeded.selector, ALICE, 600e6, 500e6));
        vm.prank(ALICE);
        cash.transfer(BOB, 600e6);

        // INSTITUTIONAL is NO_LIMIT
        vm.prank(BOB);
        cash.transfer(ALICE, 5_000e6);

        assertEq(cash.dailySpent(BOB), 0, "an uncapped tier writes no accumulator");
    }

    /// @dev Reclassification takes effect on the next transfer, with no token-side change.
    function test_reclassificationChangesTheLimitImmediately() public {
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, 10_000e6);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.TransactionLimitExceeded.selector, ALICE, 600e6, 500e6));
        vm.prank(ALICE);
        cash.transfer(BOB, 600e6);

        vm.prank(ORG_OFFICER);
        registry.setTier(ALICE, Tier.INSTITUTIONAL);

        vm.prank(ALICE);
        cash.transfer(BOB, 600e6);

        assertEq(cash.balanceOf(BOB), 600e6);
    }
}

/// @notice The real-registry counterpart to `Gas.t.sol`. Onboarding and funding happen in
///         setUp, so the measured call starts from cold storage the way Gas.t.sol does --
///         otherwise the comparison is not like for like.
contract TokenizedCashRegistryGasTest is TokenizedCashRegistryFixture {
    function setUp() public override {
        super.setUp();
        _onboard(ALICE, Tier.RETAIL);
        _onboard(BOB, Tier.RETAIL);
        _fund(ALICE, 10_000e6);
        _fund(BOB, 1);
    }

    /// @dev Section 10's figures come from the mock. This is the same path against the real
    ///      registry behind a real UUPS proxy.
    function test_gas_transferAgainstRealRegistry() public {
        vm.startPrank(ALICE);
        uint256 g = gasleft();
        cash.transfer(BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        cash.transfer(BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        emit log_named_uint("real registry, transfer cold", cold);
        emit log_named_uint("real registry, transfer warm", warm);
    }
}
