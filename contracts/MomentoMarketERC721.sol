// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./ERC721Momento.sol";

contract MomentoMarketERC721 is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Event triggered when an offer is created
    event OfferCreated(
        uint256 tokenId,
        address creator,
        address asset,
        uint256 numCopies,
        uint256 amount,
        bool isSale
    );

    // Event triggered when an auction is created
    event AuctionCreated(
        uint256 auctionId,
        address creator,
        uint256 tokenId,
        uint256 startPrice
    );
    // Event triggered when an auction receives a bid
    event AuctionBid(uint256 index, address bidder, uint256 amount);

    // Event triggered when an ended auction winner claims the NFT
    event Claim(uint256 auctionIndex, address claimer);

    // Event triggered when an auction received a bid that implies sending funds back to previous best bidder
    event ReturnBidFunds(uint256 index, address bidder, uint256 amount);

    // Event triggered when a royalties payment is generated, either on direct sales or on auctions
    event Royalties(address receiver, uint256 amount);

    // Event triggered when a payment to the owner is generated, either on direct sales or on auctions.assetAddress
    // This event is useful to check that all the payments funds are the right ones.
    event PaymentToOwner(
        address receiver,
        uint256 amount,
        uint256 commission,
        uint256 royalties,
        uint256 safetyCheckValue
    );
    event Buy(uint256 index, address buyer, uint256 amount);

    // Status of an auction, calculated using the start date, the duration and the current timeblock
    enum Status {
        Pending,
        Active,
        Finished
    }
    // Data of an auction
    struct Auction {
        address assetAddress; // token address
        uint256 assetId; // token id
        address payable creator; // creator of the auction, which is the token owner
        uint256 startTime; // time (unix, in seconds) where the auction will start
        uint256 duration; // duration in seconds of the auction
        uint256 currentBidAmount; // amount in ETH of the current bid amount
        address payable currentBidOwner; // address of the user who places the best bid
        uint256 bidCount; // number of bids of the auction
    }
    Auction[] public auctions;

    uint256 public commission = 0; // this is the commission in basic points that will charge the marketplace by default.
    uint256 public accumulatedCommission = 0; // this is the amount in ETH accumulated on marketplace wallet
    uint256 public totalSales = 0;

    struct Offer {
        address assetAddress; // address of the token
        uint256 tokenId; // the tokenId returned when calling "createItem"
        address payable creator; // who creates the offer
        uint256 price; // price of each token
        bool isOnSale; // is on sale or not
        bool isAuction; // is this offer is for an auction
        uint256 idAuction; // the id of the auction
    }
    mapping(uint256 => Offer) public offers;

    function initialize() external {}

    // Every time a token is put on sale, an offer is created. An offer can be a direct sale, an auction
    // or a combination of both.
    function createOffer(
        address assetAddress_, // address of the token
        uint256 tokenId_, // tokenId
        bool isDirectSale_, // true if can be bought on a direct sale
        bool isAuction_, // true if can be bought in an auction
        uint256 price_, // price that if paid in a direct sale, transfers the NFT
        uint256 startPrice_, // minimum price on the auction
        uint256 startTime_, // time when the auction will start. Check the format with frontend
        uint256 duration_ // duration in seconds of the auction
    ) public {
        IERC721Upgradeable asset = IERC721Upgradeable(assetAddress_);
        require(asset.ownerOf(tokenId_) == msg.sender, "MNTO: Not the owner");
        require(
            asset.getApproved(tokenId_) == address(this),
            "MNTO: NFT not approved"
        );
        // Could not be used to update an existing offer (#02)
        Offer memory previous = offers[tokenId_];

        require(
            previous.isOnSale == false && previous.isAuction == false,
            "MNTO: An active offer already exists"
        );

        // First create the offer
        Offer memory offer = Offer({
            assetAddress: assetAddress_,
            tokenId: tokenId_,
            creator: payable(msg.sender),
            price: price_,
            isOnSale: isDirectSale_,
            isAuction: isAuction_,
            idAuction: 0
        });

        if (isAuction_) {
            offer.idAuction = createAuction(
                assetAddress_,
                tokenId_,
                startPrice_,
                startTime_,
                duration_
            );
        }
        offers[tokenId_] = offer;
        emit OfferCreated(
            tokenId_,
            msg.sender,
            assetAddress_,
            1,
            price_,
            isDirectSale_
        );
    }

    // returns the auctionId from the offerId
    function getAuctionId(uint256 _tokenId) public view returns (uint256) {
        Offer memory offer = offers[_tokenId];
        return offer.idAuction;
    }

    // this method returns the current date and time of the blockchain. Used also to check the contract is alive
    function ahora() public view returns (uint256) {
        return block.timestamp;
    }

    // Remove an auction from the offer that did not have previous bids. Beware could be a direct sale
    function removeFromAuction(uint256 _tokenId) public {
        Offer memory offer = offers[_tokenId];
        require(msg.sender == offer.creator, "MNTO: You are not the owner");
        Auction memory auction = auctions[offer.idAuction];
        require(auction.bidCount == 0, "MNTO: Bids existing");
        offer.isAuction = false;
        offer.idAuction = 0;
        offers[_tokenId] = offer;
    }

    // remove a direct sale from an offer. Beware that could be an auction for the token
    function removeFromSale(uint256 _tokenId) public {
        Offer memory offer = offers[_tokenId];
        require(msg.sender == offer.creator, "MNTO: You are not the owner");
        offer.isOnSale = false;
        offers[_tokenId] = offer;
    }

    // Changes the default commission. Only the owner of the marketplace can do that. In basic points
    function setCommission(uint256 _commission) public onlyOwner {
        require(_commission <= 1000, "MNTO: Commission too high");
        commission = _commission;
    }

    // called in a direct sale by the customer. Transfer the nft to the customer, the royalties (if any)
    // to the token creator, the commission for the marketplace is keeped on the contract and the remaining
    // funds are transferred to the token owner.
    // is there is an auction open, the last bid amount is sent back to the last bidder
    // After that, the offer is cleared.
    function buy(uint256 tokenId_) external payable nonReentrant {
        address buyer = msg.sender;
        uint256 paidPrice = msg.value;

        Offer memory offer = offers[tokenId_];
        require(offer.isOnSale == true, "MNTO: NFT not in direct sale");
        uint256 price = offer.price;
        require(paidPrice >= price, "MNTO: Price is not enough");

        //if there is a bid and the auction is closed but not claimed, give priority to claim
        require(
            !(offer.isAuction == true &&
                isFinished(offer.idAuction) &&
                auctions[offer.idAuction].bidCount > 0),
            "MNTO: Claim asset is priority"
        );

        emit Claim(tokenId_, buyer);
        ERC721Momento asset = ERC721Momento(offer.assetAddress);
        asset.safeTransferFrom(offer.creator, buyer, tokenId_);

        // now, pay the amount - commission - royalties to the auction creator
        address payable creatorNFT = payable(asset.getCreator(tokenId_));

        uint256 commissionToPay = (paidPrice * commission) / 10000;
        uint256 royaltiesToPay = 0;
        if (creatorNFT != offer.creator) {
            // It is a resale. Transfer royalties
            royaltiesToPay = (paidPrice * asset.getRoyalties(tokenId_)) / 10000;

            (bool success, ) = creatorNFT.call{value: royaltiesToPay}("");
            require(success, "MNTO: Transfer failed");

            emit Royalties(creatorNFT, royaltiesToPay);
        }
        uint256 amountToPay = paidPrice - commissionToPay - royaltiesToPay;

        (bool success2, ) = offer.creator.call{value: amountToPay}("");
        require(success2, "MNTO: Transfer failed");
        emit PaymentToOwner(
            offer.creator,
            amountToPay,
            //     paidPrice,
            commissionToPay,
            royaltiesToPay,
            amountToPay + ((paidPrice * commission) / 10000) // using safemath will trigger an error because of stack size
        );

        // is there is an auction open, we have to give back the last bid amount to the last bidder
        if (offer.isAuction == true) {
            Auction memory auction = auctions[offer.idAuction];
            // #4. Only if there is at least a bid and the bid amount > 0, give it back to last bidder
            if (auction.currentBidAmount != 0 && auction.bidCount > 0) {
                // return funds to the previuos bidder
                (bool success3, ) = auction.currentBidOwner.call{
                    value: auction.currentBidAmount
                }("");
                require(success3, "MNTO: Transfer failed");
                emit ReturnBidFunds(
                    offer.idAuction,
                    auction.currentBidOwner,
                    auction.currentBidAmount
                );
            }
        }

        emit Buy(tokenId_, msg.sender, msg.value);

        accumulatedCommission = accumulatedCommission + commissionToPay;

        offer.isAuction = false;
        offer.isOnSale = false;
        offers[tokenId_] = offer;

        totalSales = totalSales + msg.value;
    }

    // Creates an auction for a token. It is linked to an offer
    function createAuction(
        address _assetAddress, // address of the XSigma721 token
        uint256 _assetId, // id of the NFT
        uint256 _startPrice, // minimum price
        uint256 _startTime, // time when the auction will start. Check with frontend because is unix time in seconds, not millisecs!
        uint256 _duration // duration in seconds of the auction
    ) private returns (uint256) {
        if (_startTime == 0) {
            _startTime = block.timestamp;
        }

        Auction memory auction = Auction({
            creator: payable(msg.sender),
            assetAddress: _assetAddress,
            assetId: _assetId,
            startTime: _startTime,
            duration: _duration,
            currentBidAmount: _startPrice,
            currentBidOwner: payable(address(0)),
            bidCount: 0
        });
        auctions.push(auction);
        uint256 index = auctions.length - 1;

        emit AuctionCreated(index, auction.creator, _assetId, _startPrice);

        return index;
    }

    // At the end of the call, the amount is saved on the marketplace wallet and the previous bid amount is returned to old bidder
    // except in the case of the first bid, as could exists a minimum price set by the creator as first bid.
    function bid(uint256 auctionIndex) public payable nonReentrant {
        Auction storage auction = auctions[auctionIndex];
        require(auction.creator != address(0), "MNTO: Cannot bid");
        require(isActive(auctionIndex), "MNTO: Bid not active");
        require(msg.value > auction.currentBidAmount, "MNTO: Bid too low");
        // we got a better bid. Return funds to the previous best bidder
        // and register the sender as `currentBidOwner`

        // this check is for not transferring back funds on the first bid, as the fist bid is the minimum price set by the auction creator
        // and the bid owner is address(0)
        if (
            auction.currentBidAmount != 0 &&
            auction.currentBidOwner != address(0)
        ) {
            // return funds to the previuos bidder
            (bool success, ) = auction.currentBidOwner.call{
                value: auction.currentBidAmount
            }("");
            require(success, "MNTO: Transfer failed");
            emit ReturnBidFunds(
                auctionIndex,
                auction.currentBidOwner,
                auction.currentBidAmount
            );
        }
        // register new bidder
        auction.currentBidAmount = msg.value;
        auction.currentBidOwner = payable(msg.sender);
        auction.bidCount = auction.bidCount + 1;

        emit AuctionBid(auctionIndex, msg.sender, msg.value);
    }

    function getTotalAuctions() public view returns (uint256) {
        return auctions.length;
    }

    function isActive(uint256 auctionIndex_) public view returns (bool) {
        return getStatus(auctionIndex_) == Status.Active;
    }

    function isFinished(uint256 auctionIndex_) public view returns (bool) {
        return getStatus(auctionIndex_) == Status.Finished;
    }

    // The auctions did not be affected if the current time is 15 seconds wrong
    // So, according to Consensys security advices, it is safe using block.timestamp
    function getStatus(uint256 auctionIndex_) public view returns (Status) {
        Auction storage auction = auctions[auctionIndex_];
        if (block.timestamp < auction.startTime) {
            return Status.Pending;
        } else if (block.timestamp < auction.startTime + auction.duration) {
            return Status.Active;
        } else {
            return Status.Finished;
        }
    }

    // returns the end date of the auction, in unix time using seconds
    function endDate(uint256 auctionIndex_) public view returns (uint256) {
        Auction storage auction = auctions[auctionIndex_];
        return auction.startTime + auction.duration;
    }

    // returns the user with the best bid until now on an auction
    function getCurrentBidOwner(uint256 auctionIndex_)
        public
        view
        returns (address)
    {
        return auctions[auctionIndex_].currentBidOwner;
    }

    // returns the amount in ETH of the best bid until now on an auction
    function getCurrentBidAmount(uint256 auctionIndex_)
        public
        view
        returns (uint256)
    {
        return auctions[auctionIndex_].currentBidAmount;
    }

    // returns the number of bids of an auction (0 by default)
    function getBidCount(uint256 auctionIndex_) public view returns (uint256) {
        return auctions[auctionIndex_].bidCount;
    }

    // returns the winner of an auction once the auction finished
    function getWinner(uint256 auctionIndex_) public view returns (address) {
        require(isFinished(auctionIndex_), "MNTO: Auction not finished yet");
        return auctions[auctionIndex_].currentBidOwner;
    }

    // called when the auction is finished by the user who won the auction
    // transfer the nft to the caller, the royalties (if any) to the nft creator
    // the commission of the marketplace is calculated, and the remaining funds
    // are transferred to the token owner
    // After this, the offer is disabled
    function closeAuction(uint256 auctionIndex_) public {
        //    address winner = getWinner(auctionIndex);
        //    require(winner == msg.sender, "You are not the winner of the auction");
        auctionTransferAsset(auctionIndex_);
    }

    function automaticSetWinner(uint256 auctionIndex_) public onlyOwner {
        auctionTransferAsset(auctionIndex_);
    }

    function auctionTransferAsset(uint256 auctionIndex_) private nonReentrant {
        // require(isFinished(auctionIndex), "The auction is still active");
        address winner = getWinner(auctionIndex_);

        Auction storage auction = auctions[auctionIndex_];

        // the token could be sold in direct sale or the owner cancelled the auction
        Offer memory offer = offers[auction.assetId];
        require(offer.isAuction == true, "MNTO: NFT not in auction");

        if (auction.bidCount > 0) {
            ERC721Momento asset = ERC721Momento(auction.assetAddress);

            // #3, check if the asset owner had removed their approval or the offer creator is not the token owner anymore.
            require(
                asset.getApproved(auction.assetId) == address(this),
                "MNTO: NFT not approved"
            );
            require(
                asset.ownerOf(auction.assetId) == auction.creator,
                "MNTO: Auction creator is not nft owner"
            );

            asset.safeTransferFrom(auction.creator, winner, auction.assetId);

            emit Claim(auctionIndex_, winner);

            // now, pay the amount - commission - royalties to the auction creator
            address payable creatorNFT = payable(
                asset.getCreator(auction.assetId)
            );
            uint256 commissionToPay = (auction.currentBidAmount * commission) /
                10000;
            uint256 royaltiesToPay = 0;
            if (creatorNFT != auction.creator) {
                // It is a resale. Transfer royalties
                royaltiesToPay =
                    (auction.currentBidAmount *
                        asset.getRoyalties(auction.assetId)) /
                    10000;
                creatorNFT.transfer(royaltiesToPay);
                emit Royalties(creatorNFT, royaltiesToPay);
            }
            uint256 amountToPay = auction.currentBidAmount -
                commissionToPay -
                royaltiesToPay;

            (bool success, ) = auction.creator.call{value: amountToPay}("");
            require(success, "MNTO: Transfer failed");
            emit PaymentToOwner(
                auction.creator,
                amountToPay,
                //  auction.currentBidAmount,
                commissionToPay,
                royaltiesToPay,
                amountToPay + commissionToPay + royaltiesToPay
            );

            accumulatedCommission = accumulatedCommission + commissionToPay;
            totalSales = totalSales + auction.currentBidAmount;
        }

        offer.isAuction = false;
        offer.isOnSale = false;
        offers[auction.assetId] = offer;
    }

    //Call this method
    function cancelAuctionOfToken(uint256 tokenId_)
        external
        onlyOwner
        nonReentrant
    {
        Offer memory offer = offers[tokenId_];
        // is there is an auction open, we have to give back the last bid amount to the last bidder
        require(offer.isAuction, "MNTO: Offer is not an auction");
        Auction memory auction = auctions[offer.idAuction];

        if (auction.bidCount > 0) returnLastBid(offer, auction);

        offer.isAuction = false;
        offers[tokenId_] = offer;
    }

    function returnLastBid(Offer memory offer, Auction memory auction)
        internal
    {
        // is there is an auction open, we have to give back the last bid amount to the last bidder
        require(offer.isAuction, "MNTO: Offer is not an auction");
        // #4. Only if there is at least a bid and the bid amount > 0, give it back to last bidder
        require(
            auction.currentBidAmount != 0 &&
                auction.bidCount > 0 &&
                auction.currentBidOwner != address(0),
            "MNTO: No bids yet"
        );
        require(
            offer.creator != auction.currentBidOwner,
            "MNTO: Offer owner cannot retrieve own funds"
        );
        // return funds to the previuos bidder
        (bool success3, ) = auction.currentBidOwner.call{
            value: auction.currentBidAmount
        }("");
        require(success3, "MNTO: Transfer failed");
        emit ReturnBidFunds(
            offer.idAuction,
            auction.currentBidOwner,
            auction.currentBidAmount
        );
    }

    // This method is only callable by the marketplace owner and transfer funds from
    // the marketplace to the caller.
    // It us used to move the funds from the marketplace to the investors
    function extractBalance() public nonReentrant onlyOwner {
        address payable me = payable(msg.sender);
        (bool success, ) = me.call{value: accumulatedCommission}("");
        require(success, "MNTO: Transfer failed");
        accumulatedCommission = 0;
    }
}
