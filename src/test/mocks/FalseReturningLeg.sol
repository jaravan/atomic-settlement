// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice A leg that reports its identity correctly and then returns false from transferFrom
///         instead of reverting -- the classic non-standard ERC-20 (settlement section 7).
contract FalseReturningLeg {
    bytes3 public immutable currency;
    bytes12 public immutable isin;

    constructor(bytes3 currency_, bytes12 isin_) {
        currency = currency_;
        isin = isin_;
    }

    function canTransferFrom(address, address, address, uint256) external pure returns (bool, bytes4) {
        return (true, bytes4(0));
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}
