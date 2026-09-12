// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IKYCRegistryV2} from "kyc-registry/interfaces/IKYCRegistryV2.sol";

/// @title AssetToken
/// @notice The asset leg of an atomic DvP settlement: an ERC-20 standing for a single bond
///         issue, with compliance enforced by the contract itself.
/// @dev Design: doc/design-asset.md. Where it shares a decision with the cash leg it says so.
contract AssetToken is ERC20, AccessControl, Pausable {
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

    /// @notice Whether an address is frozen. A frozen address cannot send, but can receive.
    mapping(address account => bool) public frozen;

    // ---------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------

    /// @notice A constructor argument was the zero address or the zero ISIN.
    error InvalidConfiguration();

    /// @notice The account is not approved in the registry, or its approval has lapsed.
    error NotApproved(address account);

    /// @notice The sender is frozen. Frozen accounts can still receive.
    error SenderFrozen(address account);

    /// @notice `forceTransfer` was called on an account that has not been frozen first.
    /// @dev The frozen precondition is the whole control: a move without consent can only
    ///      follow a public, attributed, reversible act by a different role (section 8).
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

    /// @notice Emitted at issuance. Every supply change is attributed to the acting issuer.
    event Minted(address indexed to, uint256 value, address indexed issuer);

    /// @notice Emitted at redemption, from the issuer's own balance.
    event Burned(address indexed from, uint256 value, address indexed issuer);

    /// @notice Emitted alongside the ERC-20 Transfer when bonds are moved without the
    ///         holder's consent, so a seizure is a distinct event type in the log.
    event ForcedTransfer(
        address indexed from, address indexed to, uint256 value, bytes32 reason, address indexed issuer
    );

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
    function _update(address from, address to, uint256 value) internal override {
        _checkTransfer(from, to, value);
        super._update(from, to, value);
    }

    /// @dev The single predicate. Reverts with the exact error the caller should see; the
    ///      previews run this same function so they cannot disagree with enforcement.
    function _checkTransfer(address from, address to, uint256 value) private view {
        if (paused()) revert EnforcedPause();

        // A burn (to == 0) delivers to nobody, so the sender side is not guarded (section 3).
        // Unlike the cash leg, nothing here reads tierOf: there are no limits (section 4).
        if (from != address(0) && to != address(0)) {
            if (!registry.isApproved(from)) revert NotApproved(from);
            if (frozen[from]) revert SenderFrozen(from);

            // Included so a preview answers the whole question, not the compliance half.
            uint256 balance = balanceOf(from);
            if (balance < value) revert ERC20InsufficientBalance(from, balance, value);
        }

        // Also covers the mint recipient.
        if (to != address(0)) _checkRecipient(to);
    }

    /// @dev The one rule a forced transfer still applies, kept as one function so the two
    ///      callers cannot drift.
    function _checkRecipient(address to) private view {
        if (!registry.isApproved(to)) revert NotApproved(to);
    }

    // ---------------------------------------------------------------------------------
    // Previewing the checks (section 3)
    // ---------------------------------------------------------------------------------

    /// @notice Whether a direct `transfer` would succeed right now.
    /// @return ok True if it would go through.
    /// @return reason The selector of the error it would revert with, or 0 when `ok`.
    function canTransfer(address from, address to, uint256 value) external view returns (bool ok, bytes4 reason) {
        try this.previewTransfer(from, to, value) {
            return (true, bytes4(0));
        } catch (bytes memory err) {
            return (false, _selectorOf(err));
        }
    }

    /// @notice Whether a `transferFrom` would succeed right now.
    /// @dev Separate from `canTransfer` because only this path has a spender and an
    ///      allowance, so a caller asking about a plain payment invents neither.
    /// @return ok True if it would go through.
    /// @return reason The selector of the error it would revert with, or 0 when `ok`.
    function canTransferFrom(address spender, address from, address to, uint256 value)
        external
        view
        returns (bool ok, bytes4 reason)
    {
        try this.previewTransferFrom(spender, from, to, value) {
            return (true, bytes4(0));
        } catch (bytes memory err) {
            return (false, _selectorOf(err));
        }
    }

    /// @notice Reverts with the error a real `transfer` would.
    /// @dev Machinery for `canTransfer`. Running the predicate rather than reimplementing it
    ///      is what makes `reason` correct by construction rather than by convention.
    function previewTransfer(address from, address to, uint256 value) external view {
        _checkTransfer(from, to, value);
    }

    /// @notice Reverts with the error a real `transferFrom` would.
    /// @dev Checks run in the order the real call makes them: spender, allowance, transfer.
    function previewTransferFrom(address spender, address from, address to, uint256 value) external view {
        if (registry.isSanctioned(spender)) revert SpenderSanctioned(spender);

        uint256 allowed = allowance(from, spender);
        if (allowed < value) revert ERC20InsufficientAllowance(spender, allowed, value);

        _checkTransfer(from, to, value);
    }

    /// @dev The leading four bytes of returndata, or zero if there are not four to take.
    function _selectorOf(bytes memory err) private pure returns (bytes4 selector) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(err, 0x20))
        }
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

    /// @notice Halt all transfers, mints, burns and approvals on this instrument. Views stay
    ///         readable.
    /// @dev One deployment per issue, so this pauses one instrument, not the network.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------------------
    // Issuance and redemption (section 7)
    // ---------------------------------------------------------------------------------

    /// @notice Issuance. For a bond this normally happens once, to the arranger or the
    ///         initial allottees. The recipient must be approved.
    function mint(address to, uint256 value) external onlyRole(ISSUER_ROLE) {
        _mint(to, value);
        emit Minted(to, value, msg.sender);
    }

    /// @notice Redemption: takes from the issuer's own balance only.
    /// @dev The holder delivers the bond to the issuer and the issuer burns it. There is no
    ///      burnFrom; a non-cooperative redemption is forceTransfer then burn (section 8).
    function burn(uint256 value) external onlyRole(ISSUER_ROLE) {
        _burn(msg.sender, value);
        emit Burned(msg.sender, value, msg.sender);
    }

    // ---------------------------------------------------------------------------------
    // Forced transfer (section 8)
    // ---------------------------------------------------------------------------------

    /// @notice Move bonds from a holder that has not consented. Reverts unless the holder
    ///         is already frozen. Total supply is unchanged.
    /// @dev Not burn-and-mint: a bond issue is a fixed legal quantity, and a supply that dips
    ///      and recovers is a reconciliation break, not a signal (section 8).
    function forceTransfer(address from, address to, uint256 value, bytes32 reason)
        external
        onlyRole(ISSUER_ROLE)
        whenNotPaused
    {
        if (!frozen[from]) revert AccountNotFrozen(from);
        if (to == address(0)) revert ERC20InvalidReceiver(address(0)); // would be a burn
        _checkRecipient(to);

        // super._update is ERC20's own: the balances move, the sender-side checks in this
        // contract's override are not run. That is the whole bypass (section 8).
        super._update(from, to, value);

        emit ForcedTransfer(from, to, value, reason, msg.sender);
    }
}
