// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MysticLands Revenue Splitter
/// @notice Every POL payment from the game shops lands here and is split on arrival:
///         `poolBps` (40% by default) goes to the Reward Pool and the rest to the treasury.
/// @dev Nothing stays in this contract. The pool share is capped between 20% and 60%.
///      Token payments (e.g. ML from the Seed Shop) are not split: anyone can push them to the treasury.
contract MysticRevenueSplitter is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_POOL_BPS = 2_000;
    uint256 public constant MAX_POOL_BPS = 6_000;

    address public treasury;
    address public pool;
    uint256 public poolBps;

    event Split(address indexed from, uint256 toTreasury, uint256 toPool);
    event TokenForwarded(address indexed token, uint256 amount);
    event ConfigUpdated(address treasury, address pool, uint256 poolBps);

    error ZeroAddress();
    error InvalidShare();
    error TransferFailed();

    constructor(address initialOwner, address treasury_, address pool_, uint256 poolBps_) Ownable(initialOwner) {
        _set(treasury_, pool_, poolBps_);
    }

    receive() external payable {
        uint256 toPool = (msg.value * poolBps) / 10_000;
        uint256 toTreasury = msg.value - toPool;
        (bool okPool,) = pool.call{value: toPool}("");
        (bool okTreasury,) = treasury.call{value: toTreasury}("");
        if (!okPool || !okTreasury) revert TransferFailed();
        emit Split(msg.sender, toTreasury, toPool);
    }

    /// @notice Sends the whole balance of an ERC-20 held here to the treasury (it can never go anywhere else).
    function flushToken(IERC20 token) external {
        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) return;
        token.safeTransfer(treasury, amount);
        emit TokenForwarded(address(token), amount);
    }

    function setConfig(address treasury_, address pool_, uint256 poolBps_) external onlyOwner {
        _set(treasury_, pool_, poolBps_);
    }

    function _set(address treasury_, address pool_, uint256 poolBps_) private {
        if (treasury_ == address(0) || pool_ == address(0)) revert ZeroAddress();
        if (poolBps_ < MIN_POOL_BPS || poolBps_ > MAX_POOL_BPS) revert InvalidShare();
        treasury = treasury_;
        pool = pool_;
        poolBps = poolBps_;
        emit ConfigUpdated(treasury_, pool_, poolBps_);
    }
}
