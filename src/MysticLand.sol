// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GameNFT} from "./base/GameNFT.sol";

/// @title MysticLands Land (MLL)
/// @notice Land NFTs on a 201 x 201 map (coordinates -100..100). Each cell can be owned once.
///         Rarity defines farm capacity in the game: common 5+1, rare 7+1, mythic 10+2 slots.
contract MysticLand is GameNFT {
    struct Land {
        uint8 rarity;
        int16 x;
        int16 y;
    }

    int16 public constant MAP_RADIUS = 100;
    uint256 public constant MAP_CELLS = 201 * 201;
    uint8 public constant RARITIES = 3;

    mapping(uint256 tokenId => Land) private _lands;
    mapping(uint256 cell => bool) public cellTaken;

    event LandMinted(address indexed to, uint256 indexed tokenId, uint8 rarity, int16 x, int16 y);

    error InvalidTraits();

    constructor(address admin, uint256 maxSupply_, string memory baseURI_)
        GameNFT("MysticLands Land", "MLL", admin, maxSupply_, baseURI_)
    {
        require(maxSupply_ <= MAP_CELLS, "supply above map size");
    }

    /// @notice Mints a land on a free cell picked from `seed` (a random word from Chainlink VRF).
    /// @dev Starts at a pseudo-random cell and walks forward until it finds a free one.
    ///      Since maxSupply <= MAP_CELLS, a free cell always exists while minting is allowed.
    function mint(address to, uint8 rarity, uint256 seed) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        if (rarity >= RARITIES) revert InvalidTraits();
        tokenId = _nextId();

        uint256 cell = seed % MAP_CELLS;
        while (cellTaken[cell]) {
            cell = (cell + 1) % MAP_CELLS;
        }
        cellTaken[cell] = true;

        int16 x = int16(int256(cell % 201)) - MAP_RADIUS;
        int16 y = int16(int256(cell / 201)) - MAP_RADIUS;
        _lands[tokenId] = Land(rarity, x, y);
        _mint(to, tokenId);
        emit LandMinted(to, tokenId, rarity, x, y);
    }

    /// @notice On-chain data of a land. Reverts if it does not exist.
    function landOf(uint256 tokenId) external view returns (Land memory) {
        _requireOwned(tokenId);
        return _lands[tokenId];
    }

    /// @notice Data of many lands in one call (used by the game server to sync a wallet).
    function landsBatch(uint256[] calldata tokenIds) external view returns (Land[] memory list) {
        list = new Land[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _requireOwned(tokenIds[i]);
            list[i] = _lands[tokenIds[i]];
        }
    }
}
