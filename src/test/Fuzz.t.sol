// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice Stateless properties: one random input, one assertion, many runs. These target
///         the arithmetic the unit tests pin with hand-picked values.
contract FuzzTest is Test {
    MockKYCRegistry internal registry;
    TokenizedCash internal cash;
    DvPSettlement internal dvp;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant ALICE = address(0xA11);
    address internal constant BOB = address(0xB0B);
    address internal constant SELLER = address(0x5E11);

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new MockKYCRegistry();
        cash = new TokenizedCash("tEUR", "tEUR", bytes3("EUR"), IKYCRegistryV2(address(registry)), ADMIN);
        dvp = new DvPSettlement();

        bytes32 issuer = cash.ISSUER_ROLE();
        vm.prank(ADMIN);
        cash.grantRole(issuer, ISSUER);

        for (uint256 i = 0; i < 3; i++) {
            address a = [ALICE, BOB, ISSUER][i];
            registry.setApproved(a, true);
            registry.setTier(a, Tier.RETAIL);
        }
    }

    // -- the daily accumulator (cash section 4) --------------------------------------------

    /// @dev For any cap and any sequence of amounts, the running total matches a plain sum
    ///      of the transfers that succeeded, and never exceeds the cap. The uint216
    ///      narrowing in _checkLimits is exercised across the whole range.
    function testFuzz_dailyAccumulatorIsExact(uint216 perDay, uint256[8] calldata amounts) public {
        perDay = uint216(bound(perDay, 1, type(uint216).max));
        uint256 noLimit = cash.NO_LIMIT();
        vm.prank(ADMIN);
        cash.setTierLimits(Tier.RETAIL, noLimit, perDay);

        // Enough that the balance never binds before the cap does, for any cap in range.
        vm.prank(ISSUER);
        cash.mint(ALICE, type(uint216).max);

        uint256 expected;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 v = bound(amounts[i], 0, uint256(perDay) / 2 + 1);
            vm.prank(ALICE);
            try cash.transfer(BOB, v) {
                expected += v;
            } catch (bytes memory err) {
                assertEq(bytes4(err), TokenizedCash.DailyLimitExceeded.selector);
                assertGt(expected + v, perDay, "refused only when it would have exceeded the cap");
            }
            assertEq(cash.dailySpent(ALICE), expected);
            assertLe(cash.dailySpent(ALICE), perDay);
        }
    }

    /// @dev Exactly at the cap succeeds; one more unit is refused. For any cap.
    function testFuzz_dailyCapBoundaryIsExact(uint216 perDay) public {
        perDay = uint216(bound(perDay, 1, type(uint128).max));
        uint256 noLimit = cash.NO_LIMIT();
        vm.prank(ADMIN);
        cash.setTierLimits(Tier.RETAIL, noLimit, perDay);
        vm.prank(ISSUER);
        cash.mint(ALICE, uint256(perDay) + 1);

        vm.prank(ALICE);
        cash.transfer(BOB, perDay);
        assertEq(cash.dailySpent(ALICE), perDay);

        vm.expectRevert(abi.encodeWithSelector(TokenizedCash.DailyLimitExceeded.selector, ALICE, 1, perDay, perDay));
        vm.prank(ALICE);
        cash.transfer(BOB, 1);
    }

    /// @dev The window is a calendar day: whatever the timestamp, the total resets at the
    ///      next multiple of 86,400 and not before.
    function testFuzz_dailyWindowResetsExactlyAtMidnight(uint256 ts, uint256 amount) public {
        ts = bound(ts, 1 days, 4_000_000_000);
        amount = bound(amount, 1, 100e6);
        uint256 noLimit = cash.NO_LIMIT();
        vm.prank(ADMIN);
        cash.setTierLimits(Tier.RETAIL, noLimit, 1_000e6);
        vm.prank(ISSUER);
        cash.mint(ALICE, 1_000e6);

        vm.warp(ts);
        vm.prank(ALICE);
        cash.transfer(BOB, amount);

        uint256 midnight = (ts / 1 days + 1) * 1 days;
        vm.warp(midnight - 1);
        assertEq(cash.dailySpent(ALICE), amount, "still the same day");
        vm.warp(midnight);
        assertEq(cash.dailySpent(ALICE), 0, "reset on the boundary");
    }

    // -- the terms hash (settlement section 2) -------------------------------------------

    /// @dev Any change to any field, or to the id or seller, changes the hash.
    function testFuzz_hashTermsIsSensitiveToEverything(
        DvPSettlement.Terms calldata a,
        uint256 idA,
        address sellerA,
        DvPSettlement.Terms calldata b,
        uint256 idB,
        address sellerB
    ) public view {
        // Split so no line wraps: formatter versions disagree on where to break a long &&.
        bool sameTrade = idA == idB && sellerA == sellerB && a.buyer == b.buyer;
        bool sameCash = a.cashToken == b.cashToken && a.currency == b.currency && a.cashAmount == b.cashAmount;
        bool sameAsset = a.assetToken == b.assetToken && a.isin == b.isin && a.assetAmount == b.assetAmount;
        bool same = sameTrade && sameCash && sameAsset && a.deadline == b.deadline;
        bytes32 ha = dvp.hashTerms(idA, sellerA, a);
        bytes32 hb = dvp.hashTerms(idB, sellerB, b);
        assertEq(ha == hb, same);
    }

    /// @dev Any hash other than the right one is refused with TermsMismatch, and nothing moves.
    function testFuzz_settleRefusesAnyWrongHash(bytes32 wrong, uint256 cashAmount, uint256 bondAmount) public {
        cashAmount = bound(cashAmount, 1, type(uint128).max);
        bondAmount = bound(bondAmount, 1, type(uint128).max);
        uint64 deadline = uint64(block.timestamp + 1 days);
        DvPSettlement.Terms memory t = DvPSettlement.Terms({
            buyer: BOB,
            cashToken: address(cash),
            currency: bytes3("EUR"),
            cashAmount: cashAmount,
            assetToken: address(0xB0BD),
            isin: bytes12("DE000A1EWWW0"),
            assetAmount: bondAmount,
            deadline: deadline
        });
        vm.prank(SELLER);
        uint256 id = dvp.propose(t);
        bytes32 right = dvp.hashTerms(id, SELLER, t);
        vm.assume(wrong != right);

        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TermsMismatch.selector, id));
        vm.prank(BOB);
        dvp.settle(id, wrong);

        assertEq(uint8(dvp.trades(id).status), uint8(DvPSettlement.Status.PROPOSED));
    }

    /// @dev A deadline is honoured to the second, for any deadline and any time after it.
    function testFuzz_settleRefusesAnyTimePastTheDeadline(uint64 deadline, uint64 later) public {
        deadline = uint64(bound(deadline, block.timestamp + 1, type(uint64).max - 1));
        later = uint64(bound(later, uint256(deadline) + 1, type(uint64).max));
        DvPSettlement.Terms memory t = DvPSettlement.Terms({
            buyer: BOB,
            cashToken: address(cash),
            currency: bytes3("EUR"),
            cashAmount: 1,
            assetToken: address(0xB0BD),
            isin: bytes12("DE000A1EWWW0"),
            assetAmount: 1,
            deadline: deadline
        });
        vm.prank(SELLER);
        uint256 id = dvp.propose(t);
        bytes32 h = dvp.hashTerms(id, SELLER, t);

        vm.warp(later);
        vm.expectRevert(abi.encodeWithSelector(DvPSettlement.TradeExpired.selector, id, deadline));
        vm.prank(BOB);
        dvp.settle(id, h);
    }
}
