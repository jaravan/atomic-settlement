// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {DeployCash} from "../script/DeployCash.s.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice The deploy script carries the one control the contract cannot: that ISSUER_ROLE
///         and COMPLIANCE_OFFICER_ROLE go to different parties (sections 2, 9).
contract DeployCashTest is Test {
    DeployCash internal script;
    MockKYCRegistry internal registry;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant PAUSER = address(0x9A05);

    function setUp() public {
        script = new DeployCash();
        registry = new MockKYCRegistry();
    }

    function _config() private view returns (DeployCash.Config memory) {
        return DeployCash.Config({
            name: "Tokenized Euro",
            symbol: "tEUR",
            currency: bytes3("EUR"),
            registry: IKYCRegistryV2(address(registry)),
            admin: ADMIN,
            issuer: ISSUER,
            complianceOfficer: OFFICER,
            pauser: PAUSER
        });
    }

    // -- the control this script exists for ----------------------------------------------

    function test_revertsWhenIssuerAndOfficerAreTheSame() public {
        DeployCash.Config memory cfg = _config();
        cfg.complianceOfficer = ISSUER;

        vm.expectRevert(abi.encodeWithSelector(DeployCash.RolesNotSeparated.selector, ISSUER));
        script.deploy(cfg, address(script));
    }

    /// @dev Admin holding issuer is fine: section 2 says admin can self-grant anyway, and the
    ///      grant would be a public event. It is issuer-and-officer that breaks the control.
    function test_allowsAdminToAlsoHoldAnOperationalRole() public {
        DeployCash.Config memory cfg = _config();
        cfg.issuer = ADMIN;

        TokenizedCash token = script.deploy(cfg, address(script));

        assertTrue(token.hasRole(token.ISSUER_ROLE(), ADMIN));
    }

    // -- roles land where the plan said --------------------------------------------------

    function test_grantsEveryRoleToItsHolder() public {
        TokenizedCash token = script.deploy(_config(), address(script));

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(token.hasRole(token.ISSUER_ROLE(), ISSUER));
        assertTrue(token.hasRole(token.COMPLIANCE_OFFICER_ROLE(), OFFICER));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), PAUSER));
    }

    /// @dev The deployer bootstraps as admin and must end up holding nothing.
    function test_deployerRetainsNothing() public {
        TokenizedCash token = script.deploy(_config(), address(script));

        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(script)));
        assertFalse(token.hasRole(token.ISSUER_ROLE(), address(script)));
        assertFalse(token.hasRole(token.COMPLIANCE_OFFICER_ROLE(), address(script)));
        assertFalse(token.hasRole(token.PAUSER_ROLE(), address(script)));
    }

    function test_setsTokenConfiguration() public {
        TokenizedCash token = script.deploy(_config(), address(script));

        assertEq(token.name(), "Tokenized Euro");
        assertEq(token.symbol(), "tEUR");
        assertEq(token.currency(), bytes3("EUR"));
        assertEq(address(token.registry()), address(registry));
        assertEq(token.decimals(), 6);
    }

    /// @dev Nothing can move until admin sets limits: an unconfigured tier reads zero and the
    ///      contract fails closed (section 4).
    function test_leavesEveryTierUnconfigured() public {
        TokenizedCash token = script.deploy(_config(), address(script));

        (uint256 perTx, uint256 perDay) = token.tierLimits(Tier.RETAIL);
        assertEq(perTx, 0);
        assertEq(perDay, 0);
    }

    // -- configuration is validated before anything is deployed --------------------------

    function test_revertsOnZeroRegistry() public {
        DeployCash.Config memory cfg = _config();
        cfg.registry = IKYCRegistryV2(address(0));

        vm.expectRevert(DeployCash.InvalidConfiguration.selector);
        script.deploy(cfg, address(script));
    }

    function test_revertsOnZeroAdmin() public {
        DeployCash.Config memory cfg = _config();
        cfg.admin = address(0);

        vm.expectRevert(DeployCash.InvalidConfiguration.selector);
        script.deploy(cfg, address(script));
    }

    function test_revertsOnZeroPauser() public {
        DeployCash.Config memory cfg = _config();
        cfg.pauser = address(0);

        vm.expectRevert(DeployCash.InvalidConfiguration.selector);
        script.deploy(cfg, address(script));
    }

    function test_revertsOnZeroCurrency() public {
        DeployCash.Config memory cfg = _config();
        cfg.currency = bytes3(0);

        vm.expectRevert(DeployCash.InvalidConfiguration.selector);
        script.deploy(cfg, address(script));
    }

    /// @dev A registry address that is an EOA, or a chain where it was never deployed, is a
    ///      configuration mistake worth catching before the token exists.
    function test_revertsWhenRegistryHasNoCode() public {
        DeployCash.Config memory cfg = _config();
        cfg.registry = IKYCRegistryV2(address(0xDEAD));

        vm.expectRevert(abi.encodeWithSelector(DeployCash.RegistryHasNoCode.selector, address(0xDEAD)));
        script.deploy(cfg, address(script));
    }
}
