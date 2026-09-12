// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";
import {KYCRegistryFixture} from "./helpers/KYCRegistryFixture.sol";

/// @notice All three contracts against the real KYC registry: the whole system, end to end.
abstract contract SettlementRegistryFixture is KYCRegistryFixture {
    TokenizedCash internal cash;
    AssetToken internal bond;
    DvPSettlement internal dvp;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant SELLER = address(0x5E11);
    address internal constant BUYER = address(0xB0BB);

    bytes3 internal constant EUR = bytes3("EUR");
    bytes12 internal constant ISIN = bytes12("DE000A1EWWW0");
    uint256 internal constant CASH_AMOUNT = 10_000_000e6;
    uint256 internal constant BOND_AMOUNT = 100;
    uint64 internal deadline;

    function setUp() public virtual override {
        super.setUp();
        deadline = uint64(block.timestamp + 1 days);

        cash = new TokenizedCash("Tokenized Euro", "tEUR", EUR, IKYCRegistryV2(address(registry)), ADMIN);
        bond = new AssetToken("Bund 2035", "BUND35", ISIN, IKYCRegistryV2(address(registry)), ADMIN);
        dvp = new DvPSettlement();

        bytes32 cashIssuer = cash.ISSUER_ROLE();
        bytes32 cashOfficer = cash.COMPLIANCE_OFFICER_ROLE();
        bytes32 bondIssuer = bond.ISSUER_ROLE();
        bytes32 bondOfficer = bond.COMPLIANCE_OFFICER_ROLE();
        uint256 noLimit = cash.NO_LIMIT();
        vm.startPrank(ADMIN);
        cash.grantRole(cashIssuer, ISSUER);
        cash.grantRole(cashOfficer, OFFICER);
        cash.setTierLimits(Tier.INSTITUTIONAL, noLimit, noLimit);
        cash.setTierLimits(Tier.RETAIL, 500e6, 1_000e6);
        bond.grantRole(bondIssuer, ISSUER);
        bond.grantRole(bondOfficer, OFFICER);
        vm.stopPrank();
    }

    /// @dev Both parties onboarded as institutions, funded, and with allowances in place.
    function _readyToSettle() internal returns (uint256 id) {
        _onboard(SELLER, Tier.INSTITUTIONAL);
        _onboard(BUYER, Tier.INSTITUTIONAL);

        vm.startPrank(ISSUER);
        cash.mint(BUYER, CASH_AMOUNT);
        bond.mint(SELLER, BOND_AMOUNT);
        vm.stopPrank();

        vm.prank(SELLER);
        bond.approve(address(dvp), BOND_AMOUNT);
        vm.prank(BUYER);
        cash.approve(address(dvp), CASH_AMOUNT);

        vm.prank(SELLER);
        id = dvp.propose(_terms());
    }

    function _terms() internal view returns (DvPSettlement.Terms memory) {
        return DvPSettlement.Terms({
            buyer: BUYER,
            cashToken: address(cash),
            currency: EUR,
            cashAmount: CASH_AMOUNT,
            assetToken: address(bond),
            isin: ISIN,
            assetAmount: BOND_AMOUNT,
            deadline: deadline
        });
    }

    /// @dev The buyer's own computation (integration notes section 4).
    function _buyersHash(uint256 id) internal view returns (bytes32) {
        DvPSettlement.Terms memory t = _terms();
        return keccak256(
            abi.encode(
                block.chainid,
                address(dvp),
                id,
                SELLER,
                t.buyer,
                t.cashToken,
                t.currency,
                t.cashAmount,
                t.assetToken,
                t.isin,
                t.assetAmount,
                t.deadline
            )
        );
    }
}

contract DvPSettlementRegistryTest is SettlementRegistryFixture {
    // -- the whole thing, once ----------------------------------------------------------

    function test_fullSettlement() public {
        uint256 id = _readyToSettle();
        bytes32 h = _buyersHash(id);

        (bool ok,) = dvp.canSettle(id, h);
        assertTrue(ok, "preview says go");

        vm.prank(BUYER);
        dvp.settle(id, h);

        assertEq(cash.balanceOf(SELLER), CASH_AMOUNT);
        assertEq(bond.balanceOf(BUYER), BOND_AMOUNT);
        assertEq(cash.balanceOf(address(dvp)), 0, "never custodied");
        assertEq(bond.balanceOf(address(dvp)), 0, "never custodied");
    }

    // -- the registry states no mock could produce, hit mid-trade ---------------------------

    /// @dev The buyer's approval lapses while the proposal sits open -- before the trade
    ///      deadline does. The seller's allowance still stands; the trade cannot settle.
    function test_buyerApprovalExpiresWhileProposalOpen() public {
        _onboard(SELLER, Tier.INSTITUTIONAL);
        // BUYER onboarded with an approval that runs out twelve hours before the trade does
        vm.startPrank(ORG_OFFICER);
        registry.approve(BUYER, uint64(block.timestamp + 12 hours), ORG);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);
        vm.stopPrank();
        vm.startPrank(ISSUER);
        cash.mint(BUYER, CASH_AMOUNT);
        bond.mint(SELLER, BOND_AMOUNT);
        vm.stopPrank();
        vm.prank(SELLER);
        bond.approve(address(dvp), BOND_AMOUNT);
        vm.prank(BUYER);
        cash.approve(address(dvp), CASH_AMOUNT);
        vm.prank(SELLER);
        uint256 id = dvp.propose(_terms());
        bytes32 h = _buyersHash(id);

        vm.warp(block.timestamp + 13 hours); // approval gone, trade still open

        (bool ok, bytes4 reason) = dvp.canSettle(id, h);
        assertFalse(ok);
        assertEq(reason, TokenizedCash.NotApproved.selector);
        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.PROPOSED), "trade itself is not expired");
    }

    function test_sellerSuspendedWhileProposalOpen() public {
        uint256 id = _readyToSettle();
        bytes32 h = _buyersHash(id);

        vm.prank(ORG_OFFICER);
        registry.suspend(SELLER);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.NotApproved.selector, SELLER));
        vm.prank(BUYER);
        dvp.settle(id, h);
    }

    /// @dev The kill switch the spender check exists for: sanction the settlement contract
    ///      and every trade through it stops, with neither token paused.
    function test_sanctioningTheSettlementContractHaltsIt() public {
        uint256 id = _readyToSettle();
        bytes32 h = _buyersHash(id);

        vm.prank(SANCTIONS_OFFICER);
        registry.setSanctioned(address(dvp));

        (bool ok, bytes4 reason) = dvp.canSettle(id, h);
        assertFalse(ok);
        assertEq(reason, TokenizedCash.SpenderSanctioned.selector);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.SpenderSanctioned.selector, address(dvp)));
        vm.prank(BUYER);
        dvp.settle(id, h);

        assertFalse(cash.paused());
        assertFalse(bond.paused());
    }

    /// @dev A retail buyer against a wholesale trade: the cash leg's cap binds and the
    ///      settlement surfaces the limit error unchanged (section 5).
    function test_retailBuyerHitsTheCashLegCap() public {
        _onboard(SELLER, Tier.INSTITUTIONAL);
        _onboard(BUYER, Tier.RETAIL);
        vm.startPrank(ISSUER);
        cash.mint(BUYER, CASH_AMOUNT);
        bond.mint(SELLER, BOND_AMOUNT);
        vm.stopPrank();
        vm.prank(SELLER);
        bond.approve(address(dvp), BOND_AMOUNT);
        vm.prank(BUYER);
        cash.approve(address(dvp), CASH_AMOUNT);
        vm.prank(SELLER);
        uint256 id = dvp.propose(_terms());
        bytes32 h = _buyersHash(id);

        (, bytes4 reason) = dvp.canSettle(id, h);
        assertEq(reason, TokenizedCash.TransactionLimitExceeded.selector);

        vm.expectRevert(
            abi.encodeWithSelector(TokenizedCash.TransactionLimitExceeded.selector, BUYER, CASH_AMOUNT, 500e6)
        );
        vm.prank(BUYER);
        dvp.settle(id, h);
    }

    /// @dev Reclassifying the buyer to INSTITUTIONAL unblocks the same proposal with no
    ///      change on the token or the settlement contract.
    function test_reclassificationUnblocksAnOpenProposal() public {
        _onboard(SELLER, Tier.INSTITUTIONAL);
        _onboard(BUYER, Tier.RETAIL);
        vm.startPrank(ISSUER);
        cash.mint(BUYER, CASH_AMOUNT);
        bond.mint(SELLER, BOND_AMOUNT);
        vm.stopPrank();
        vm.prank(SELLER);
        bond.approve(address(dvp), BOND_AMOUNT);
        vm.prank(BUYER);
        cash.approve(address(dvp), CASH_AMOUNT);
        vm.prank(SELLER);
        uint256 id = dvp.propose(_terms());
        bytes32 h = _buyersHash(id);

        (bool before,) = dvp.canSettle(id, h);
        assertFalse(before);

        vm.prank(ORG_OFFICER);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);

        vm.prank(BUYER);
        dvp.settle(id, h);
        assertEq(bond.balanceOf(BUYER), BOND_AMOUNT);
    }

    // -- a seizure on one leg does not touch an open trade on the other ---------------------

    /// @dev The seller is frozen and its bonds forcibly moved elsewhere while a proposal sits
    ///      open. The proposal is now undeliverable and fails on the asset leg's own error.
    function test_forcedTransferStrandsAnOpenProposal() public {
        uint256 id = _readyToSettle();
        bytes32 h = _buyersHash(id);
        address newOwner = address(0x0E0);
        _onboard(newOwner, Tier.INSTITUTIONAL);

        vm.prank(OFFICER);
        bond.freeze(SELLER, bytes32("COURT_ORDER"));
        vm.prank(ISSUER);
        bond.forceTransfer(SELLER, newOwner, BOND_AMOUNT, bytes32("COURT_ORDER"));

        (, bytes4 reason) = dvp.canSettle(id, h);
        assertEq(reason, AssetToken.SenderFrozen.selector, "frozen is checked before balance");

        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.PROPOSED), "the record is just stale");
    }
}

/// @notice The real-registry counterpart to SettlementGasTest, cold from setUp.
contract DvPSettlementRegistryGasTest is SettlementRegistryFixture {
    uint256 internal id;
    bytes32 internal h;

    function setUp() public override {
        super.setUp();
        id = _readyToSettle();
        h = _buyersHash(id);

        // As in SettlementGasTest: the receiving side of each leg already holds something,
        // so the measured writes are nonzero -> nonzero rather than the one-off slot creation.
        vm.startPrank(ISSUER);
        cash.mint(SELLER, 1);
        bond.mint(BUYER, 1);
        vm.stopPrank();
    }

    /// @dev Seven registry round trips through a real UUPS proxy, in one transaction.
    function test_gas_settleAgainstRealRegistry() public {
        vm.prank(BUYER);
        uint256 g = gasleft();
        dvp.settle(id, h);
        emit log_named_uint("settle, real registry   cold", g - gasleft());
    }
}
