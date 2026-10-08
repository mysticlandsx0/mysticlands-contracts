// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IMarketPol {
    function list(address collection, uint256 tokenId, uint256 price) external;
    function buy(address collection, uint256 tokenId) external payable;
}

/// @dev Vendedor cuja carteira recusa POL: nao pode travar a compra.
contract RejectingSeller {
    function listOn(IMarketPol market, address collection, uint256 tokenId, uint256 price) external {
        IERC721(collection).setApprovalForAll(address(market), true);
        market.list(collection, tokenId, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @dev Comprador que, ao receber o NFT, tenta comprar outro anuncio na mesma transacao.
contract ReentrantPolBuyer {
    IMarketPol private market;
    address private collection;
    uint256 private second;
    uint256 private secondPrice;

    function attack(IMarketPol market_, address collection_, uint256 first, uint256 second_, uint256 firstPrice, uint256 secondPrice_)
        external
        payable
    {
        market = market_;
        collection = collection_;
        second = second_;
        secondPrice = secondPrice_;
        market_.buy{value: firstPrice}(collection_, first);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (second != 0) {
            uint256 id = second;
            second = 0;
            market.buy{value: secondPrice}(collection, id);
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
