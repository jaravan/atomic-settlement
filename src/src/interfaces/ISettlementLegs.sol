// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice What the settlement contract needs from a cash leg: ERC-20 movement, the
///         instrument identity to verify, and the preview to compose (settlement section 5).
interface ICashLeg is IERC20 {
    function currency() external view returns (bytes3);
    function canTransferFrom(address spender, address from, address to, uint256 value)
        external
        view
        returns (bool ok, bytes4 reason);
}

/// @notice The same for an asset leg, identified by ISIN.
interface IAssetLeg is IERC20 {
    function isin() external view returns (bytes12);
    function canTransferFrom(address spender, address from, address to, uint256 value)
        external
        view
        returns (bool ok, bytes4 reason);
}
