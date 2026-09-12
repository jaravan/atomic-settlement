// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice Drives the whole system with random actions. Every call is expected to either
///         succeed or revert with a contract error; the invariants below must hold after
///         each one regardless. Ghost variables track what the handler did so the
///         invariants can compare against it.
contract SystemHandler is Test {
    MockKYCRegistry public registry;
    TokenizedCash public cash;
    AssetToken public bond;
    DvPSettlement public dvp;

    address public constant ADMIN = address(0xA11CE);
    address public constant ISSUER = address(0x155);
    address public constant OFFICER = address(0x0FF);
    address public constant PAUSER = address(0x9A05);

    address[] public actors;

    // -- ghosts -------------------------------------------------------------------------
    uint256 public cashMinted;
    uint256 public cashBurned;
    uint256 public bondMinted;
    uint256 public bondBurned;
    uint256 public proposals;
    uint256 public settlements;
    uint256 public cancellations;
    mapping(uint256 tradeId => DvPSettlement.Status) public terminalStatus;
    mapping(uint256 tradeId => uint256) public settleCount;
    uint256 public retailTransfers;
    uint256 public dailyLimitHits;
    uint256 public txLimitHits;

    uint256 internal constant PER_TX = 500e6;
    uint256 internal constant PER_DAY = 1_000e6; // two full transfers, then the cap

    constructor() {
        vm.warp(1_700_000_000);
        registry = new MockKYCRegistry();
        cash = new TokenizedCash("tEUR", "tEUR", bytes3("EUR"), IKYCRegistryV2(address(registry)), ADMIN);
        bond = new AssetToken("BUND", "BUND", bytes12("DE000A1EWWW0"), IKYCRegistryV2(address(registry)), ADMIN);
        dvp = new DvPSettlement();

        bytes32 ci = cash.ISSUER_ROLE();
        bytes32 co = cash.COMPLIANCE_OFFICER_ROLE();
        bytes32 cp = cash.PAUSER_ROLE();
        bytes32 bi = bond.ISSUER_ROLE();
        bytes32 bo = bond.COMPLIANCE_OFFICER_ROLE();
        bytes32 bp = bond.PAUSER_ROLE();
        uint256 noLimit = cash.NO_LIMIT();
        vm.startPrank(ADMIN);
        cash.grantRole(ci, ISSUER);
        cash.grantRole(co, OFFICER);
        cash.grantRole(cp, PAUSER);
        bond.grantRole(bi, ISSUER);
        bond.grantRole(bo, OFFICER);
        bond.grantRole(bp, PAUSER);
        cash.setTierLimits(Tier.RETAIL, PER_TX, PER_DAY);
        cash.setTierLimits(Tier.INSTITUTIONAL, noLimit, noLimit);
        cash.setTierLimits(Tier.CROSS_BORDER, PER_TX, noLimit);
        vm.stopPrank();

        // A valid baseline to perturb from: everyone onboarded and funded. Two retail
        // actors exercise the daily cap; four institutional ones settle freely. Tiers are
        // fixed for the run: a downgrade mid-day would make dailySpent exceed the new cap,
        // which is correct behaviour but not a global invariant.
        for (uint160 i = 1; i <= 6; i++) {
            address a = address(0xA000 + i);
            actors.push(a);
            registry.setApproved(a, true);
            registry.setTier(a, i <= 2 ? Tier.RETAIL : Tier.INSTITUTIONAL);
        }
        registry.setApproved(ISSUER, true);
        registry.setTier(ISSUER, Tier.INSTITUTIONAL);

        vm.startPrank(ISSUER);
        for (uint256 i = 0; i < actors.length; i++) {
            cash.mint(actors[i], 1_000_000e6);
            bond.mint(actors[i], 10_000);
            cashMinted += 1_000_000e6;
            bondMinted += 10_000;
        }
        vm.stopPrank();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // -- registry ----------------------------------------------------------------------

    // Perturbations are biased toward the valid state -- one call in eight breaks
    // something, the rest restore -- so the constructive paths are actually reached.

    function setApproved(uint256 seed) external {
        registry.setApproved(_actor(seed), seed % 8 != 0);
    }

    function setSanctioned(uint256 seed) external {
        registry.setSanctioned(_actor(seed), seed % 8 == 0);
    }

    // -- supply ------------------------------------------------------------------------

    function mintCash(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 10_000e6);
        address to = _actor(seed);
        vm.prank(ISSUER);
        try cash.mint(to, amount) {
            cashMinted += amount;
        } catch {}
    }

    function mintBond(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 1_000);
        address to = _actor(seed);
        vm.prank(ISSUER);
        try bond.mint(to, amount) {
            bondMinted += amount;
        } catch {}
    }

    /// @dev The two-key sequence as one action: freeze, then burn. Each key separately.
    function seizeCash(uint256 seed, uint256 amount) external {
        address from = _actor(seed);
        amount = bound(amount, 0, cash.balanceOf(from));
        vm.prank(OFFICER);
        cash.freeze(from, bytes32("X"));
        vm.prank(ISSUER);
        try cash.burnFrom(from, amount, bytes32("X")) {
            cashBurned += amount;
        } catch {}
        vm.prank(OFFICER);
        cash.unfreeze(from, bytes32("X"));
    }

    /// @dev The asset leg's version: freeze, then move. Supply must not change.
    function seizeBond(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, bond.balanceOf(from));
        vm.prank(OFFICER);
        bond.freeze(from, bytes32("X"));
        vm.prank(ISSUER);
        try bond.forceTransfer(from, to, amount, bytes32("X")) {} catch {}
        vm.prank(OFFICER);
        bond.unfreeze(from, bytes32("X"));
    }

    // -- transfers and compliance --------------------------------------------------------

    function transferCash(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        // Up to a little over the per-transaction cap: retail hits both caps, institutional neither.
        amount = bound(amount, 0, _min(cash.balanceOf(from), PER_TX + PER_TX / 4));
        bool retail = registry.tierOf(from) == Tier.RETAIL;
        vm.prank(from);
        try cash.transfer(_actor(toSeed), amount) {
            if (retail) retailTransfers++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == TokenizedCash.DailyLimitExceeded.selector) dailyLimitHits++;
            if (sel == TokenizedCash.TransactionLimitExceeded.selector) txLimitHits++;
        }
    }

    function transferBond(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, bond.balanceOf(from));
        vm.prank(from);
        try bond.transfer(_actor(toSeed), amount) {} catch {}
    }

    function freeze(uint256 seed, bool onCash) external {
        address a = _actor(seed);
        bool on = seed % 8 == 0;
        vm.prank(OFFICER);
        if (onCash) {
            if (on) cash.freeze(a, bytes32("X"));
            else cash.unfreeze(a, bytes32("X"));
        } else {
            if (on) bond.freeze(a, bytes32("X"));
            else bond.unfreeze(a, bytes32("X"));
        }
    }

    function pause(uint256 seed, bool onCash) external {
        bool on = seed % 8 == 0;
        vm.prank(PAUSER);
        if (onCash) {
            if (on) {
                try cash.pause() {} catch {}
            } else {
                try cash.unpause() {} catch {}
            }
        } else {
            if (on) {
                try bond.pause() {} catch {}
            } else {
                try bond.unpause() {} catch {}
            }
        }
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 8 hours));
    }

    // -- settlement -------------------------------------------------------------------

    function propose(uint256 sellerSeed, uint256 buyerSeed, uint256 cashAmt, uint256 bondAmt, uint256 ttl) external {
        address seller = _actor(sellerSeed);
        address buyer = _actor(buyerSeed);
        // Bounded to holdings, so a proposal is usually one that could settle.
        uint256 buyerCash = cash.balanceOf(buyer);
        uint256 sellerBonds = bond.balanceOf(seller);
        if (buyerCash == 0 || sellerBonds == 0) return;
        cashAmt = bound(cashAmt, 1, _min(buyerCash, PER_TX + PER_TX / 4));
        bondAmt = bound(bondAmt, 1, _min(sellerBonds, 500));
        uint64 deadline = uint64(block.timestamp + bound(ttl, 1 hours, 3 days));

        vm.prank(seller);
        try bond.approve(address(dvp), type(uint256).max) {} catch {}

        vm.prank(seller);
        try dvp.propose(
            DvPSettlement.Terms({
                buyer: buyer,
                cashToken: address(cash),
                currency: bytes3("EUR"),
                cashAmount: cashAmt,
                assetToken: address(bond),
                isin: bytes12("DE000A1EWWW0"),
                assetAmount: bondAmt,
                deadline: deadline
            })
        ) {
            proposals++;
        } catch {}
    }

    function settle(uint256 idSeed) external {
        uint256 n = dvp.nextTradeId();
        if (n <= 1) return;
        // The last few proposals are the ones likely still open; a wrong hash one time in eight.
        uint256 window = _min(n - 1, 4);
        uint256 id = n - 1 - (idSeed % window);
        DvPSettlement.Trade memory t = dvp.trades(id);

        bytes32 h = idSeed % 8 == 0 ? keccak256(abi.encode(idSeed)) : _hashOf(id, t);

        vm.prank(t.buyer);
        try cash.approve(address(dvp), type(uint256).max) {} catch {}

        vm.prank(t.buyer);
        try dvp.settle(id, h) {
            settlements++;
            settleCount[id]++;
            terminalStatus[id] = DvPSettlement.Status.SETTLED;
        } catch {}
    }

    function cancel(uint256 idSeed) external {
        uint256 n = dvp.nextTradeId();
        if (n <= 1 || idSeed % 3 != 0) return; // rarer than settle, so trades survive to be settled
        uint256 id = 1 + (idSeed % (n - 1));
        address seller = dvp.trades(id).seller;

        vm.prank(seller);
        try dvp.cancel(id) {
            cancellations++;
            terminalStatus[id] = DvPSettlement.Status.CANCELLED;
        } catch {}
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _hashOf(uint256 id, DvPSettlement.Trade memory t) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(dvp),
                id,
                t.seller,
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

/// @notice Properties that must hold after any sequence of handler actions.
contract SystemInvariants is Test {
    SystemHandler internal h;

    function setUp() public {
        h = new SystemHandler();
        targetContract(address(h));
    }

    // -- supply is conserved on both legs ------------------------------------------------

    function invariant_cashSupplyEqualsMintedMinusBurned() public view {
        assertEq(h.cash().totalSupply(), h.cashMinted() - h.cashBurned());
    }

    function invariant_bondSupplyEqualsMintedMinusBurned() public view {
        assertEq(h.bond().totalSupply(), h.bondMinted() - h.bondBurned());
    }

    function invariant_cashBalancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < h.actorCount(); i++) {
            sum += h.cash().balanceOf(h.actors(i));
        }
        sum += h.cash().balanceOf(h.ISSUER());
        assertEq(sum, h.cash().totalSupply());
    }

    function invariant_bondBalancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < h.actorCount(); i++) {
            sum += h.bond().balanceOf(h.actors(i));
        }
        sum += h.bond().balanceOf(h.ISSUER());
        assertEq(sum, h.bond().totalSupply());
    }

    // -- the settlement contract holds nothing, ever (settlement section 1) ----------------

    function invariant_settlementNeverCustodies() public view {
        assertEq(h.cash().balanceOf(address(h.dvp())), 0);
        assertEq(h.bond().balanceOf(address(h.dvp())), 0);
    }

    // -- the daily cap is never exceeded (cash section 4) ------------------------------------

    function invariant_dailySpentNeverExceedsCap() public view {
        for (uint256 i = 0; i < h.actorCount(); i++) {
            address a = h.actors(i);
            Tier tier = h.registry().tierOf(a);
            if (tier == Tier.UNSET) continue;
            (, uint256 perDay) = h.cash().tierLimits(tier);
            if (perDay == h.cash().NO_LIMIT()) continue;
            assertLe(h.cash().dailySpent(a), perDay);
        }
    }

    // -- trade states are monotonic and settle at most once (settlement section 3) ----------

    function invariant_terminalTradesStayTerminal() public view {
        uint256 n = h.dvp().nextTradeId();
        for (uint256 id = 1; id < n; id++) {
            DvPSettlement.Status ghost = h.terminalStatus(id);
            if (ghost != DvPSettlement.Status.NONE) {
                assertEq(uint8(h.dvp().trades(id).status), uint8(ghost));
            }
            assertLe(h.settleCount(id), 1);
        }
    }

    function invariant_tradeCounterMatchesProposals() public view {
        assertEq(h.dvp().nextTradeId(), 1 + h.proposals());
    }

    function invariant_settledPlusCancelledNeverExceedsProposed() public view {
        assertLe(h.settlements() + h.cancellations(), h.proposals());
    }
}

/// @notice Invariants that pass over states the handler never reaches are worth nothing.
///         This drives the handler deterministically and asserts every interesting path
///         was taken, so the suite above is known to be non-vacuous.
contract SystemHandlerCoverage is Test {
    SystemHandler internal h;

    function setUp() public {
        h = new SystemHandler();
    }

    function test_handlerReachesEveryPath() public {
        uint256 seed = 0xC0FFEE;
        for (uint256 i = 0; i < 3_000; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = seed;
            uint256 b = seed >> 64;
            uint256 c = seed >> 128;
            uint256 pick = seed % 14;
            if (pick == 0) h.setApproved(a);
            else if (pick == 1) h.setSanctioned(a);
            else if (pick == 2) h.mintCash(a, b);
            else if (pick == 3) h.mintBond(a, b);
            else if (pick == 4) h.seizeCash(a, b);
            else if (pick == 5) h.seizeBond(a, b, c);
            else if (pick == 6) h.transferCash(a, b, c);
            else if (pick == 7) h.transferBond(a, b, c);
            else if (pick == 8) h.freeze(a, b % 2 == 0);
            else if (pick == 9) h.pause(a, b % 2 == 0);
            else if (pick == 10) h.warp(a);
            else if (pick == 11) h.propose(a, b, c, seed >> 192, seed >> 200);
            else if (pick == 12) h.settle(a);
            else h.cancel(a);
        }

        assertGt(h.proposals(), 0, "proposals");
        assertGt(h.settlements(), 0, "settlements");
        assertGt(h.cancellations(), 0, "cancellations");
        assertGt(h.cashBurned(), 0, "seizures on cash");
        assertGt(h.retailTransfers(), 0, "retail transfers");
        assertGt(h.txLimitHits(), 0, "per-transaction cap hit");
        assertGt(h.dailyLimitHits(), 0, "daily cap hit");

        emit log_named_uint("proposals      ", h.proposals());
        emit log_named_uint("settlements    ", h.settlements());
        emit log_named_uint("cancellations  ", h.cancellations());
        emit log_named_uint("retailTransfers", h.retailTransfers());
        emit log_named_uint("txLimitHits    ", h.txLimitHits());
        emit log_named_uint("dailyLimitHits ", h.dailyLimitHits());
    }
}
