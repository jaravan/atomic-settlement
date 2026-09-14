// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ICashLeg, IAssetLeg} from "./interfaces/ISettlementLegs.sol";

/// @title DvPSettlement
/// @notice One transaction that moves both legs of a trade, or neither. Holds no balances
///         and takes no custody: cash moves buyer to seller and the bond seller to buyer,
///         directly, and the only state kept here is the record of proposed trades.
/// @dev Design: doc/design-settlement.md. Section numbers in comments refer to it.
contract DvPSettlement {
    // ---------------------------------------------------------------------------------
    // Trades (section 3)
    // ---------------------------------------------------------------------------------

    /// @notice Where a trade is in its lifecycle. Expiry is not a status; it's computed from
    ///         the deadline, so nobody has to send a transaction to expire a trade.
    enum Status {
        NONE,
        PROPOSED,
        SETTLED,
        CANCELLED
    }

    /// @notice A settlement instruction. The seller writes it; the buyer executes it.
    /// @dev Field order packs the record into six slots, the minimum for four addresses and
    ///      two full words: the small fields ride alongside `seller` and `buyer`.
    struct Trade {
        address seller;
        bytes3 currency;
        uint64 deadline;
        Status status;
        address buyer;
        bytes12 isin;
        address cashToken;
        address assetToken;
        uint256 cashAmount;
        uint256 assetAmount;
    }

    /// @notice The terms a seller states when proposing.
    /// @dev Currency and ISIN are what the seller *expects* the two addresses to be; settle
    ///      reads each token's immutable identifier and refuses a mismatch (section 6).
    struct Terms {
        address buyer;
        address cashToken;
        bytes3 currency;
        uint256 cashAmount;
        address assetToken;
        bytes12 isin;
        uint256 assetAmount;
        uint64 deadline;
    }

    // ---------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------

    /// @dev A counter, not a hash of the terms: two identical trades must not collide.
    uint256 private _nextTradeId = 1;

    mapping(uint256 tradeId => Trade) private _trades;

    // ---------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------

    /// @notice A term was zero, or the buyer is the seller.
    error InvalidTerms();

    /// @notice The deadline is not in the future. There are no open-ended proposals.
    error DeadlineNotInFuture(uint64 deadline);

    /// @notice The trade is not PROPOSED: never assigned, already settled, or cancelled.
    error TradeNotOpen(uint256 tradeId, Status status);

    /// @notice The caller is not the party the action belongs to.
    error NotSeller(uint256 tradeId, address caller);

    /// @notice Only the named buyer can settle: a proposal is addressed to one party.
    error NotBuyer(uint256 tradeId, address caller);

    /// @notice The deadline has passed. The record stays, harmless and unusable.
    error TradeExpired(uint256 tradeId, uint64 deadline);

    /// @notice The buyer's hash does not match the stored terms: the two instructions differ.
    error TermsMismatch(uint256 tradeId);

    /// @notice The cash token at the recorded address is not the currency the trade names.
    error WrongCurrency(address token, bytes3 expected, bytes3 actual);

    /// @notice The asset token at the recorded address is not the instrument the trade names.
    error WrongInstrument(address token, bytes12 expected, bytes12 actual);

    /// @notice A leg returned false instead of reverting. Neither of ours does; this is for
    ///         a token this contract did not ship with (section 7).
    error TransferFailed(address token);

    // ---------------------------------------------------------------------------------
    // Events (section 8)
    // ---------------------------------------------------------------------------------

    /// @notice A seller has recorded a settlement instruction addressed to one buyer.
    event TradeProposed(
        uint256 indexed tradeId,
        address indexed seller,
        address indexed buyer,
        address cashToken,
        uint256 cashAmount,
        address assetToken,
        uint256 assetAmount,
        uint64 deadline
    );

    /// @notice Both legs moved. Terms repeated rather than referenced, so a reconciliation
    ///         reading settlements alone can describe each one (section 8).
    event TradeSettled(
        uint256 indexed tradeId,
        address indexed seller,
        address indexed buyer,
        address cashToken,
        uint256 cashAmount,
        address assetToken,
        uint256 assetAmount
    );

    /// @notice The seller withdrew its instruction. No reason code: withdrawing your own
    ///         proposal isn't a compliance action (section 8).
    event TradeCancelled(uint256 indexed tradeId, address indexed seller, address indexed buyer);

    // ---------------------------------------------------------------------------------
    // Proposing (section 3)
    // ---------------------------------------------------------------------------------

    /// @notice Record a trade. The caller is the seller: it delivers the asset and receives
    ///         the cash. Only `terms.buyer` will be able to settle it.
    /// @dev Not a reservation: nothing is locked, and the seller's allowance is what makes
    ///      delivery possible when the buyer settles (section 3).
    function propose(Terms calldata terms) external returns (uint256 tradeId) {
        if (
            terms.buyer == address(0) || terms.buyer == msg.sender || terms.cashToken == address(0)
                || terms.assetToken == address(0) || terms.cashAmount == 0 || terms.assetAmount == 0
                || terms.currency == bytes3(0) || terms.isin == bytes12(0)
        ) {
            revert InvalidTerms();
        }
        if (terms.deadline <= block.timestamp) revert DeadlineNotInFuture(terms.deadline);

        tradeId = _nextTradeId++;

        _trades[tradeId] = Trade({
            seller: msg.sender,
            currency: terms.currency,
            deadline: terms.deadline,
            status: Status.PROPOSED,
            buyer: terms.buyer,
            isin: terms.isin,
            cashToken: terms.cashToken,
            assetToken: terms.assetToken,
            cashAmount: terms.cashAmount,
            assetAmount: terms.assetAmount
        });

        emit TradeProposed(
            tradeId,
            msg.sender,
            terms.buyer,
            terms.cashToken,
            terms.cashAmount,
            terms.assetToken,
            terms.assetAmount,
            terms.deadline
        );
    }

    /// @notice The stored record of a trade. `status` is NONE for an id never assigned.
    function trades(uint256 tradeId) external view returns (Trade memory) {
        return _trades[tradeId];
    }

    /// @notice The id the next proposal will receive.
    function nextTradeId() external view returns (uint256) {
        return _nextTradeId;
    }

    // ---------------------------------------------------------------------------------
    // Cancelling (section 3)
    // ---------------------------------------------------------------------------------

    /// @notice Withdraw a proposal. Seller only, and only while it is still PROPOSED.
    /// @dev The buyer has no cancel: declining is doing nothing until the deadline. An
    ///      expired trade can still be cancelled, which only tidies a record already dead.
    function cancel(uint256 tradeId) external {
        Trade storage trade = _trades[tradeId];

        if (trade.status != Status.PROPOSED) revert TradeNotOpen(tradeId, trade.status);
        if (msg.sender != trade.seller) revert NotSeller(tradeId, msg.sender);

        trade.status = Status.CANCELLED;
        emit TradeCancelled(tradeId, trade.seller, trade.buyer);
    }

    // ---------------------------------------------------------------------------------
    // The terms hash (section 2)
    // ---------------------------------------------------------------------------------

    /// @notice The hash a buyer passes to `settle`, computed from the buyer's own record of
    ///         the trade -- never from reading the proposal back and hashing that.
    /// @dev Includes trade id, contract address and chain id, so a hash only ever matches
    ///      the one trade it was computed for.
    function hashTerms(uint256 tradeId, address seller, Terms memory terms) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                tradeId,
                seller,
                terms.buyer,
                terms.cashToken,
                terms.currency,
                terms.cashAmount,
                terms.assetToken,
                terms.isin,
                terms.assetAmount,
                terms.deadline
            )
        );
    }

    // ---------------------------------------------------------------------------------
    // Settling (sections 2, 3, 4, 6, 7)
    // ---------------------------------------------------------------------------------

    /// @notice Execute a trade. The named buyer only, asserting the terms it agreed as a
    ///         hash. Both legs move in this transaction, or neither does.
    /// @dev Acceptance and execution are one call: splitting them would open a window in
    ///      which both parties have agreed and nothing has moved (section 3).
    function settle(uint256 tradeId, bytes32 termsHash) external {
        Trade storage trade = _trades[tradeId];
        (ICashLeg cash, IAssetLeg asset) = _checkSettle(tradeId, trade, termsHash, msg.sender);

        // Effect before interactions: a token that called back in would find the trade
        // no longer PROPOSED (section 7).
        trade.status = Status.SETTLED;

        // Cash first: it carries more checks, so it is the leg likelier to refuse.
        if (!cash.transferFrom(trade.buyer, trade.seller, trade.cashAmount)) revert TransferFailed(trade.cashToken);
        if (!asset.transferFrom(trade.seller, trade.buyer, trade.assetAmount)) {
            revert TransferFailed(trade.assetToken);
        }

        emit TradeSettled(
            tradeId, trade.seller, trade.buyer, trade.cashToken, trade.cashAmount, trade.assetToken, trade.assetAmount
        );
    }

    /// @dev Everything settle checks before it touches a balance, in the same order canSettle
    ///      uses so the view reports the same cause the transaction would. Returns both legs.
    function _checkSettle(uint256 tradeId, Trade storage trade, bytes32 termsHash, address caller)
        private
        view
        returns (ICashLeg cash, IAssetLeg asset)
    {
        if (trade.status != Status.PROPOSED) revert TradeNotOpen(tradeId, trade.status);
        if (caller != trade.buyer) revert NotBuyer(tradeId, caller);
        if (block.timestamp > trade.deadline) revert TradeExpired(tradeId, trade.deadline);
        if (termsHash != _storedHash(tradeId, trade)) revert TermsMismatch(tradeId);

        // The addresses really are the instruments the trade names (section 6).
        cash = ICashLeg(trade.cashToken);
        asset = IAssetLeg(trade.assetToken);
        bytes3 currency = cash.currency();
        if (currency != trade.currency) revert WrongCurrency(trade.cashToken, trade.currency, currency);
        bytes12 isin = asset.isin();
        if (isin != trade.isin) revert WrongInstrument(trade.assetToken, trade.isin, isin);
    }

    // ---------------------------------------------------------------------------------
    // Previewing a settlement (section 5)
    // ---------------------------------------------------------------------------------

    /// @notice Whether `settle` would succeed right now, were the named buyer to call it.
    /// @dev Makes no registry call of its own. Each token answers for its leg through its
    ///      own preview, so there's no second copy of the compliance rules here.
    /// @return ok True if it would go through.
    /// @return reason The selector of the error it would revert with, or 0 when `ok`.
    function canSettle(uint256 tradeId, bytes32 termsHash) external view returns (bool ok, bytes4 reason) {
        try this.previewSettle(tradeId, termsHash) {
            return (true, bytes4(0));
        } catch (bytes memory err) {
            return (false, _selectorOf(err));
        }
    }

    /// @notice Reverts with the error a real `settle` would, assuming the buyer calls it.
    /// @dev Backs `canSettle`: this contract's own checks, then the cash leg, then the asset
    ///      leg, in the order settle would hit them.
    function previewSettle(uint256 tradeId, bytes32 termsHash) external view {
        Trade storage trade = _trades[tradeId];
        (ICashLeg cash, IAssetLeg asset) = _checkSettle(tradeId, trade, termsHash, trade.buyer);

        (bool ok, bytes4 reason) = cash.canTransferFrom(address(this), trade.buyer, trade.seller, trade.cashAmount);
        if (!ok) _revertWith(reason);

        (ok, reason) = asset.canTransferFrom(address(this), trade.seller, trade.buyer, trade.assetAmount);
        if (!ok) _revertWith(reason);
    }

    /// @dev Re-raise a leg's answer as a revert carrying just the selector.
    function _revertWith(bytes4 selector) private pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 4)
        }
    }

    /// @dev The leading four bytes of returndata, or zero if there are not four to take.
    function _selectorOf(bytes memory err) private pure returns (bytes4 selector) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(err, 0x20))
        }
    }

    /// @dev The stored record, hashed exactly as `hashTerms` would hash the buyer's copy.
    function _storedHash(uint256 tradeId, Trade storage trade) private view returns (bytes32) {
        return hashTerms(
            tradeId,
            trade.seller,
            Terms({
                buyer: trade.buyer,
                cashToken: trade.cashToken,
                currency: trade.currency,
                cashAmount: trade.cashAmount,
                assetToken: trade.assetToken,
                isin: trade.isin,
                assetAmount: trade.assetAmount,
                deadline: trade.deadline
            })
        );
    }
}
