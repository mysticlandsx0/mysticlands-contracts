// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Test-only Chainlink price feed (8 decimals) with a settable answer and timestamp.
contract PriceFeedMock {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 answer_) {
        set(answer_, block.timestamp);
    }

    function set(int256 answer_, uint256 updatedAt_) public {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
