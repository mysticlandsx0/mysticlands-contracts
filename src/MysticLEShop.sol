// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title MysticLands LE Shop
/// @notice Players buy Light Energy (in-game currency) with POL. The game server credits the LE after
///         reading the `LeBought` event. The POL goes to `treasury` (the revenue splitter: 60% treasury,
///         40% reward pool).
/// @dev Price is set in USD per 10,000 LE and converted with the Chainlink POL/USD feed (or a fixed POL
///      price on testnet). The LE price is kept above the maximum LE -> POL reward rate so buying LE to
///      cash it out always loses money.
contract MysticLEShop is Ownable2Step, Pausable, ReentrancyGuard {
    uint256 public constant LE_PER_PACK = 10_000;

    address public treasury;
    AggregatorV3Interface public priceFeed;
    uint256 public usdPerPack; // 8 casas (100_000_000 = US$ 1 por 10.000 LE)
    uint256 public polPerPack; // POL wei por 10.000 LE quando nao ha oraculo
    uint256 public maxStaleness = 1 days;
    uint256 public maxLePerPurchase = 1_000_000;
    uint256 public purchaseCount;

    event LeBought(address indexed buyer, uint256 indexed purchaseId, uint256 polPaid, uint256 leAmount);
    event PricingUpdated(address feed, uint256 usdPerPack, uint256 polPerPack);
    event TreasuryUpdated(address treasury);

    error ZeroAddress();
    error InvalidPrice();
    error StalePrice();
    error BelowMinimum(uint256 le, uint256 minLe);
    error AboveMaximum(uint256 le);
    error TransferFailed();

    constructor(address initialOwner, address treasury_, address feed, uint256 usdPerPack_, uint256 polPerPack_) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        _setPricing(feed, usdPerPack_, polPerPack_);
    }

    /// @notice POL (wei) por 10.000 LE agora.
    function packPriceInPol() public view returns (uint256) {
        if (address(priceFeed) == address(0)) return polPerPack;
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        return (usdPerPack * 1e18) / uint256(answer);
    }

    /// @notice LE recebido por `polWei`.
    function quote(uint256 polWei) public view returns (uint256) {
        return (polWei * LE_PER_PACK) / packPriceInPol();
    }

    function buy(uint256 minLe) external payable whenNotPaused nonReentrant returns (uint256 le) {
        le = quote(msg.value);
        if (le == 0 || le < minLe) revert BelowMinimum(le, minLe);
        if (le > maxLePerPurchase) revert AboveMaximum(le);
        (bool ok,) = treasury.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
        emit LeBought(msg.sender, ++purchaseCount, msg.value, le);
    }

    function setPricing(address feed, uint256 usdPerPack_, uint256 polPerPack_) external onlyOwner {
        _setPricing(feed, usdPerPack_, polPerPack_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setMaxLePerPurchase(uint256 max) external onlyOwner {
        maxLePerPurchase = max;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _setPricing(address feed, uint256 usdPerPack_, uint256 polPerPack_) private {
        if (feed == address(0) ? polPerPack_ == 0 : usdPerPack_ == 0) revert InvalidPrice();
        priceFeed = AggregatorV3Interface(feed);
        usdPerPack = usdPerPack_;
        polPerPack = polPerPack_;
        emit PricingUpdated(feed, usdPerPack_, polPerPack_);
    }
}
