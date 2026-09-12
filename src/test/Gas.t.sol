// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";
import {VanillaERC20} from "./mocks/VanillaERC20.sol";
import {DelegateProxy} from "./mocks/DelegateProxy.sol";

/// @notice Section 10: the compliance overhead, measured against an unmodified ERC-20.
/// @dev Each measurement is the first call of its test, so storage and accounts are cold --
///      the state a real transfer starts from. Registry reads go through a delegatecall
///      proxy so the UUPS hop production pays is included.
contract GasTest is Test {
    TokenizedCash internal capped;
    TokenizedCash internal uncapped;
    VanillaERC20 internal vanilla;
    MockKYCRegistry internal registry;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant ALICE = address(0xA11);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5E77);

    uint256 internal constant AMOUNT = 10e6;

    function setUp() public {
        MockKYCRegistry impl = new MockKYCRegistry();
        registry = MockKYCRegistry(address(new DelegateProxy(address(impl))));

        registry.setApproved(ALICE, true);
        registry.setApproved(BOB, true);
        registry.setApproved(ISSUER, true);
        registry.setTier(ALICE, Tier.RETAIL);
        registry.setTier(BOB, Tier.RETAIL);
        registry.setTier(ISSUER, Tier.RETAIL);

        capped = _deploy();
        uncapped = _deploy();
        vanilla = new VanillaERC20();

        vm.startPrank(ADMIN);
        capped.setTierLimits(Tier.RETAIL, 1_000e6, 1_000e6);
        uncapped.setTierLimits(Tier.RETAIL, uncapped.NO_LIMIT(), uncapped.NO_LIMIT());
        vm.stopPrank();

        _seed(capped);
        _seed(uncapped);
        vanilla.mint(ALICE, 1_000e6);
        vanilla.mint(BOB, 1);

        vm.prank(ALICE);
        capped.approve(SPENDER, type(uint256).max);
    }

    function _deploy() private returns (TokenizedCash t) {
        t = new TokenizedCash("Tokenized Euro", "tEUR", bytes3("EUR"), IKYCRegistryV2(address(registry)), ADMIN);

        bytes32 role = t.ISSUER_ROLE(); // hoisted: reading it is a call, which eats the prank
        vm.prank(ADMIN);
        t.grantRole(role, ISSUER);
    }

    /// @dev BOB starts with a non-zero balance in every token, so a transfer measures the
    ///      nonzero->nonzero write rather than the one-off cost of creating a slot.
    function _seed(TokenizedCash t) private {
        vm.startPrank(ISSUER);
        t.mint(ALICE, 1_000e6);
        t.mint(BOB, 1);
        vm.stopPrank();
    }

    function _report(string memory label, uint256 used) private {
        emit log_named_uint(label, used);
    }

    // Each pair is one cold call (the state a real transaction starts from) followed by a
    // warm one, so the two tokens are compared under identical conditions.

    function test_gas_transfer_vanilla() public {
        vm.startPrank(ALICE);
        uint256 g = gasleft();
        vanilla.transfer(BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        vanilla.transfer(BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("vanilla transfer        cold", cold);
        _report("vanilla transfer        warm", warm);
    }

    function test_gas_transfer_uncappedTier() public {
        vm.startPrank(ALICE);
        uint256 g = gasleft();
        uncapped.transfer(BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        uncapped.transfer(BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("NO_LIMIT transfer       cold", cold);
        _report("NO_LIMIT transfer       warm", warm);
    }

    function test_gas_transfer_cappedTier() public {
        vm.startPrank(ALICE);
        uint256 g = gasleft();
        capped.transfer(BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        capped.transfer(BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("capped transfer         cold", cold);
        _report("capped transfer         warm", warm);
    }

    function test_gas_transferFrom_cappedTier() public {
        vm.startPrank(SPENDER);
        uint256 g = gasleft();
        capped.transferFrom(ALICE, BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        capped.transferFrom(ALICE, BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("capped transferFrom     cold", cold);
        _report("capped transferFrom     warm", warm);
    }

    function test_gas_mint() public {
        vm.startPrank(ISSUER);
        uint256 g = gasleft();
        capped.mint(BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        capped.mint(BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("mint                    cold", cold);
        _report("mint                    warm", warm);
    }

    function test_gas_burn() public {
        vm.startPrank(ISSUER);
        capped.mint(ISSUER, 3 * AMOUNT);

        uint256 g = gasleft();
        capped.burn(AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("burn (issuer already warm)  ", warm);
    }

    function test_gas_canTransfer_preview() public {
        uint256 g = gasleft();
        capped.canTransfer(ALICE, BOB, AMOUNT);
        _report("canTransfer  cold (view)    ", g - gasleft());
    }
}

/// @notice Asset section 11: the same paths on the bond, which carries no tier read and no
///         accumulator. Same conditions as GasTest so the two legs compare directly.
contract AssetGasTest is Test {
    AssetToken internal bond;
    MockKYCRegistry internal registry;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant ALICE = address(0xA11);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5E77);

    uint256 internal constant AMOUNT = 10;

    function setUp() public {
        MockKYCRegistry impl = new MockKYCRegistry();
        registry = MockKYCRegistry(address(new DelegateProxy(address(impl))));

        registry.setApproved(ALICE, true);
        registry.setApproved(BOB, true);
        registry.setApproved(ISSUER, true);

        bond = new AssetToken("Bund 2035", "BUND35", bytes12("DE000A1EWWW0"), IKYCRegistryV2(address(registry)), ADMIN);

        bytes32 issuerRole = bond.ISSUER_ROLE();
        bytes32 officerRole = bond.COMPLIANCE_OFFICER_ROLE();
        vm.startPrank(ADMIN);
        bond.grantRole(issuerRole, ISSUER);
        bond.grantRole(officerRole, OFFICER);
        vm.stopPrank();

        vm.startPrank(ISSUER);
        bond.mint(ALICE, 1_000);
        bond.mint(BOB, 1);
        vm.stopPrank();

        vm.prank(ALICE);
        bond.approve(SPENDER, type(uint256).max);
    }

    function _report(string memory label, uint256 used) private {
        emit log_named_uint(label, used);
    }

    function test_gas_transfer() public {
        vm.startPrank(ALICE);
        uint256 g = gasleft();
        bond.transfer(BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        bond.transfer(BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("asset transfer          cold", cold);
        _report("asset transfer          warm", warm);
    }

    function test_gas_transferFrom() public {
        vm.startPrank(SPENDER);
        uint256 g = gasleft();
        bond.transferFrom(ALICE, BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        bond.transferFrom(ALICE, BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("asset transferFrom      cold", cold);
        _report("asset transferFrom      warm", warm);
    }

    function test_gas_mint() public {
        vm.startPrank(ISSUER);
        uint256 g = gasleft();
        bond.mint(BOB, AMOUNT);
        uint256 cold = g - gasleft();

        g = gasleft();
        bond.mint(BOB, AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("asset mint              cold", cold);
        _report("asset mint              warm", warm);
    }

    function test_gas_burn() public {
        vm.startPrank(ISSUER);
        bond.mint(ISSUER, 3 * AMOUNT);

        uint256 g = gasleft();
        bond.burn(AMOUNT);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("asset burn (issuer warm)    ", warm);
    }

    /// @dev The one path with no cash-leg counterpart. Measured cold: a seizure is a fresh
    ///      transaction in practice.
    function test_gas_forceTransfer() public {
        vm.prank(OFFICER);
        bond.freeze(ALICE, bytes32("COURT_ORDER"));

        vm.prank(ISSUER);
        uint256 g = gasleft();
        bond.forceTransfer(ALICE, BOB, AMOUNT, bytes32("COURT_ORDER"));
        _report("asset forceTransfer     cold", g - gasleft());
    }
}

/// @notice Settlement section 12: a settlement pays for both legs plus its own bookkeeping.
///         Seven registry round trips in one transaction -- the number no token document
///         could state because neither sees both legs.
contract SettlementGasTest is Test {
    TokenizedCash internal cash;
    AssetToken internal bond;
    DvPSettlement internal dvp;
    MockKYCRegistry internal registry;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant SELLER = address(0x5E11);
    address internal constant BUYER = address(0xB0BB);

    uint256 internal constant CASH_AMOUNT = 10_000_000e6;
    uint256 internal constant BOND_AMOUNT = 100;

    uint64 internal deadline;

    function setUp() public {
        vm.warp(1_700_000_000);
        deadline = uint64(block.timestamp + 1 days);

        MockKYCRegistry impl = new MockKYCRegistry();
        registry = MockKYCRegistry(address(new DelegateProxy(address(impl))));
        registry.setApproved(SELLER, true);
        registry.setApproved(BUYER, true);
        registry.setApproved(ISSUER, true);
        registry.setTier(SELLER, Tier.INSTITUTIONAL);
        registry.setTier(BUYER, Tier.INSTITUTIONAL);
        registry.setTier(ISSUER, Tier.INSTITUTIONAL);

        cash = new TokenizedCash("Tokenized Euro", "tEUR", bytes3("EUR"), IKYCRegistryV2(address(registry)), ADMIN);
        bond = new AssetToken("Bund 2035", "BUND35", bytes12("DE000A1EWWW0"), IKYCRegistryV2(address(registry)), ADMIN);
        dvp = new DvPSettlement();

        bytes32 cashIssuer = cash.ISSUER_ROLE();
        bytes32 bondIssuer = bond.ISSUER_ROLE();
        uint256 noLimit = cash.NO_LIMIT();
        vm.startPrank(ADMIN);
        cash.grantRole(cashIssuer, ISSUER);
        bond.grantRole(bondIssuer, ISSUER);
        cash.setTierLimits(Tier.INSTITUTIONAL, noLimit, noLimit); // as the registry fixture: like for like
        vm.stopPrank();

        // Non-zero balances on both sides of both legs, so every write is nonzero -> nonzero.
        vm.startPrank(ISSUER);
        cash.mint(BUYER, 10 * CASH_AMOUNT);
        cash.mint(SELLER, 1);
        bond.mint(SELLER, 10 * BOND_AMOUNT);
        bond.mint(BUYER, 1);
        vm.stopPrank();

        vm.prank(SELLER);
        bond.approve(address(dvp), type(uint256).max);
        vm.prank(BUYER);
        cash.approve(address(dvp), type(uint256).max);

        _proposeTwo();
    }

    function _terms() private view returns (DvPSettlement.Terms memory) {
        return DvPSettlement.Terms({
            buyer: BUYER,
            cashToken: address(cash),
            currency: bytes3("EUR"),
            cashAmount: CASH_AMOUNT,
            assetToken: address(bond),
            isin: bytes12("DE000A1EWWW0"),
            assetAmount: BOND_AMOUNT,
            deadline: deadline
        });
    }

    function _hash(uint256 id) private view returns (bytes32) {
        return dvp.hashTerms(id, SELLER, _terms());
    }

    function _report(string memory label, uint256 used) private {
        emit log_named_uint(label, used);
    }

    function test_gas_propose() public {
        DvPSettlement.Terms memory t = _terms();
        vm.startPrank(SELLER);
        uint256 g = gasleft();
        dvp.propose(t);
        uint256 cold = g - gasleft();

        g = gasleft();
        dvp.propose(t);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("propose                 cold", cold);
        _report("propose                 warm", warm);
    }

    function test_gas_cancel() public {
        vm.startPrank(SELLER);
        uint256 id = dvp.propose(_terms());
        uint256 g = gasleft();
        dvp.cancel(id);
        _report("cancel (record warm)        ", g - gasleft());
        vm.stopPrank();
    }

    uint256 internal tradeA;
    uint256 internal tradeB;

    /// @dev Proposed in setUp, as in production: propose and settle are separate
    ///      transactions, so the trade record is cold when settle reads it.
    function _proposeTwo() private {
        vm.startPrank(SELLER);
        tradeA = dvp.propose(_terms());
        tradeB = dvp.propose(_terms());
        vm.stopPrank();
    }

    /// @dev Cold: the first settlement in a transaction, both tokens, the registry and the
    ///      trade record untouched, the buyer's daily slot fresh for the day.
    function test_gas_settle() public {
        uint256 a = tradeA;
        uint256 b = tradeB;
        bytes32 ha = _hash(a);
        bytes32 hb = _hash(b);

        vm.startPrank(BUYER);
        uint256 g = gasleft();
        dvp.settle(a, ha);
        uint256 cold = g - gasleft();

        g = gasleft();
        dvp.settle(b, hb);
        uint256 warm = g - gasleft();
        vm.stopPrank();

        _report("settle                  cold", cold);
        _report("settle                  warm", warm);
    }

    function test_gas_canSettle() public {
        vm.prank(SELLER);
        uint256 id = dvp.propose(_terms());
        bytes32 h = _hash(id);

        uint256 g = gasleft();
        dvp.canSettle(id, h);
        _report("canSettle  cold (view)      ", g - gasleft());
    }
}
