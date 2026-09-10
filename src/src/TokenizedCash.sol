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
    // Storage and immutables
    // ---------------------------------------------------------------------------------

    /// @notice The registry every compliance decision is read from.
    /// @dev Immutable (section 1): costs no SLOAD, and leaves no door to repoint the token
    ///      at a registry that approves everyone.
    IKYCRegistryV2 public immutable registry;

    /// @notice ISO 4217 code of the currency this deployment represents, e.g. "EUR".
    /// @dev One balance mapping cannot keep two currencies apart, so each deployment is
    ///      exactly one currency and it is fixed at construction (section 8).
    bytes3 public immutable currency;

    /// @notice Whether an address is frozen. A frozen address cannot send, but can receive.
    mapping(address account => bool) public frozen;

    // ---------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------

    /// @notice A constructor argument was the zero address or the zero currency code.
    error InvalidConfiguration();

    /// @notice The account is not approved in the registry, or its approval has lapsed.
    error NotApproved(address account);

    /// @notice The sender is frozen. Frozen accounts can still receive.
    error SenderFrozen(address account);

    /// @notice The party directing the transfer is sanctioned.
    /// @dev The only check made on the spender: on a settlement it is a contract, and a
    ///      contract can never be isApproved (section 3).
    error SpenderSanctioned(address spender);

    // ---------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------

    /// @notice Emitted on freeze.
    /// @dev `reason` is an enumerated bytes32 code, not free text: one word instead of
    ///      unbounded calldata, and queryable by a compliance system (section 5).
    event AccountFrozen(address indexed account, bytes32 reason, address indexed by);

    /// @notice Emitted on unfreeze, carrying the same enumerated code.
    event AccountUnfrozen(address indexed account, bytes32 reason, address indexed by);

    // ---------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------

    /// @param name_     ERC-20 name.
    /// @param symbol_   ERC-20 symbol.
    /// @param currency_ ISO 4217 code, e.g. "EUR". Fixed for the life of the deployment.
    /// @param registry_ The KYC registry. Never changeable.
    /// @param admin     Initial DEFAULT_ADMIN_ROLE holder, which grants the other three.
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
    /// @dev Six, not two or eighteen (section 8).
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ---------------------------------------------------------------------------------
    // Transfers (section 3)
    // ---------------------------------------------------------------------------------

    /// @inheritdoc ERC20
    /// @dev Only transferFrom pays for the spender check. On a direct transfer the spender
    ///      is the sender, and isApproved(from) already implies not sanctioned.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (registry.isSanctioned(msg.sender)) revert SpenderSanctioned(msg.sender);
        return super.transferFrom(from, to, value);
    }

    /// @dev The one place every transfer, mint and burn passes through: in OpenZeppelin
    ///      v5.6.1 _update is the only virtual hook on the transfer path.
    function _update(address from, address to, uint256 value) internal override {
        // A burn (to == 0) delivers to nobody, so the sender side is not guarded: there is
        // no counterparty to protect, and it is what makes burnFrom possible (section 3).
        if (from != address(0) && to != address(0)) {
            if (!registry.isApproved(from)) revert NotApproved(from);
            if (frozen[from]) revert SenderFrozen(from);
        }

        // Also covers the mint recipient.
        if (to != address(0)) {
            if (!registry.isApproved(to)) revert NotApproved(to);
        }

        super._update(from, to, value);
    }

    // ---------------------------------------------------------------------------------
    // Freeze (section 5)
    // ---------------------------------------------------------------------------------

    /// @notice Stop an address sending. It can still receive.
    /// @dev Allowances are deliberately left in place: they cannot be enumerated on-chain,
    ///      and a freeze is reversible where deleting approvals is not (section 3).
    function freeze(address account, bytes32 reason) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        frozen[account] = true;
        emit AccountFrozen(account, reason, msg.sender);
    }

    /// @notice Lift a freeze.
    function unfreeze(address account, bytes32 reason) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        frozen[account] = false;
        emit AccountUnfrozen(account, reason, msg.sender);
    }
}
