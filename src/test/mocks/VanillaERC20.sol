// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Unmodified OpenZeppelin ERC20, the baseline the compliance overhead is measured
///         against. Six decimals so the numbers are like for like.
contract VanillaERC20 is ERC20 {
    constructor() ERC20("Vanilla", "VAN") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}
