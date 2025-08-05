// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title TruePassMarketplace
 * @dev Marketplace contract for secondary ticket sales
 */


contract TruePassMarketplace is ReentrancyGuard, Pausable, Ownable {
    using Counters for Counters.Counter;
    
    TruePassTicketNFT public immutable ticketContract;
    
    struct Listing {
        uint256 listingId;
        uint256 tokenId;
        address seller;
        uint256 price;
        bool isActive;
        uint256 listedAt;
    }
    
    Counters.Counter private _listingIds;
    mapping(uint256 => Listing) public listings; // listingId => Listing
    mapping(uint256 => uint256) public tokenToListing; // tokenId => listingId
    mapping(address => uint256[]) public sellerListings; // seller => listingIds
    
    uint256 public constant MARKETPLACE_FEE = 250; // 2.5%
    uint256 public constant PERCENTAGE_BASE = 10000;
    
    address public marketplaceTreasury;
    
    event TicketListed(uint256 indexed listingId, uint256 indexed tokenId, address indexed seller, uint256 price);
    event TicketSold(uint256 indexed listingId, uint256 indexed tokenId, address indexed buyer, uint256 price);
    event ListingCancelled(uint256 indexed listingId, uint256 indexed tokenId, address indexed seller);
    event PriceUpdated(uint256 indexed listingId, uint256 oldPrice, uint256 newPrice);
    
    modifier onlyTokenOwner(uint256 tokenId) {
        require(ticketContract.ownerOf(tokenId) == msg.sender, "Not token owner");
        _;
    }
    
    modifier listingExists(uint256 listingId) {
        require(listings[listingId].seller != address(0), "Listing does not exist");
        _;
    }
    
    modifier listingActive(uint256 listingId) {
        require(listings[listingId].isActive, "Listing not active");
        _;
    }
    
    constructor(address _ticketContract, address _marketplaceTreasury) {
        require(_ticketContract != address(0), "Invalid ticket contract");
        require(_marketplaceTreasury != address(0), "Invalid treasury");
        
        ticketContract = TruePassTicketNFT(_ticketContract);
        marketplaceTreasury = _marketplaceTreasury;
    }
    
    /**
     * @dev List a ticket for sale
     */
    function listTicket(uint256 _tokenId, uint256 _price) external onlyTokenOwner(_tokenId) whenNotPaused nonReentrant {
        require(_price > 0, "Price must be > 0");
        require(tokenToListing[_tokenId] == 0, "Ticket already listed");
        
        // Get ticket and event details
        TruePassTicketNFT.Ticket memory ticket = ticketContract.getTicket(_tokenId);
        TruePassTicketNFT.Event memory eventData = ticketContract.getEvent(ticket.eventId);
        
        require(eventData.isActive && !eventData.eventCompleted, "Event not active for resale");
        require(block.timestamp < eventData.eventDate, "Event has started");
        require(!ticket.isScanned, "Cannot list scanned ticket");
        require(_price <= eventData.maxResalePrice, "Price exceeds maximum");
        require(_price >= eventData.ticketPrice / 2, "Price too low");
        
        _listingIds.increment();
        uint256 listingId = _listingIds.current();
        
        listings[listingId] = Listing({
            listingId: listingId,
            tokenId: _tokenId,
            seller: msg.sender,
            price: _price,
            isActive: true,
            listedAt: block.timestamp
        });
        
        tokenToListing[_tokenId] = listingId;
        sellerListings[msg.sender].push(listingId);
        
        // Transfer ticket to marketplace for escrow
        ticketContract.transferFrom(msg.sender, address(this), _tokenId);
        
        emit TicketListed(listingId, _tokenId, msg.sender, _price);
    }
    
    /**
     * @dev Buy a listed ticket
     */
    function buyTicket(uint256 _listingId) external payable nonReentrant whenNotPaused listingExists(_listingId) listingActive(_listingId) {
        Listing storage listing = listings[_listingId];
        require(msg.sender != listing.seller, "Cannot buy own ticket");
        require(msg.value == listing.price, "Incorrect payment");
        
        // Get ticket and event details for validation
        TruePassTicketNFT.Ticket memory ticket = ticketContract.getTicket(listing.tokenId);
        TruePassTicketNFT.Event memory eventData = ticketContract.getEvent(ticket.eventId);
        
        require(eventData.isActive && !eventData.eventCompleted, "Event not active");
        require(block.timestamp < eventData.eventDate, "Event has started");
        require(!ticket.isScanned, "Cannot buy scanned ticket");
        
        // Calculate fees
        uint256 marketplaceFeeAmount = (msg.value * MARKETPLACE_FEE) / PERCENTAGE_BASE;
        uint256 royaltyAmount = (msg.value * eventData.royaltyPercentage) / PERCENTAGE_BASE;
        uint256 sellerAmount = msg.value - marketplaceFeeAmount - royaltyAmount;
        
        // Deactivate listing
        listing.isActive = false;
        delete tokenToListing[listing.tokenId];
        
        // Transfer ticket to buyer
        ticketContract.transferFrom(address(this), msg.sender, listing.tokenId);
        
        // Distribute payments
        payable(marketplaceTreasury).transfer(marketplaceFeeAmount);
        payable(eventData.creator).transfer(royaltyAmount);
        payable(listing.seller).transfer(sellerAmount);
        
        emit TicketSold(_listingId, listing.tokenId, msg.sender, listing.price);
    }
    
    /**
     * @dev Cancel a listing
     */
    function cancelListing(uint256 _listingId) external nonReentrant listingExists(_listingId) listingActive(_listingId) {
        Listing storage listing = listings[_listingId];
        require(msg.sender == listing.seller, "Not the seller");
        
        listing.isActive = false;
        delete tokenToListing[listing.tokenId];
        
        // Return ticket to seller
        ticketContract.transferFrom(address(this), listing.seller, listing.tokenId);
        
        emit ListingCancelled(_listingId, listing.tokenId, listing.seller);
    }
    
    /**
     * @dev Update listing price
     */
    function updatePrice(uint256 _listingId, uint256 _newPrice) external listingExists(_listingId) listingActive(_listingId) {
        Listing storage listing = listings[_listingId];
        require(msg.sender == listing.seller, "Not the seller");
        require(_newPrice > 0, "Price must be > 0");
        
        // Validate new price against event constraints
        TruePassTicketNFT.Ticket memory ticket = ticketContract.getTicket(listing.tokenId);
        TruePassTicketNFT.Event memory eventData = ticketContract.getEvent(ticket.eventId);
        
        require(_newPrice <= eventData.maxResalePrice, "Price exceeds maximum");
        require(_newPrice >= eventData.ticketPrice / 2, "Price too low");
        
        uint256 oldPrice = listing.price;
        listing.price = _newPrice;
        
        emit PriceUpdated(_listingId, oldPrice, _newPrice);
    }
    
    /**
     * @dev Get active listings for an event
     */
    function getEventListings(uint256 _eventId) external view returns (uint256[] memory) {
        uint256[] memory eventTickets = ticketContract.getEventTickets(_eventId);
        uint256[] memory activeListings = new uint256[](eventTickets.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < eventTickets.length; i++) {
            uint256 listingId = tokenToListing[eventTickets[i]];
            if (listingId != 0 && listings[listingId].isActive) {
                activeListings[count] = listingId;
                count++;
            }
        }
        
        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeListings[i];
        }
        
        return result;
    }
    
    /**
     * @dev Get seller's active listings
     */
    function getSellerActiveListings(address _seller) external view returns (uint256[] memory) {
        uint256[] memory sellerListing = sellerListings[_seller];
        uint256[] memory activeListings = new uint256[](sellerListing.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < sellerListing.length; i++) {
            if (listings[sellerListing[i]].isActive) {
                activeListings[count] = sellerListing[i];
                count++;
            }
        }
        
        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeListings[i];
        }
        
        return result;
    }
    
    /**
     * @dev Admin functions
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
}
}