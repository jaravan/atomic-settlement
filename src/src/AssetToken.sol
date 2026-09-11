// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";

/// @title AssetToken
/// @notice The asset leg of an atomic DvP settlement: an ERC-20 standing for a single bond
///         issue, with compliance enforced by the contract itself.
/// @dev Design: doc/design-asset.md. Where it shares a decision with the cash leg it says so.
contract AssetToken is ERC20, AccessControl {
    // ---------------------------------------------------------------------------------
    // Roles (section 2)
    // ---------------------------------------------------------------------------------

    /// @notice Mint at issue, burn at redemption, and forceTransfer. Used rarely.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// @notice Freeze and unfreeze a single address.
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");

    /// @notice Pause and unpause this instrument.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ---------------------------------------------------------------------------------
    // Storage and immutables
    // ---------------------------------------------------------------------------------

    /// @notice The registry every compliance decision is read from.
    /// @dev Immutable (section 1): costs no SLOAD, and leaves no door to repoint the token
    ///      at a registry that approves everyone.
    IKYCRegistryV2 public immutable registry;

    /// @notice ISO 6166 ISIN of the issue this deployment represents, e.g. "DE000A1EWWW0".
    /// @dev One balance mapping cannot keep two instruments apart, so each issue is its own
    ///      deployment and the identity is fixed at construction (section 9).
    bytes12 public immutable isin;

    // ---------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------

    /// @notice A constructor argument was the zero address or the zero ISIN.
    error InvalidConfiguration();

    // ---------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------

    /// @param name_     ERC-20 name.
    /// @param symbol_   ERC-20 symbol.
    /// @param isin_     ISO 6166 ISIN. Fixed for the life of the deployment.
    /// @param registry_ The KYC registry. Never changeable.
    /// @param admin     Initial DEFAULT_ADMIN_ROLE holder, which grants the other three.
    constructor(string memory name_, string memory symbol_, bytes12 isin_, IKYCRegistryV2 registry_, address admin)
        ERC20(name_, symbol_)
    {
        if (address(registry_) == address(0) || admin == address(0) || isin_ == bytes12(0)) {
            revert InvalidConfiguration();
        }
        registry = registry_;
        isin = isin_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc ERC20
    /// @dev A bond is not divisible: a balance of 100 is one hundred bonds (section 9).
    function decimals() public pure override returns (uint8) {
        return 0;
    }
}
