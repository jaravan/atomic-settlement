// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";

/// @notice Deploys one TokenizedCash -- one currency -- and hands every role to its holder.
/// @dev The contract enforces the freeze-then-burn sequence but cannot see who holds which
///      key, so the separation section 2 requires is asserted here (section 9).
contract DeployCash is Script {
    /// @notice Everything the deployment needs, gathered so it can be validated as a whole.
    struct Config {
        string name;
        string symbol;
        bytes3 currency;
        IKYCRegistryV2 registry;
        address admin;
        address issuer;
        address complianceOfficer;
        address pauser;
    }

    /// @notice ISSUER_ROLE and COMPLIANCE_OFFICER_ROLE went to the same address, which would
    ///         reduce the two-key seizure control to a single actor.
    error RolesNotSeparated(address account);

    /// @notice A configured address was zero, or the currency code was not three characters.
    error InvalidConfiguration();

    /// @notice The registry address holds no code on this chain.
    error RegistryHasNoCode(address registry);

    function run() external returns (TokenizedCash token) {
        Config memory cfg = _fromEnv();

        vm.startBroadcast();
        token = deploy(cfg, msg.sender);
        vm.stopBroadcast();

        _report(token, cfg);
    }

    /// @notice Deploy and wire up roles.
    /// @param bootstrapAdmin The address that will hold DEFAULT_ADMIN_ROLE while the roles are
    ///        granted, then renounce it. Must be whoever ends up sending these calls.
    /// @dev Taken as a parameter rather than read as `address(this)`: under `--broadcast` the
    ///      sender is the EOA, not this ephemeral script contract.
    function deploy(Config memory cfg, address bootstrapAdmin) public returns (TokenizedCash token) {
        _validate(cfg);

        token = new TokenizedCash(cfg.name, cfg.symbol, cfg.currency, cfg.registry, bootstrapAdmin);

        token.grantRole(token.ISSUER_ROLE(), cfg.issuer);
        token.grantRole(token.COMPLIANCE_OFFICER_ROLE(), cfg.complianceOfficer);
        token.grantRole(token.PAUSER_ROLE(), cfg.pauser);

        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        token.grantRole(adminRole, cfg.admin);

        // Skipped when the deployer is itself the intended admin, which would undo the grant.
        if (bootstrapAdmin != cfg.admin) token.renounceRole(adminRole, bootstrapAdmin);

        _assertFinalState(token, cfg, bootstrapAdmin);
    }

    /// @dev Checked before anything is deployed, so a bad plan costs nothing.
    function _validate(Config memory cfg) private view {
        if (
            address(cfg.registry) == address(0) || cfg.admin == address(0) || cfg.issuer == address(0)
                || cfg.complianceOfficer == address(0) || cfg.pauser == address(0) || cfg.currency == bytes3(0)
        ) {
            revert InvalidConfiguration();
        }

        if (address(cfg.registry).code.length == 0) revert RegistryHasNoCode(address(cfg.registry));

        // The whole point of this script (section 2).
        if (cfg.issuer == cfg.complianceOfficer) revert RolesNotSeparated(cfg.issuer);
    }

    /// @dev Re-checked after wiring, so a mistake in this script fails the deploy rather than
    ///      shipping a token whose roles are not where the plan said.
    function _assertFinalState(TokenizedCash token, Config memory cfg, address bootstrapAdmin) private view {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        require(token.hasRole(adminRole, cfg.admin), "admin role not transferred");
        require(bootstrapAdmin == cfg.admin || !token.hasRole(adminRole, bootstrapAdmin), "deployer still holds admin");
        require(token.hasRole(token.ISSUER_ROLE(), cfg.issuer), "issuer role not granted");
        require(token.hasRole(token.COMPLIANCE_OFFICER_ROLE(), cfg.complianceOfficer), "officer role not granted");
        require(token.hasRole(token.PAUSER_ROLE(), cfg.pauser), "pauser role not granted");
        require(!token.hasRole(token.ISSUER_ROLE(), cfg.complianceOfficer), "officer also holds issuer");
    }

    function _fromEnv() private view returns (Config memory cfg) {
        string memory code = vm.envString("TOKEN_CURRENCY");
        if (bytes(code).length != 3) revert InvalidConfiguration();

        cfg = Config({
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL"),
            currency: bytes3(bytes(code)),
            registry: IKYCRegistryV2(vm.envAddress("KYC_REGISTRY")),
            admin: vm.envAddress("ADMIN_ADDRESS"),
            issuer: vm.envAddress("ISSUER_ADDRESS"),
            complianceOfficer: vm.envAddress("COMPLIANCE_OFFICER_ADDRESS"),
            pauser: vm.envAddress("PAUSER_ADDRESS")
        });
    }

    function _report(TokenizedCash token, Config memory cfg) private pure {
        console2.log("TokenizedCash      :", address(token));
        console2.log("registry           :", address(cfg.registry));
        console2.log("admin              :", cfg.admin);
        console2.log("issuer             :", cfg.issuer);
        console2.log("compliance officer :", cfg.complianceOfficer);
        console2.log("pauser             :", cfg.pauser);
        console2.log("");
        console2.log("Tier limits are unset, so every tier refuses transfers until admin");
        console2.log("calls setTierLimits. That is deliberate: the contract fails closed.");
    }
}
