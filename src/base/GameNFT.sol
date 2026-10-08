// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title GameNFT
/// @notice Shared base for MysticLands collections: capped supply, role-based minting,
///         on-chain enumeration (the game lists a wallet's NFTs without an indexer) and
///         a one-way switch that locks the list of minters.
/// @dev Only game contracts (e.g. MysticSeedShop) should hold MINTER_ROLE. Once they are set,
///      the admin calls {freezeMinters} and nobody (not even the admin) can add a new minter,
///      so the team cannot mint rare NFTs to itself later.
abstract contract GameNFT is ERC721, ERC721Enumerable, ERC721Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Maximum number of tokens that can ever be minted (burned tokens still count).
    uint256 public immutable maxSupply;

    /// @notice Number of tokens minted so far. Token ids go from 1 to `totalMinted`.
    uint256 public totalMinted;

    /// @notice When true, MINTER_ROLE can no longer be granted.
    bool public mintersFrozen;

    string private _baseTokenURI;

    event MintersFrozen();
    event BaseURIUpdated(string baseURI);

    error MaxSupplyReached();
    error MintersAreFrozen();

    constructor(string memory name_, string memory symbol_, address admin, uint256 maxSupply_, string memory baseURI_)
        ERC721(name_, symbol_)
    {
        maxSupply = maxSupply_;
        _baseTokenURI = baseURI_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Permanently locks the list of minters.
    function freezeMinters() external onlyRole(DEFAULT_ADMIN_ROLE) {
        mintersFrozen = true;
        emit MintersFrozen();
    }

    function setBaseURI(string calldata baseURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }

    /// @notice All token ids owned by `owner` (convenience for the game; fine for game-sized wallets).
    function tokensOfOwner(address owner) external view returns (uint256[] memory ids) {
        uint256 count = balanceOf(owner);
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = tokenOfOwnerByIndex(owner, i);
        }
    }

    /// @dev Reserves the next token id, enforcing the supply cap.
    function _nextId() internal returns (uint256 id) {
        if (totalMinted >= maxSupply) revert MaxSupplyReached();
        id = ++totalMinted;
    }

    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        if (role == MINTER_ROLE && mintersFrozen) revert MintersAreFrozen();
        return super._grantRole(role, account);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 amount) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, amount);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
