// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";

/// @notice Steps 1-3: recording and withdrawing a proposal, and the terms hash.
contract DvPSettlementTest is Test {
    DvPSettlement internal dvp;

    address internal constant SELLER = address(0x5E11);
    address internal constant BUYER = address(0xB0BB);
    address internal constant STRANGER = address(0x5747);
    address internal constant CASH = address(0xCA54);
    address internal constant BOND = address(0xB0BD);

    bytes3 internal constant EUR = bytes3("EUR");
    bytes12 internal constant ISIN = bytes12("DE000A1EWWW0");
    uint256 internal constant CASH_AMOUNT = 10_000_000e6; // EUR 10m at six decimals
    uint256 internal constant BOND_AMOUNT = 100; // 100 bonds of EUR 100k nominal

    uint64 internal deadline;

    function setUp() public {
        vm.warp(1_700_000_000);
        deadline = uint64(block.timestamp + 1 days);
        dvp = new DvPSettlement();
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
}
