// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {AssetToken} from "../src/AssetToken.sol";

/// @notice Deploys one AssetToken -- one bond issue -- and hands every role to its holder.
/// @dev Two checks the contract deliberately leaves to this script: that ISSUER_ROLE and
///      COMPLIANCE_OFFICER_ROLE are different parties (section 2), and that the ISIN's
///      check digit is right (section 9).
contract DeployAsset is Script {
    struct Config {
        string name;
        string symbol;
        bytes12 isin;
        IKYCRegistryV2 registry;
        address admin;
        address issuer;
        address complianceOfficer;
        address pauser;
    }

    /// @notice ISSUER_ROLE and COMPLIANCE_OFFICER_ROLE went to the same address, which would
    ///         reduce the two-key forced-transfer control to a single actor.
    error RolesNotSeparated(address account);

    /// @notice A configured address was zero.
    error InvalidConfiguration();

    /// @notice The registry address holds no code on this chain.
    error RegistryHasNoCode(address registry);

    /// @notice The ISIN is not twelve characters of [A-Z0-9], or its check digit is wrong.
    error InvalidIsin(bytes12 isin);

    function run() external returns (AssetToken token) {
        Config memory cfg = _fromEnv();

        vm.startBroadcast();
        token = deploy(cfg, msg.sender);
        vm.stopBroadcast();

        _report(token, cfg);
    }

    /// @notice Deploy and wire up roles.
    /// @param bootstrapAdmin Holds DEFAULT_ADMIN_ROLE while the roles are granted, then
    ///        renounces it. Must be whoever ends up sending these calls.
    function deploy(Config memory cfg, address bootstrapAdmin) public returns (AssetToken token) {
        _validate(cfg);

        token = new AssetToken(cfg.name, cfg.symbol, cfg.isin, cfg.registry, bootstrapAdmin);

        token.grantRole(token.ISSUER_ROLE(), cfg.issuer);
        token.grantRole(token.COMPLIANCE_OFFICER_ROLE(), cfg.complianceOfficer);
        token.grantRole(token.PAUSER_ROLE(), cfg.pauser);

        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        token.grantRole(adminRole, cfg.admin);
        if (bootstrapAdmin != cfg.admin) token.renounceRole(adminRole, bootstrapAdmin);

        _assertFinalState(token, cfg, bootstrapAdmin);
    }

    /// @notice ISO 6166 check: twelve characters of [A-Z0-9], the last a Luhn digit over the
    ///         expansion where each letter becomes two digits (A=10 ... Z=35).
    /// @dev Public so it can be tested directly. Kept off-chain by design (section 9).
    function isValidIsin(bytes12 isin) public pure returns (bool) {
        // Expand into a digit string. At most 24 digits (all letters), at least 12.
        uint8[24] memory digits;
        uint256 n = 0;

        for (uint256 i = 0; i < 12; i++) {
            uint8 c = uint8(isin[i]);
            if (c >= 0x30 && c <= 0x39) {
                digits[n++] = c - 0x30;
            } else if (c >= 0x41 && c <= 0x5A) {
                uint8 v = c - 0x41 + 10; // 10..35
                digits[n++] = v / 10;
                digits[n++] = v % 10;
            } else {
                return false;
            }
        }

        // Luhn from the right: double every second digit, fold if it exceeds 9.
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 d = digits[n - 1 - i];
            if (i % 2 == 1) {
                d *= 2;
                if (d > 9) d -= 9;
            }
            sum += d;
        }
        return sum % 10 == 0;
    }

    function _validate(Config memory cfg) private view {
        if (
            address(cfg.registry) == address(0) || cfg.admin == address(0) || cfg.issuer == address(0)
                || cfg.complianceOfficer == address(0) || cfg.pauser == address(0)
        ) {
            revert InvalidConfiguration();
        }

        if (!isValidIsin(cfg.isin)) revert InvalidIsin(cfg.isin);
        if (address(cfg.registry).code.length == 0) revert RegistryHasNoCode(address(cfg.registry));

        // The whole point of this script (section 2).
        if (cfg.issuer == cfg.complianceOfficer) revert RolesNotSeparated(cfg.issuer);
    }

    function _assertFinalState(AssetToken token, Config memory cfg, address bootstrapAdmin) private view {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        require(token.hasRole(adminRole, cfg.admin), "admin role not transferred");
        require(bootstrapAdmin == cfg.admin || !token.hasRole(adminRole, bootstrapAdmin), "deployer still holds admin");
        require(token.hasRole(token.ISSUER_ROLE(), cfg.issuer), "issuer role not granted");
        require(token.hasRole(token.COMPLIANCE_OFFICER_ROLE(), cfg.complianceOfficer), "officer role not granted");
        require(token.hasRole(token.PAUSER_ROLE(), cfg.pauser), "pauser role not granted");
        require(!token.hasRole(token.ISSUER_ROLE(), cfg.complianceOfficer), "officer also holds issuer");
    }

    function _fromEnv() private view returns (Config memory cfg) {
        string memory code = vm.envString("ASSET_ISIN");
        if (bytes(code).length != 12) revert InvalidIsin(bytes12(bytes(code)));

        cfg = Config({
            name: vm.envString("ASSET_NAME"),
            symbol: vm.envString("ASSET_SYMBOL"),
            isin: bytes12(bytes(code)),
            registry: IKYCRegistryV2(vm.envAddress("KYC_REGISTRY")),
            admin: vm.envAddress("ADMIN_ADDRESS"),
            issuer: vm.envAddress("ISSUER_ADDRESS"),
            complianceOfficer: vm.envAddress("COMPLIANCE_OFFICER_ADDRESS"),
            pauser: vm.envAddress("PAUSER_ADDRESS")
        });
    }

    function _report(AssetToken token, Config memory cfg) private pure {
        console2.log("AssetToken         :", address(token));
        console2.log("ISIN               :", string(abi.encodePacked(cfg.isin)));
        console2.log("registry           :", address(cfg.registry));
        console2.log("admin              :", cfg.admin);
        console2.log("issuer             :", cfg.issuer);
        console2.log("compliance officer :", cfg.complianceOfficer);
        console2.log("pauser             :", cfg.pauser);
        console2.log("");
        console2.log("Supply is zero until the issuer mints the issue to the arranger or the");
        console2.log("initial allottees. ISSUER_ROLE is a cold key here: used at issue, at");
        console2.log("redemption, and for a court-ordered forced transfer. Store it like one.");
    }
}
