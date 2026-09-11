// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";

/// @notice Step 1: recording a proposal.
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
}
