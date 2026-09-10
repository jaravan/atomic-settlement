// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";

/// @title TokenizedCash
/// @notice The cash leg of an atomic DvP settlement: an ERC-20 representing commercial bank
///         money, or a simplified CBDC, with compliance enforced by the contract itself.
/// @dev Design: doc/design-cash.md
contract TokenizedCash is ERC20, AccessControl, Pausable {
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
    // Limits (section 4)
    // ---------------------------------------------------------------------------------

    /// @notice A tier configured to this value is uncapped.
    /// @dev The sentinel sits opposite the zero default so that forgetting to configure a
    ///      tier blocks transfers rather than uncapping them: the contract fails closed.
    uint256 public constant NO_LIMIT = type(uint256).max;

    /// @notice The two caps that apply to a tier: one per transaction, one per calendar day.
    struct TierLimits {
        uint256 perTransaction;
        uint256 perDay;
    }

    /// @notice A sender's running total for the current UTC day.
    /// @dev Packs into one 256-bit slot; a uint40 day number outlasts any plausible chain.
    struct DailyUsage {
        uint40 day;
        uint216 spent;
    }

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

    mapping(Tier tier => TierLimits) private _limits;
    mapping(address account => DailyUsage) private _usage;

    // ---------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------

    /// @notice A constructor argument was the zero address or the zero currency code.
    error InvalidConfiguration();

    /// @notice The account is not approved in the registry, or its approval has lapsed.
    error NotApproved(address account);

    /// @notice The sender is frozen. Frozen accounts can still receive.
    error SenderFrozen(address account);

    /// @notice The sender has no tier, so no limit applies to it and it cannot transact.
    /// @dev Falling back to the strictest tier would let an unclassified address transact at
    ///      a limit nobody assigned it. "No tier" is an onboarding problem (section 4).
    error TierUnset(address account);

    /// @notice The transfer exceeds the sender's per-transaction cap.
    error TransactionLimitExceeded(address account, uint256 value, uint256 limit);

    /// @notice The transfer would take the sender past its cap for the current UTC day.
    error DailyLimitExceeded(address account, uint256 value, uint256 spent, uint256 limit);

    /// @notice The UNSET tier cannot be configured; it always refuses.
    error CannotConfigureUnsetTier();

    /// @notice A daily cap must fit the accumulator, or be NO_LIMIT.
    error DailyLimitTooLarge(uint256 limit);

    /// @notice `burnFrom` was called on an account that has not been frozen first.
    /// @dev The frozen precondition is the whole control: destruction can only follow a
    ///      public, attributed, reversible act by a different role (section 7).
    error AccountNotFrozen(address account);

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

    /// @notice Emitted on mint. Every supply change is attributed to the acting issuer.
    event Minted(address indexed to, uint256 value, address indexed issuer);

    /// @notice Emitted when an issuer burns from its own balance.
    event Burned(address indexed from, uint256 value, address indexed issuer);

    /// @notice Emitted when a tier's caps change. The whole policy is three of these.
    event TierLimitsSet(Tier indexed tier, uint256 perTransaction, uint256 perDay, address indexed by);

    /// @notice Emitted when an issuer burns from a frozen holder that has not consented.
    /// @dev Distinct from `Burned` so a seizure is never mistaken for a redemption.
    event ForcedBurn(address indexed account, uint256 value, bytes32 reason, address indexed issuer);

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

    /// @inheritdoc ERC20
    /// @dev Granting new spending authority during an incident serves no purpose and could
    ///      stage a drain for the moment the pause lifts (section 6).
    function approve(address spender, uint256 value) public override whenNotPaused returns (bool) {
        return super.approve(spender, value);
    }

    /// @dev The one place every transfer, mint and burn passes through: in OpenZeppelin
    ///      v5.6.1 _update is the only virtual hook on the transfer path.
    /// @dev whenNotPaused here covers transfers, mints and burns in one place (section 6).
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        // A burn (to == 0) delivers to nobody, so the sender side is not guarded: there is
        // no counterparty to protect, and it is what makes burnFrom possible (section 3).
        if (from != address(0) && to != address(0)) {
            if (!registry.isApproved(from)) revert NotApproved(from);
            if (frozen[from]) revert SenderFrozen(from);

            (bool accumulate, uint216 newSpent) = _checkLimits(from, value);
            if (accumulate) _usage[from] = DailyUsage({day: _today(), spent: newSpent});
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

    // ---------------------------------------------------------------------------------
    // Pause (section 6)
    // ---------------------------------------------------------------------------------

    /// @notice Halt all transfers, mints, burns and approvals. Views stay readable.
    /// @dev A network-incident control. Freeze is the per-address instrument (section 6).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------------------
    // Supply (section 7)
    // ---------------------------------------------------------------------------------

    /// @notice Money entering the system: a deposit of reserves, or an issuer creating a
    ///         liability. The recipient must be approved; no supply path consumes a tier cap.
    function mint(address to, uint256 value) external onlyRole(ISSUER_ROLE) {
        _mint(to, value);
        emit Minted(to, value, msg.sender);
    }

    /// @notice The ordinary redemption route: takes from the issuer's own balance.
    /// @dev To withdraw from a customer, the customer transfers to the issuer first and the
    ///      issuer burns. Every cooperative redemption uses this and only this.
    function burn(uint256 value) external onlyRole(ISSUER_ROLE) {
        _burn(msg.sender, value);
        emit Burned(msg.sender, value, msg.sender);
    }

    /// @notice Take from a holder that has not consented. Reverts unless already frozen.
    /// @dev It names no recipient, so it can only destroy: total supply falls, which makes a
    ///      seizure visible in supply reconciliation rather than reading as a payment.
    function burnFrom(address account, uint256 value, bytes32 reason) external onlyRole(ISSUER_ROLE) {
        if (!frozen[account]) revert AccountNotFrozen(account);
        _burn(account, value);
        emit ForcedBurn(account, value, reason, msg.sender);
    }

    // ---------------------------------------------------------------------------------
    // Limit policy (section 4)
    // ---------------------------------------------------------------------------------

    /// @dev Both caps for the sender's tier, reading tierOf exactly once.
    /// @return accumulate Whether the sender's daily total needs writing back.
    /// @return newSpent The total to write, valid only when `accumulate` is true.
    function _checkLimits(address from, uint256 value) private view returns (bool accumulate, uint216 newSpent) {
        Tier tier = registry.tierOf(from);
        if (tier == Tier.UNSET) revert TierUnset(from);

        TierLimits memory limits = _limits[tier];

        if (limits.perTransaction != NO_LIMIT && value > limits.perTransaction) {
            revert TransactionLimitExceeded(from, value, limits.perTransaction);
        }

        // An uncapped tier skips both the comparison and the storage write, so it never pays
        // for an accumulator it does not use.
        if (limits.perDay == NO_LIMIT) return (false, 0);

        // A fixed calendar-day window: if the stored day is not today, the total resets.
        DailyUsage memory usage = _usage[from];
        uint256 spent = usage.day == _today() ? usage.spent : 0;

        uint256 total = spent + value;
        if (total > limits.perDay) revert DailyLimitExceeded(from, value, spent, limits.perDay);

        // Safe to narrow: total <= perDay, and setTierLimits refuses a perDay above the range.
        return (true, uint216(total));
    }

    /// @dev Days since the Unix epoch, so the window rolls at 00:00 UTC for every holder.
    function _today() private view returns (uint40) {
        return uint40(block.timestamp / 1 days);
    }

    /// @notice Set both caps for a tier. Either may be NO_LIMIT.
    /// @dev Takes a Tier, never an address: the entire policy is three entries, readable in
    ///      full, where per-address overrides would scatter it across holders (section 4).
    function setTierLimits(Tier tier, uint256 perTransaction, uint256 perDay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tier == Tier.UNSET) revert CannotConfigureUnsetTier();
        if (perDay != NO_LIMIT && perDay > type(uint216).max) revert DailyLimitTooLarge(perDay);

        _limits[tier] = TierLimits({perTransaction: perTransaction, perDay: perDay});
        emit TierLimitsSet(tier, perTransaction, perDay, msg.sender);
    }

    /// @notice The caps configured for a tier. Zero on both means the tier cannot transact.
    function tierLimits(Tier tier) external view returns (uint256 perTransaction, uint256 perDay) {
        TierLimits memory limits = _limits[tier];
        return (limits.perTransaction, limits.perDay);
    }

    /// @notice How much an address has already sent during the current UTC day.
    /// @dev Reports zero once the stored day is stale, which is what the next transfer sees.
    function dailySpent(address account) external view returns (uint256) {
        DailyUsage memory usage = _usage[account];
        return usage.day == _today() ? usage.spent : 0;
    }
}
