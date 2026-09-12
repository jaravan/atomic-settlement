// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice Steps 1-4: proposing, cancelling, the terms hash, and settling.
contract DvPSettlementTest is Test {
    DvPSettlement internal dvp;
    MockKYCRegistry internal registry;
    TokenizedCash internal cash;
    AssetToken internal bond;

    address internal constant SELLER = address(0x5E11);
    address internal constant BUYER = address(0xB0BB);
    address internal constant STRANGER = address(0x5747);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);

    // Set in setUp; the propose/cancel/hash tests only need them as addresses.
    address internal CASH;
    address internal BOND;

    bytes3 internal constant EUR = bytes3("EUR");
    bytes12 internal constant ISIN = bytes12("DE000A1EWWW0");
    uint256 internal constant CASH_AMOUNT = 10_000_000e6; // EUR 10m at six decimals
    uint256 internal constant BOND_AMOUNT = 100; // 100 bonds of EUR 100k nominal

    uint64 internal deadline;

    function setUp() public {
        vm.warp(1_700_000_000);
        deadline = uint64(block.timestamp + 1 days);

        registry = new MockKYCRegistry();
        cash = new TokenizedCash("Tokenized Euro", "tEUR", EUR, IKYCRegistryV2(address(registry)), ADMIN);
        bond = new AssetToken("Bund 2035", "BUND35", ISIN, IKYCRegistryV2(address(registry)), ADMIN);
        dvp = new DvPSettlement();
        CASH = address(cash);
        BOND = address(bond);

        bytes32 cashIssuer = cash.ISSUER_ROLE();
        bytes32 cashOfficer = cash.COMPLIANCE_OFFICER_ROLE();
        bytes32 bondIssuer = bond.ISSUER_ROLE();
        bytes32 bondOfficer = bond.COMPLIANCE_OFFICER_ROLE();
        vm.startPrank(ADMIN);
        cash.grantRole(cashIssuer, ISSUER);
        cash.grantRole(cashOfficer, OFFICER);
        cash.setTierLimits(Tier.INSTITUTIONAL, cash.NO_LIMIT(), cash.NO_LIMIT());
        bond.grantRole(bondIssuer, ISSUER);
        bond.grantRole(bondOfficer, OFFICER);
        vm.stopPrank();
    }

    /// @dev Both parties onboarded as institutions, funded, and with the allowances a
    ///      settlement needs: the seller's on the bond, the buyer's on the cash.
    function _readyToSettle() private returns (uint256 id) {
        registry.setApproved(SELLER, true);
        registry.setTier(SELLER, Tier.INSTITUTIONAL);
        registry.setApproved(BUYER, true);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);

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

    /// @dev What the buyer computes from its own record (section 2) -- locally, not via the
    ///      contract. Also keeps this an in-process read, so it cannot consume a vm.prank.
    function _buyersHash(uint256 id) private view returns (bytes32) {
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

    function _terms() private view returns (DvPSettlement.Terms memory) {
        return DvPSettlement.Terms({
            buyer: BUYER,
            cashToken: CASH,
            currency: EUR,
            cashAmount: CASH_AMOUNT,
            assetToken: BOND,
            isin: ISIN,
            assetAmount: BOND_AMOUNT,
            deadline: deadline
        });
    }

    // -- propose (section 3) -------------------------------------------------------------

    function test_propose_recordsTheTrade() public {
        vm.prank(SELLER);
        uint256 id = dvp.propose(_terms());

        DvPSettlement.Trade memory t = dvp.trades(id);
        assertEq(t.seller, SELLER);
        assertEq(t.buyer, BUYER);
        assertEq(t.cashToken, CASH);
        assertEq(t.cashAmount, CASH_AMOUNT);
        assertEq(t.assetToken, BOND);
        assertEq(t.assetAmount, BOND_AMOUNT);
        assertEq(t.currency, EUR);
        assertEq(t.isin, ISIN);
        assertEq(t.deadline, deadline);
        assertEq(uint8(t.status), uint8(DvPSettlement.Status.PROPOSED));
    }

    /// @dev The caller is the seller: the record binds the proposer to the asset side.
    function test_propose_callerIsTheSeller() public {
        vm.prank(STRANGER);
        uint256 id = dvp.propose(_terms());

        assertEq(dvp.trades(id).seller, STRANGER);
    }

    function test_propose_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit DvPSettlement.TradeProposed(1, SELLER, BUYER, CASH, CASH_AMOUNT, BOND, BOND_AMOUNT, deadline);
        vm.prank(SELLER);
        dvp.propose(_terms());
    }

    // -- tradeId is a counter (section 3) ------------------------------------------------

    function test_propose_idsStartAtOneAndIncrement() public {
        assertEq(dvp.nextTradeId(), 1);

        vm.startPrank(SELLER);
        assertEq(dvp.propose(_terms()), 1);
        assertEq(dvp.propose(_terms()), 2);
        assertEq(dvp.propose(_terms()), 3);
        vm.stopPrank();

        assertEq(dvp.nextTradeId(), 4);
    }

    /// @dev Rejected: a hash of the terms as the id. Two identical trades must not collide.
    function test_propose_identicalTradesGetDistinctIds() public {
        vm.startPrank(SELLER);
        uint256 a = dvp.propose(_terms());
        uint256 b = dvp.propose(_terms());
        vm.stopPrank();

        assertTrue(a != b);
        assertEq(uint8(dvp.trades(a).status), uint8(DvPSettlement.Status.PROPOSED));
        assertEq(uint8(dvp.trades(b).status), uint8(DvPSettlement.Status.PROPOSED));
    }

    function test_trades_unassignedIdIsNone() public view {
        assertEq(uint8(dvp.trades(0).status), uint8(DvPSettlement.Status.NONE));
        assertEq(uint8(dvp.trades(999).status), uint8(DvPSettlement.Status.NONE));
    }

    // -- validation ----------------------------------------------------------------------

    function test_propose_revertsOnZeroBuyer() public {
        DvPSettlement.Terms memory t = _terms();
        t.buyer = address(0);

        vm.expectRevert(DvPSettlement.InvalidTerms.selector);
        vm.prank(SELLER);
        dvp.propose(t);
    }

    function test_propose_revertsWhenBuyerIsSeller() public {
        DvPSettlement.Terms memory t = _terms();
        t.buyer = SELLER;

        vm.expectRevert(DvPSettlement.InvalidTerms.selector);
        vm.prank(SELLER);
        dvp.propose(t);
    }

    function test_propose_revertsOnZeroToken() public {
        DvPSettlement.Terms memory t = _terms();
        t.cashToken = address(0);
        vm.expectRevert(DvPSettlement.InvalidTerms.selector);
        vm.prank(SELLER);
        dvp.propose(t);

        t = _terms();
        t.assetToken = address(0);
        vm.expectRevert(DvPSettlement.InvalidTerms.selector);
        vm.prank(SELLER);
        dvp.propose(t);
    }

    function test_propose_revertsOnZeroAmount() public {
        DvPSettlement.Terms memory t = _terms();
        t.cashAmount = 0;
        vm.expectRevert(DvPSettlement.InvalidTerms.selector);
        vm.prank(SELLER);
        dvp.propose(t);

        t = _terms();
        t.assetAmount = 0;
        vm.expectRevert(DvPSettlement.InvalidTerms.selector);
        vm.prank(SELLER);
        dvp.propose(t);
    }

    function test_propose_revertsOnZeroIdentifier() public {
        DvPSettlement.Terms memory t = _terms();
        t.currency = bytes3(0);
        vm.expectRevert(DvPSettlement.InvalidTerms.selector);
        vm.prank(SELLER);
        dvp.propose(t);

        t = _terms();
        t.isin = bytes12(0);
        vm.expectRevert(DvPSettlement.InvalidTerms.selector);
        vm.prank(SELLER);
        dvp.propose(t);
    }

    // -- every proposal expires (section 4) ----------------------------------------------

    function test_propose_revertsOnPastDeadline() public {
        DvPSettlement.Terms memory t = _terms();
        t.deadline = uint64(block.timestamp - 1);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.DeadlineNotInFuture.selector, t.deadline));
        vm.prank(SELLER);
        dvp.propose(t);
    }

    /// @dev A deadline equal to now is already unusable, so it is rejected as not in the future.
    function test_propose_revertsOnDeadlineNow() public {
        DvPSettlement.Terms memory t = _terms();
        t.deadline = uint64(block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.DeadlineNotInFuture.selector, t.deadline));
        vm.prank(SELLER);
        dvp.propose(t);
    }

    function test_propose_revertsOnZeroDeadline() public {
        DvPSettlement.Terms memory t = _terms();
        t.deadline = 0;

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.DeadlineNotInFuture.selector, uint64(0)));
        vm.prank(SELLER);
        dvp.propose(t);
    }

    // -- cancel (section 3) --------------------------------------------------------------

    function _proposed() private returns (uint256 id) {
        vm.prank(SELLER);
        id = dvp.propose(_terms());
    }

    function test_cancel_marksTradeCancelled() public {
        uint256 id = _proposed();

        vm.prank(SELLER);
        dvp.cancel(id);

        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.CANCELLED));
    }

    /// @dev Both parties indexed: the buyer is the party a withdrawn offer actually affects,
    ///      so it must be able to find one addressed to it (section 8).
    function test_cancel_emitsEventNamingBothParties() public {
        uint256 id = _proposed();

        vm.expectEmit(true, true, true, true);
        emit DvPSettlement.TradeCancelled(id, SELLER, BUYER);
        vm.prank(SELLER);
        dvp.cancel(id);
    }

    /// @dev The record survives: cancelled is a terminal status, not a deletion.
    function test_cancel_leavesTermsReadable() public {
        uint256 id = _proposed();
        vm.prank(SELLER);
        dvp.cancel(id);

        DvPSettlement.Trade memory t = dvp.trades(id);
        assertEq(t.seller, SELLER);
        assertEq(t.cashAmount, CASH_AMOUNT);
    }

    // -- only the seller -----------------------------------------------------------------

    function test_cancel_buyerCannot() public {
        uint256 id = _proposed();

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.NotSeller.selector, id, BUYER));
        vm.prank(BUYER);
        dvp.cancel(id);
    }

    function test_cancel_strangerCannot() public {
        uint256 id = _proposed();

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.NotSeller.selector, id, STRANGER));
        vm.prank(STRANGER);
        dvp.cancel(id);
    }

    // -- only while PROPOSED -------------------------------------------------------------

    function test_cancel_twiceReverts() public {
        uint256 id = _proposed();
        vm.prank(SELLER);
        dvp.cancel(id);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeNotOpen.selector, id, DvPSettlement.Status.CANCELLED));
        vm.prank(SELLER);
        dvp.cancel(id);
    }

    function test_cancel_unassignedIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeNotOpen.selector, 42, DvPSettlement.Status.NONE));
        vm.prank(SELLER);
        dvp.cancel(42);
    }

    /// @dev The status check comes first, so a stranger probing an unassigned id learns it
    ///      is unassigned rather than being told it is not the seller of nothing.
    function test_cancel_statusCheckPrecedesSellerCheck() public {
        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeNotOpen.selector, 42, DvPSettlement.Status.NONE));
        vm.prank(STRANGER);
        dvp.cancel(42);
    }

    /// @dev Expiry is not a status. A seller can still cancel a lapsed proposal; it changes
    ///      nothing anyone could act on, but it is not refused (section 4).
    function test_cancel_expiredProposalIsAllowed() public {
        uint256 id = _proposed();
        vm.warp(uint256(deadline) + 1);

        vm.prank(SELLER);
        dvp.cancel(id);

        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.CANCELLED));
    }

    /// @dev One seller's cancel touches one trade, not every open proposal it has.
    function test_cancel_isPerTrade() public {
        vm.startPrank(SELLER);
        uint256 a = dvp.propose(_terms());
        uint256 b = dvp.propose(_terms());
        dvp.cancel(a);
        vm.stopPrank();

        assertEq(uint8(dvp.trades(a).status), uint8(DvPSettlement.Status.CANCELLED));
        assertEq(uint8(dvp.trades(b).status), uint8(DvPSettlement.Status.PROPOSED));
    }

    // -- the terms hash (section 2) ------------------------------------------------------

    function test_hashTerms_isDeterministic() public view {
        assertEq(dvp.hashTerms(1, SELLER, _terms()), dvp.hashTerms(1, SELLER, _terms()));
    }

    /// @dev Pins the layout, so an off-chain client can compute the same value from its own
    ///      record without calling the contract -- which section 2 says it must.
    function test_hashTerms_matchesDocumentedLayout() public view {
        DvPSettlement.Terms memory t = _terms();
        bytes32 expected = keccak256(
            abi.encode(
                block.chainid,
                address(dvp),
                uint256(1),
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
        assertEq(dvp.hashTerms(1, SELLER, t), expected);
    }

    // -- every term is load-bearing --------------------------------------------------------

    function test_hashTerms_changesWithTradeId() public view {
        assertTrue(dvp.hashTerms(1, SELLER, _terms()) != dvp.hashTerms(2, SELLER, _terms()));
    }

    function test_hashTerms_changesWithSeller() public view {
        assertTrue(dvp.hashTerms(1, SELLER, _terms()) != dvp.hashTerms(1, STRANGER, _terms()));
    }

    function test_hashTerms_changesWithEachField() public view {
        bytes32 base = dvp.hashTerms(1, SELLER, _terms());
        DvPSettlement.Terms memory t;

        t = _terms();
        t.buyer = STRANGER;
        assertTrue(dvp.hashTerms(1, SELLER, t) != base, "buyer");

        t = _terms();
        t.cashToken = STRANGER;
        assertTrue(dvp.hashTerms(1, SELLER, t) != base, "cashToken");

        t = _terms();
        t.currency = bytes3("USD");
        assertTrue(dvp.hashTerms(1, SELLER, t) != base, "currency");

        t = _terms();
        t.cashAmount = CASH_AMOUNT + 1;
        assertTrue(dvp.hashTerms(1, SELLER, t) != base, "cashAmount");

        t = _terms();
        t.assetToken = STRANGER;
        assertTrue(dvp.hashTerms(1, SELLER, t) != base, "assetToken");

        t = _terms();
        t.isin = bytes12("DE000A1EWWX8");
        assertTrue(dvp.hashTerms(1, SELLER, t) != base, "isin");

        t = _terms();
        t.assetAmount = BOND_AMOUNT + 1;
        assertTrue(dvp.hashTerms(1, SELLER, t) != base, "assetAmount");

        t = _terms();
        t.deadline = deadline + 1;
        assertTrue(dvp.hashTerms(1, SELLER, t) != base, "deadline");
    }

    /// @dev The two ordinary mistakes section 2 is built to catch: one extra zero, and the
    ///      right terms against the wrong id. Both change the hash.
    function test_hashTerms_catchesTheTwoOrdinaryMistakes() public view {
        bytes32 agreed = dvp.hashTerms(47, SELLER, _terms());

        DvPSettlement.Terms memory tenX = _terms();
        tenX.cashAmount = CASH_AMOUNT * 10;
        assertTrue(dvp.hashTerms(47, SELLER, tenX) != agreed, "10,000,000 typed as 100,000,000");

        assertTrue(dvp.hashTerms(48, SELLER, _terms()) != agreed, "meant 47, called 48");
    }

    // -- bound to this deployment and this chain --------------------------------------------

    function test_hashTerms_changesWithContractAddress() public {
        DvPSettlement other = new DvPSettlement();
        assertTrue(dvp.hashTerms(1, SELLER, _terms()) != other.hashTerms(1, SELLER, _terms()));
    }

    function test_hashTerms_changesWithChainId() public {
        bytes32 here = dvp.hashTerms(1, SELLER, _terms());
        vm.chainId(999);
        assertTrue(dvp.hashTerms(1, SELLER, _terms()) != here);
    }

    // -- settle: both legs move, or neither (sections 1, 3) --------------------------------

    function test_settle_movesBothLegs() public {
        uint256 id = _readyToSettle();

        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));

        assertEq(cash.balanceOf(SELLER), CASH_AMOUNT, "seller received the cash");
        assertEq(cash.balanceOf(BUYER), 0);
        assertEq(bond.balanceOf(BUYER), BOND_AMOUNT, "buyer received the bonds");
        assertEq(bond.balanceOf(SELLER), 0);
        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.SETTLED));
    }

    /// @dev The contract holds nothing, before, during or after (section 1).
    function test_settle_contractNeverHoldsEitherLeg() public {
        uint256 id = _readyToSettle();

        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));

        assertEq(cash.balanceOf(address(dvp)), 0);
        assertEq(bond.balanceOf(address(dvp)), 0);
    }

    function test_settle_emitsTermsInFull() public {
        uint256 id = _readyToSettle();

        vm.expectEmit(true, true, true, true);
        emit DvPSettlement.TradeSettled(id, SELLER, BUYER, CASH, CASH_AMOUNT, BOND, BOND_AMOUNT);
        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));
    }

    /// @dev Atomicity: if the second leg refuses, the first leg is rolled back too.
    function test_settle_isAtomic_assetLegRefusalUndoesCashLeg() public {
        uint256 id = _readyToSettle();
        vm.prank(SELLER);
        bond.approve(address(dvp), 0); // seller withdrew the bond allowance

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(dvp), 0, BOND_AMOUNT)
        );
        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));

        assertEq(cash.balanceOf(BUYER), CASH_AMOUNT, "cash did not move");
        assertEq(cash.balanceOf(SELLER), 0);
        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.PROPOSED), "still open");
    }

    /// @dev A failed settlement comes back with the token's own error, unchanged (section 5).
    function test_settle_surfacesTheTokensOwnError() public {
        uint256 id = _readyToSettle();
        vm.prank(OFFICER);
        cash.freeze(BUYER, bytes32("SANCTIONS_HIT"));

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.SenderFrozen.selector, BUYER));
        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));
    }

    // -- who may settle (section 3) --------------------------------------------------------

    function test_settle_onlyTheNamedBuyer() public {
        uint256 id = _readyToSettle();

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.NotBuyer.selector, id, STRANGER));
        vm.prank(STRANGER);
        dvp.settle(id, _buyersHash(id));

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.NotBuyer.selector, id, SELLER));
        vm.prank(SELLER);
        dvp.settle(id, _buyersHash(id));
    }

    // -- terminal states (section 3) --------------------------------------------------------

    function test_settle_twiceReverts() public {
        uint256 id = _readyToSettle();
        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeNotOpen.selector, id, DvPSettlement.Status.SETTLED));
        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));
    }

    function test_settle_cancelledReverts() public {
        uint256 id = _readyToSettle();
        vm.prank(SELLER);
        dvp.cancel(id);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeNotOpen.selector, id, DvPSettlement.Status.CANCELLED));
        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));
    }

    function test_settle_unassignedIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeNotOpen.selector, 42, DvPSettlement.Status.NONE));
        vm.prank(BUYER);
        dvp.settle(42, bytes32(0));
    }

    function test_cancel_afterSettleReverts() public {
        uint256 id = _readyToSettle();
        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeNotOpen.selector, id, DvPSettlement.Status.SETTLED));
        vm.prank(SELLER);
        dvp.cancel(id);
    }

    // -- every proposal expires (section 4) --------------------------------------------------

    function test_settle_atTheDeadlineSucceeds() public {
        uint256 id = _readyToSettle();
        vm.warp(deadline);

        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));

        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.SETTLED));
    }

    function test_settle_oneSecondPastTheDeadlineReverts() public {
        uint256 id = _readyToSettle();
        vm.warp(uint256(deadline) + 1);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeExpired.selector, id, deadline));
        vm.prank(BUYER);
        dvp.settle(id, _buyersHash(id));
    }

    /// @dev Expiry costs no transaction: the record is still PROPOSED, just unusable.
    function test_settle_expiredTradeStaysProposedInStorage() public {
        uint256 id = _readyToSettle();
        vm.warp(uint256(deadline) + 1);

        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.PROPOSED));
    }

    // -- two instructions must match (section 2) -------------------------------------------

    function test_settle_wrongHashReverts() public {
        uint256 id = _readyToSettle();

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TermsMismatch.selector, id));
        vm.prank(BUYER);
        dvp.settle(id, keccak256("not what I agreed"));
    }

    /// @dev The seller typed one extra zero. The buyer, asserting what it actually agreed,
    ///      is refused rather than paying ten times the price.
    function test_settle_catchesSellersExtraZero() public {
        registry.setApproved(SELLER, true);
        registry.setTier(SELLER, Tier.INSTITUTIONAL);
        registry.setApproved(BUYER, true);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);

        DvPSettlement.Terms memory fat = _terms();
        fat.cashAmount = CASH_AMOUNT * 10;
        vm.prank(SELLER);
        uint256 id = dvp.propose(fat);

        bytes32 whatBuyerAgreed = dvp.hashTerms(id, SELLER, _terms());

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TermsMismatch.selector, id));
        vm.prank(BUYER);
        dvp.settle(id, whatBuyerAgreed);
    }

    /// @dev Right terms, wrong id: proposals 47 and 48 on different terms, and the buyer
    ///      settles the one it did not mean. The id is in the hash, so it is refused.
    function test_settle_catchesWrongTradeId() public {
        uint256 first = _readyToSettle();
        DvPSettlement.Terms memory other = _terms();
        other.cashAmount = CASH_AMOUNT / 2;
        vm.prank(SELLER);
        uint256 second = dvp.propose(other);

        bytes32 hashForFirst = _buyersHash(first);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TermsMismatch.selector, second));
        vm.prank(BUYER);
        dvp.settle(second, hashForFirst);
    }

    // -- the addresses really are the instruments named (section 6) -------------------------

    function test_settle_wrongCurrencyReverts() public {
        registry.setApproved(SELLER, true);
        registry.setTier(SELLER, Tier.INSTITUTIONAL);
        registry.setApproved(BUYER, true);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);

        // the seller names USD, but the address is the euro token
        DvPSettlement.Terms memory t = _terms();
        t.currency = bytes3("USD");
        vm.prank(SELLER);
        uint256 id = dvp.propose(t);

        bytes32 h = dvp.hashTerms(id, SELLER, t); // hoisted: a call, which expectRevert would latch onto

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.WrongCurrency.selector, CASH, bytes3("USD"), EUR));
        vm.prank(BUYER);
        dvp.settle(id, h);
    }

    function test_settle_wrongInstrumentReverts() public {
        registry.setApproved(SELLER, true);
        registry.setTier(SELLER, Tier.INSTITUTIONAL);
        registry.setApproved(BUYER, true);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);

        // the seller names the 2040 issue, but the address is the 2035 token
        DvPSettlement.Terms memory t = _terms();
        t.isin = bytes12("DE000A1EWWX8");
        vm.prank(SELLER);
        uint256 id = dvp.propose(t);

        bytes32 h = dvp.hashTerms(id, SELLER, t);

        vm.expectRevert(
            abi.encodeWithSelector(DvPSettlement.WrongInstrument.selector, BOND, bytes12("DE000A1EWWX8"), ISIN)
        );
        vm.prank(BUYER);
        dvp.settle(id, h);
    }

    /// @dev Both parties agreed perfectly on the wrong address: the hash matches, and the
    ///      instrument check is what catches it. Two different controls (section 6).
    function test_settle_hashMatchDoesNotExcuseWrongInstrument() public {
        registry.setApproved(SELLER, true);
        registry.setTier(SELLER, Tier.INSTITUTIONAL);
        registry.setApproved(BUYER, true);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);

        AssetToken other =
            new AssetToken("Bund 2040", "BUND40", bytes12("DE000A1EWWX8"), IKYCRegistryV2(address(registry)), ADMIN);
        DvPSettlement.Terms memory t = _terms();
        t.assetToken = address(other); // both think this is the 2035 issue; it is not
        vm.prank(SELLER);
        uint256 id = dvp.propose(t);

        bytes32 agreedHash = dvp.hashTerms(id, SELLER, t);

        vm.expectRevert(
            abi.encodeWithSelector(
                DvPSettlement.WrongInstrument.selector, address(other), ISIN, bytes12("DE000A1EWWX8")
            )
        );
        vm.prank(BUYER);
        dvp.settle(id, agreedHash);
    }

    // -- check ordering: the same order canSettle will mirror -------------------------------

    /// @dev Status is checked before the hash, so an unassigned id is named as such rather
    ///      than as a mismatch against an empty record.
    function test_settle_statusOutranksHash() public {
        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeNotOpen.selector, 42, DvPSettlement.Status.NONE));
        vm.prank(BUYER);
        dvp.settle(42, keccak256("anything"));
    }

    /// @dev Expiry is checked before the hash: a stale proposal is named as expired even
    ///      when the buyer's hash would have matched.
    function test_settle_expiryOutranksHash() public {
        uint256 id = _readyToSettle();
        vm.warp(uint256(deadline) + 1);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeExpired.selector, id, deadline));
        vm.prank(BUYER);
        dvp.settle(id, keccak256("wrong anyway"));
    }

    /// @dev The hash is checked before the tokens are touched, so a mismatched instruction
    ///      never reaches a registry call.
    function test_settle_hashOutranksInstrumentCheck() public {
        registry.setApproved(SELLER, true);
        registry.setTier(SELLER, Tier.INSTITUTIONAL);
        registry.setApproved(BUYER, true);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);

        DvPSettlement.Terms memory t = _terms();
        t.currency = bytes3("USD"); // would fail WrongCurrency
        vm.prank(SELLER);
        uint256 id = dvp.propose(t);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TermsMismatch.selector, id));
        vm.prank(BUYER);
        dvp.settle(id, keccak256("also wrong"));
    }
}
