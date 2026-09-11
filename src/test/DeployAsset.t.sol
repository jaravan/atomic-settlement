// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {DeployAsset} from "../script/DeployAsset.s.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {MockKYCRegistry} from "./mocks/MockKYCRegistry.sol";

/// @notice The deploy script carries the two controls the contract leaves off-chain: role
///         separation (section 2) and the ISIN check digit (section 9).
contract DeployAssetTest is Test {
    DeployAsset internal script;
    MockKYCRegistry internal registry;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ISSUER = address(0x155);
    address internal constant OFFICER = address(0x0FF);
    address internal constant PAUSER = address(0x9A05);

    function setUp() public {
        script = new DeployAsset();
        registry = new MockKYCRegistry();
    }

    function _config() private view returns (DeployAsset.Config memory) {
        return DeployAsset.Config({
            name: "Bund 2035",
            symbol: "BUND35",
            isin: bytes12("DE000A1EWWW0"),
            registry: IKYCRegistryV2(address(registry)),
            admin: ADMIN,
            issuer: ISSUER,
            complianceOfficer: OFFICER,
            pauser: PAUSER
        });
    }

    // -- the two controls this script exists for -----------------------------------------

    function test_revertsWhenIssuerAndOfficerAreTheSame() public {
        DeployAsset.Config memory cfg = _config();
        cfg.complianceOfficer = ISSUER;

        vm.expectRevert(abi.encodeWithSelector(DeployAsset.RolesNotSeparated.selector, ISSUER));
        script.deploy(cfg, address(script));
    }

    function test_revertsOnBadCheckDigit() public {
        DeployAsset.Config memory cfg = _config();
        cfg.isin = bytes12("DE000A1EWWW1"); // last digit off by one

        vm.expectRevert(abi.encodeWithSelector(DeployAsset.InvalidIsin.selector, cfg.isin));
        script.deploy(cfg, address(script));
    }

    // -- the Luhn itself, against real and corrupted ISINs -------------------------------

    function test_isin_acceptsRealOnes() public view {
        assertTrue(script.isValidIsin(bytes12("US0378331005")), "Apple");
        assertTrue(script.isValidIsin(bytes12("DE000A1EWWW0")), "Bund");
        assertTrue(script.isValidIsin(bytes12("DE000A1EWWX8")), "Bund");
        assertTrue(script.isValidIsin(bytes12("GB0002634946")), "BAE");
    }

    function test_isin_rejectsWrongCheckDigit() public view {
        assertFalse(script.isValidIsin(bytes12("US0378331006")));
        assertFalse(script.isValidIsin(bytes12("DE000A1EWWW1")));
    }

    function test_isin_rejectsLowercase() public view {
        assertFalse(script.isValidIsin(bytes12("de000a1ewww0")));
    }

    function test_isin_rejectsNonAlphanumeric() public view {
        assertFalse(script.isValidIsin(bytes12("DE000A1EWW-0")));
    }

    function test_isin_rejectsZero() public view {
        assertFalse(script.isValidIsin(bytes12(0)));
    }

    // -- roles land where the plan said --------------------------------------------------

    function test_grantsEveryRoleToItsHolder() public {
        AssetToken token = script.deploy(_config(), address(script));

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(token.hasRole(token.ISSUER_ROLE(), ISSUER));
        assertTrue(token.hasRole(token.COMPLIANCE_OFFICER_ROLE(), OFFICER));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), PAUSER));
    }

    function test_deployerRetainsNothing() public {
        AssetToken token = script.deploy(_config(), address(script));

        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(script)));
        assertFalse(token.hasRole(token.ISSUER_ROLE(), address(script)));
    }

    function test_setsTokenConfiguration() public {
        AssetToken token = script.deploy(_config(), address(script));

        assertEq(token.name(), "Bund 2035");
        assertEq(token.symbol(), "BUND35");
        assertEq(token.isin(), bytes12("DE000A1EWWW0"));
        assertEq(address(token.registry()), address(registry));
        assertEq(token.decimals(), 0);
        assertEq(token.totalSupply(), 0, "nothing issued until the issuer mints");
    }

    // -- configuration is validated before anything is deployed --------------------------

    function test_revertsOnZeroAdmin() public {
        DeployAsset.Config memory cfg = _config();
        cfg.admin = address(0);

        vm.expectRevert(DeployAsset.InvalidConfiguration.selector);
        script.deploy(cfg, address(script));
    }

    function test_revertsWhenRegistryHasNoCode() public {
        DeployAsset.Config memory cfg = _config();
        cfg.registry = IKYCRegistryV2(address(0xDEAD));

        vm.expectRevert(abi.encodeWithSelector(DeployAsset.RegistryHasNoCode.selector, address(0xDEAD)));
        script.deploy(cfg, address(script));
    }
}
