// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";

contract ERC721Momento is ERC721URIStorageUpgradeable {
    struct TokenData {
        address payable creator; // creator of the NFT
        uint256 royalties; // royalties to be paid to NFT creator on a resale. In basic points
    }
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;
    mapping(uint256 => TokenData) private tokens;
    string private baseURI;

    event CreateERC721Momento(address owner, string name, string symbol);

    function initialize(string memory baseURI_) public initializer {
        __ERC721_init("Momento NFT", "MNTNFT");
        __ERC721URIStorage_init();
        _setBaseURI(baseURI_);
        emit CreateERC721Momento(_msgSender(), name(), symbol());
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    function _setBaseURI(string memory baseURI_) internal {
        baseURI = baseURI_;
    }

    function getCreator(uint256 tokenId_) public view returns (address) {
        return tokens[tokenId_].creator;
    }

    // returns in basic points the royalties of a token
    function getRoyalties(uint256 tokenId_) public view returns (uint256) {
        return tokens[tokenId_].royalties;
    }

    // mints the NFT and save the data in the "tokens" map
    function createItem(string memory tokenURI_, uint256 royalties_)
        public
        returns (uint256)
    {
        require(royalties_ <= 5000, "Max royalties are 50%");

        _tokenIds.increment();

        uint256 newItemId = _tokenIds.current();
        _mint(msg.sender, newItemId);
        _setTokenURI(newItemId, tokenURI_);

        tokens[newItemId] = TokenData({
            creator: payable(msg.sender),
            royalties: royalties_
        });
        return newItemId;
    }
}
