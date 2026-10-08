// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MysticLands Market (POL)
/// @notice Fixed-price, non-custodial marketplace for MysticLands NFTs, paid in POL.
///         The NFT stays in the seller's wallet until it is sold (the market only needs approval).
/// @dev The fee is capped in code at 10% and is locked into each listing when it is created,
///      so the owner can never change the fee of a sale that is already listed.
///      The fee goes to the treasury (the revenue splitter). If a seller's wallet refuses POL, the amount is
///      kept here for the seller to {withdraw}, so no seller can block purchases.
contract MysticMarketPol is Ownable2Step, Pausable, ReentrancyGuard {

    struct Listing {
        address seller;
        uint96 feeBps;
        uint256 price;
    }

    uint96 public constant MAX_FEE_BPS = 1_000; // 10%
    uint96 private constant BPS = 10_000;

    address public treasury;
    /// @notice POL owed to sellers whose wallet refused the payment.
    mapping(address seller => uint256) public pendingWithdrawals;
    uint96 public feeBps;

    mapping(address collection => bool) public allowedCollection;
    mapping(address collection => mapping(uint256 tokenId => Listing)) public listings;

    // lista de anuncios ativos (o jogo le direto do contrato, sem indexador)
    struct Key {
        address collection;
        uint256 tokenId;
    }

    Key[] private _active;
    mapping(address collection => mapping(uint256 tokenId => uint256 indexPlusOne)) private _activeIndex;

    event Listed(address indexed collection, uint256 indexed tokenId, address indexed seller, uint256 price, uint96 feeBps);
    event Cancelled(address indexed collection, uint256 indexed tokenId);
    event Sold(address indexed collection, uint256 indexed tokenId, address indexed buyer, address seller, uint256 price, uint256 fee);
    event FeeUpdated(uint96 feeBps);
    event TreasuryUpdated(address treasury);
    event CollectionUpdated(address indexed collection, bool allowed);
    event PaymentHeld(address indexed seller, uint256 amount);
    event Withdrawn(address indexed seller, uint256 amount);

    error CollectionNotAllowed();
    error InvalidPrice();
    error NotTokenOwner();
    error MarketNotApproved();
    error NotListed();
    error StaleListing();
    error CannotBuyOwnListing();
    error FeeTooHigh();
    error ZeroAddress();
    error WrongPayment(uint256 sent, uint256 price);
    error TransferFailed();
    error NothingToWithdraw();

    constructor(address initialOwner, address treasury_, uint96 feeBps_) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        treasury = treasury_;
        feeBps = feeBps_;
    }

    /// @notice Lists (or re-prices) an NFT you own. Approve this contract on the collection first.
    function list(address collection, uint256 tokenId, uint256 price) external whenNotPaused {
        if (!allowedCollection[collection]) revert CollectionNotAllowed();
        if (price == 0) revert InvalidPrice();
        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (nft.getApproved(tokenId) != address(this) && !nft.isApprovedForAll(msg.sender, address(this))) {
            revert MarketNotApproved();
        }
        listings[collection][tokenId] = Listing(msg.sender, feeBps, price);
        if (_activeIndex[collection][tokenId] == 0) {
            _active.push(Key(collection, tokenId));
            _activeIndex[collection][tokenId] = _active.length;
        }
        emit Listed(collection, tokenId, msg.sender, price, feeBps);
    }

    /// @notice Removes a listing. The seller can always cancel; the current owner can clear
    ///         a listing left behind by a previous owner. Works while paused.
    function cancel(address collection, uint256 tokenId) external {
        Listing memory l = listings[collection][tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (msg.sender != l.seller && IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        _removeListing(collection, tokenId);
        emit Cancelled(collection, tokenId);
    }

    /// @notice Buys a listed NFT. Send exactly the listed price in POL (protects against re-pricing).
    function buy(address collection, uint256 tokenId) external payable whenNotPaused nonReentrant {
        Listing memory l = listings[collection][tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller == msg.sender) revert CannotBuyOwnListing();
        if (msg.value != l.price) revert WrongPayment(msg.value, l.price);
        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != l.seller) revert StaleListing();

        _removeListing(collection, tokenId);
        uint256 fee = (l.price * l.feeBps) / BPS;
        nft.safeTransferFrom(l.seller, msg.sender, tokenId);
        if (fee > 0) {
            (bool okFee,) = treasury.call{value: fee}("");
            if (!okFee) revert TransferFailed();
        }
        (bool okSeller,) = l.seller.call{value: l.price - fee, gas: 50_000}("");
        if (!okSeller) {
            pendingWithdrawals[l.seller] += l.price - fee;
            emit PaymentHeld(l.seller, l.price - fee);
        }
        emit Sold(collection, tokenId, msg.sender, l.seller, l.price, fee);
    }

    /// @notice Sends POL held for the caller (only when their wallet refused a payment).
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------- leitura

    /// @notice Number of active listings.
    function activeCount() external view returns (uint256) {
        return _active.length;
    }

    /// @notice A page of active listings. `valid` is false when the seller no longer owns the NFT.
    function activeListings(uint256 offset, uint256 limit)
        external
        view
        returns (
            address[] memory collections,
            uint256[] memory tokenIds,
            address[] memory sellers,
            uint256[] memory prices,
            bool[] memory valid
        )
    {
        uint256 end = offset + limit > _active.length ? _active.length : offset + limit;
        uint256 n = end > offset ? end - offset : 0;
        collections = new address[](n);
        tokenIds = new uint256[](n);
        sellers = new address[](n);
        prices = new uint256[](n);
        valid = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            Key memory k = _active[offset + i];
            Listing memory l = listings[k.collection][k.tokenId];
            collections[i] = k.collection;
            tokenIds[i] = k.tokenId;
            sellers[i] = l.seller;
            prices[i] = l.price;
            valid[i] = _ownerOf(k.collection, k.tokenId) == l.seller;
        }
    }

    function _ownerOf(address collection, uint256 tokenId) private view returns (address) {
        try IERC721(collection).ownerOf(tokenId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    // remove da lista em O(1): o ultimo anuncio ocupa a vaga
    function _removeListing(address collection, uint256 tokenId) private {
        delete listings[collection][tokenId];
        uint256 index = _activeIndex[collection][tokenId];
        if (index == 0) return;
        Key memory last = _active[_active.length - 1];
        _active[index - 1] = last;
        _activeIndex[last.collection][last.tokenId] = index;
        _active.pop();
        delete _activeIndex[collection][tokenId];
    }

    // ---------------------------------------------------------------- admin

    function setFee(uint96 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeUpdated(feeBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setCollection(address collection, bool allowed) external onlyOwner {
        allowedCollection[collection] = allowed;
        emit CollectionUpdated(collection, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
