// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";

contract ERC721Momento is ERC721URIStorageUpgradeable {
    struct TokenData {
        address payable creator; // creator of the NFT
        uint256 royalties; // royalties to be paid to NFT creator on a resale. In basic points
    }
    using CountersUpgradeable for CountersUpgradeable.Counter;
    CountersUpgradeable.Counter private __tokenIds;
    mapping(uint256 => TokenData) private __tokens;
    string private __baseURI;

    event CreateERC721Momento(address owner, string name, string symbol);

    event CreateItem(uint256 tokenId, string tokenURI, uint256 royalties);

    function initialize(string memory baseURI_) public initializer {
        __ERC721_init("Momento NFT", "MNTNFT");
        __ERC721URIStorage_init();
        _setBaseURI(baseURI_);
        emit CreateERC721Momento(_msgSender(), name(), symbol());
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return __baseURI;
    }

    function _setBaseURI(string memory baseURI_) internal {
        __baseURI = baseURI_;
    }

    function baseURI() public view returns(string memory) {
        return _baseURI();
    }

    function setBaseURI(string memory baseURI_) public {
        _setBaseURI(baseURI_);
    }

    function getCreator(uint256 tokenId_) public view returns (address) {
        return __tokens[tokenId_].creator;
    }

    // returns in basic points the royalties of a token
    function getRoyalties(uint256 tokenId_) public view returns (uint256) {
        return __tokens[tokenId_].royalties;
    }

    // mints the NFT and save the data in the "tokens" map
    function createItem( string memory tokenURI_, uint256 royalties_)
        public
        returns (uint256)
    {
        require(royalties_ <= 1000, "Max royalties are 10%");

        __tokenIds.increment();

        uint256 newItemId = __tokenIds.current();
        _safeMint(msg.sender, newItemId);
        _setTokenURI(newItemId, tokenURI_);

        __tokens[newItemId] = TokenData({
            creator: payable(msg.sender),
            royalties: royalties_
        });
        return newItemId;
    }
}
