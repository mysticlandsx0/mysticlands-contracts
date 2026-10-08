// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GameNFT} from "./base/GameNFT.sol";

/// @title MysticLands Plant (MLP)
/// @notice Plant and Mother Tree NFTs. Species, variant, rarity and DNA live on-chain;
///         the game derives LE production and stats from them.
/// @dev Species ids match `src/config/species.js` in the game:
///      0-39 are plants, 90-93 are mother trees. Variants 0-2, rarities 0-3
///      (common, uncommon, rare, mythic).
contract MysticPlant is GameNFT {
    enum Kind {
        Plant,
        Mother
    }

    struct Traits {
        uint8 species;
        uint8 variant;
        uint8 rarity;
        Kind kind;
        uint64 bornAt;
        uint256 dna;
    }

    uint8 public constant PLANT_SPECIES = 40;
    uint8 public constant MOTHER_FIRST_ID = 90;
    uint8 public constant MOTHER_SPECIES = 4;
    uint8 public constant VARIANTS = 3;
    uint8 public constant RARITIES = 4;

    mapping(uint256 tokenId => Traits) private _traits;

    event PlantMinted(address indexed to, uint256 indexed tokenId, uint8 species, uint8 variant, uint8 rarity, uint256 dna);

    error InvalidTraits();

    constructor(address admin, uint256 maxSupply_, string memory baseURI_)
        GameNFT("MysticLands Plant", "MLP", admin, maxSupply_, baseURI_)
    {}

    /// @notice Mints a plant or mother tree. Only game contracts with MINTER_ROLE.
    function mint(address to, uint8 species, uint8 variant, uint8 rarity, uint256 dna)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 tokenId)
    {
        Kind kind;
        if (species < PLANT_SPECIES) {
            kind = Kind.Plant;
        } else if (species >= MOTHER_FIRST_ID && species < MOTHER_FIRST_ID + MOTHER_SPECIES) {
            kind = Kind.Mother;
        } else {
            revert InvalidTraits();
        }
        if (variant >= VARIANTS || rarity >= RARITIES) revert InvalidTraits();

        tokenId = _nextId();
        _traits[tokenId] = Traits(species, variant, rarity, kind, uint64(block.timestamp), dna);
        _mint(to, tokenId);
        emit PlantMinted(to, tokenId, species, variant, rarity, dna);
    }

    /// @notice On-chain traits of a token. Reverts if it does not exist.
    function traitsOf(uint256 tokenId) external view returns (Traits memory) {
        _requireOwned(tokenId);
        return _traits[tokenId];
    }

    /// @notice Traits of many tokens in one call (used by the game server to sync a wallet).
    function traitsBatch(uint256[] calldata tokenIds) external view returns (Traits[] memory list) {
        list = new Traits[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _requireOwned(tokenIds[i]);
            list[i] = _traits[tokenIds[i]];
        }
    }
}
