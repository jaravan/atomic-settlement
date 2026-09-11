// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title DvPSettlement
/// @notice One transaction that moves both legs of a trade, or neither. Holds no balances
///         and takes no custody: cash moves buyer to seller and the bond seller to buyer,
///         directly, and the only state kept here is the record of proposed trades.
/// @dev Design: doc/design-settlement.md. Section numbers in comments refer to it.
contract DvPSettlement {
    // ---------------------------------------------------------------------------------
    // Trades (section 3)
    // ---------------------------------------------------------------------------------

    /// @notice Where a trade is in its life. Expiry is not a status: it is computed from the
    ///         deadline, so an expired trade is dead without anyone paying to kill it.
    enum Status {
        NONE,
        PROPOSED,
        SETTLED,
        CANCELLED
    }

    /// @notice A settlement instruction. The seller writes it; the buyer executes it.
    struct Trade {
        address seller;
        address buyer;
        address cashToken;
        uint256 cashAmount;
        address assetToken;
        uint256 assetAmount;
        bytes3 currency;
        bytes12 isin;
        uint64 deadline;
        Status status;
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
            buyer: terms.buyer,
            cashToken: terms.cashToken,
            cashAmount: terms.cashAmount,
            assetToken: terms.assetToken,
            assetAmount: terms.assetAmount,
            currency: terms.currency,
            isin: terms.isin,
            deadline: terms.deadline,
            status: Status.PROPOSED
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
}
