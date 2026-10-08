// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Token ERC-20 qualquer, so para testes (ex.: token enviado por engano ao divisor).
contract TokenMock is ERC20 {
    constructor(uint256 supply) ERC20("Test Token", "TEST") {
        _mint(msg.sender, supply);
    }
}
