// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";

/// @title TokenizedCash
/// @notice The cash leg of an atomic DvP settlement: an ERC-20 representing commercial bank
///         money, or a simplified CBDC, with compliance enforced by the contract itself.
/// @dev Design: doc/design-cash.md
contract TokenizedCash is ERC20, AccessControl {
    // ---------------------------------------------------------------------------------
    // Roles (section 2)
    // ---------------------------------------------------------------------------------

    /// @notice Mint, burn and burnFrom. Supply in and out.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// @notice Freeze and unfreeze a single address.
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");

    /// @notice Pause and unpause the whole contract.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ---------------------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------------------

    /// @notice The registry every compliance decision is read from.
    /// @dev Immutable (section 1): costs no SLOAD, and leaves no door to repoint the token
    ///      at a registry that approves everyone.
    IKYCRegistryV2 public immutable registry;

    /// @notice ISO 4217 code of the currency this deployment represents, e.g. "EUR".
    /// @dev One balance mapping cannot keep two currencies apart, so each deployment is
    ///      exactly one currency and it is fixed at construction (section 8).
    bytes3 public immutable currency;

    // ---------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------

    /// @notice A constructor argument was the zero address or the zero currency code.
    error InvalidConfiguration();

    // ---------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------

    /// @param name_     ERC-20 name.
    /// @param symbol_   ERC-20 symbol.
    /// @param currency_ ISO 4217 code, e.g. "EUR". Fixed for the life of the deployment.
    /// @param registry_ The KYC registry. Never changeable.
    /// @param admin     Initial DEFAULT_ADMIN_ROLE holder, which grants the other three.
    /// @dev The deploy script grants the operational roles and asserts ISSUER_ROLE and
    ///      COMPLIANCE_OFFICER_ROLE go to different parties (section 2).
    constructor(string memory name_, string memory symbol_, bytes3 currency_, IKYCRegistryV2 registry_, address admin)
        ERC20(name_, symbol_)
    {
        if (address(registry_) == address(0) || admin == address(0) || currency_ == bytes3(0)) {
            revert InvalidConfiguration();
        }
        registry = registry_;
        currency = currency_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc ERC20
    /// @dev Six, not two: a cent cannot be split and pro-rata allocations rarely divide
    ///      evenly. Not eighteen: that is inherited from ether, not a property of money.
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
