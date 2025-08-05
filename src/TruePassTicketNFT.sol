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
 * @title TruePassTicketNFT
 * @dev Main NFT contract for TruePass tickets with Camp Network IP integration
 */
contract TruePassTicketNFT is ERC721, ERC721URIStorage, ERC721Enumerable, Ownable, ReentrancyGuard, Pausable {
    using Counters for Counters.Counter;
    using Strings for uint256;

    Counters.Counter private _tokenIds;
    
    // Event structure
    struct Event {
        uint256 eventId;
        address creator;
        string name;
        string description;
        string location;
        uint256 eventDate;
        uint256 ticketPrice;
        uint256 maxSupply;
        uint256 currentSupply;
        uint256 maxResalePrice; // Maximum resale price (percentage of original price)
        uint256 royaltyPercentage; // Creator royalty on resales
        bool isActive;
        bool eventCompleted;
        string ipfsMetadataHash; // For Camp Network IP registration
    }
    
    // Ticket structure
    struct Ticket {
        uint256 tokenId;
        uint256 eventId;
        address owner;
        uint256 purchasePrice;
        bool isScanned;
        bool isTransformed; // Post-event transformation status
        uint256 purchaseTimestamp;
        string qrCodeHash;
    }
    
    // Mappings
    mapping(uint256 => Event) public events;
    mapping(uint256 => Ticket) public tickets;
    mapping(uint256 => uint256) public tokenToEvent; // tokenId => eventId
    mapping(uint256 => mapping(address => uint256)) public eventTicketCounts; // eventId => owner => count
    mapping(address => uint256[]) public creatorEvents; // creator => eventIds
    mapping(uint256 => uint256[]) public eventTickets; // eventId => tokenIds
    mapping(bytes32 => bool) public usedQRCodes; // Prevent QR code reuse
    
    // Counters
    Counters.Counter private _eventIds;
    
    // Constants
    uint256 public constant PERCENTAGE_BASE = 10000; // 100.00%
    uint256 public constant MAX_ROYALTY = 1000; // 10%
    uint256 public constant PLATFORM_FEE = 250; // 2.5%
    
    // Platform addresses
    address public platformTreasury;
    address public emergencyAdmin;
    
    // Events
    event EventCreated(uint256 indexed eventId, address indexed creator, string name, uint256 ticketPrice, uint256 maxSupply);
    event TicketPurchased(uint256 indexed tokenId, uint256 indexed eventId, address indexed buyer, uint256 price);
    event TicketScanned(uint256 indexed tokenId, uint256 indexed eventId, address indexed scanner);
    event TicketTransformed(uint256 indexed tokenId, uint256 indexed eventId, string newTokenURI);
    event TicketResold(uint256 indexed tokenId, address indexed from, address indexed to, uint256 price);
    event EventCompleted(uint256 indexed eventId, address indexed creator);
    event RoyaltyPaid(uint256 indexed eventId, address indexed creator, uint256 amount);
    
    // Modifiers
    modifier onlyEventCreator(uint256 eventId) {
        require(events[eventId].creator == msg.sender, "Not event creator");
        _;
    }
    
    modifier onlyTokenOwner(uint256 tokenId) {
        require(ownerOf(tokenId) == msg.sender, "Not token owner");
        _;
    }
    
    modifier eventExists(uint256 eventId) {
        require(events[eventId].creator != address(0), "Event does not exist");
        _;
    }
    
    modifier eventActive(uint256 eventId) {
        require(events[eventId].isActive, "Event not active");
        require(!events[eventId].eventCompleted, "Event completed");
        _;
    }
    
    constructor(
        address _platformTreasury,
        address _emergencyAdmin
    ) ERC721("TruePass Tickets", "TPASS") {
        require(_platformTreasury != address(0), "Invalid platform treasury");
        require(_emergencyAdmin != address(0), "Invalid emergency admin");
        
        platformTreasury = _platformTreasury;
        emergencyAdmin = _emergencyAdmin;
    }
    
    /**
     * @dev Create a new event
     */
    function createEvent(
        string memory _name,
        string memory _description,
        string memory _location,
        uint256 _eventDate,
        uint256 _ticketPrice,
        uint256 _maxSupply,
        uint256 _maxResalePercentage, // e.g., 11000 for 110%
        uint256 _royaltyPercentage, // e.g., 500 for 5%
        string memory _ipfsMetadataHash
    ) external whenNotPaused returns (uint256) {
        require(bytes(_name).length > 0, "Name required");
        require(bytes(_location).length > 0, "Location required");
        require(_eventDate > block.timestamp, "Event date must be in future");
        require(_ticketPrice > 0, "Ticket price must be > 0");
        require(_maxSupply > 0 && _maxSupply <= 50000, "Invalid max supply");
        require(_maxResalePercentage >= PERCENTAGE_BASE && _maxResalePercentage <= 50000, "Invalid resale percentage");
        require(_royaltyPercentage <= MAX_ROYALTY, "Royalty too high");
        require(bytes(_ipfsMetadataHash).length > 0, "IPFS hash required");
        
        _eventIds.increment();
        uint256 eventId = _eventIds.current();
        
        events[eventId] = Event({
            eventId: eventId,
            creator: msg.sender,
            name: _name,
            description: _description,
            location: _location,
            eventDate: _eventDate,
            ticketPrice: _ticketPrice,
            maxSupply: _maxSupply,
            currentSupply: 0,
            maxResalePrice: (_ticketPrice * _maxResalePercentage) / PERCENTAGE_BASE,
            royaltyPercentage: _royaltyPercentage,
            isActive: true,
            eventCompleted: false,
            ipfsMetadataHash: _ipfsMetadataHash
        });
        
        creatorEvents[msg.sender].push(eventId);
        
        emit EventCreated(eventId, msg.sender, _name, _ticketPrice, _maxSupply);
        return eventId;
    }
    
    /**
     * @dev Purchase tickets for an event
     */
    function purchaseTickets(
        uint256 _eventId,
        uint256 _quantity,
        string[] memory _qrCodeHashes
    ) external payable nonReentrant whenNotPaused eventExists(_eventId) eventActive(_eventId) {
        Event storage eventData = events[_eventId];
        
        require(_quantity > 0 && _quantity <= 10, "Invalid quantity");
        require(_qrCodeHashes.length == _quantity, "QR codes mismatch quantity");
        require(eventData.currentSupply + _quantity <= eventData.maxSupply, "Exceeds max supply");
        require(msg.value == eventData.ticketPrice * _quantity, "Incorrect payment");
        require(block.timestamp < eventData.eventDate, "Event has started");
        
        // Validate QR codes are unique
        for (uint256 i = 0; i < _qrCodeHashes.length; i++) {
            bytes32 qrHash = keccak256(abi.encodePacked(_qrCodeHashes[i]));
            require(!usedQRCodes[qrHash], "QR code already used");
            usedQRCodes[qrHash] = true;
        }
        
        // Calculate fees
        uint256 platformFeeAmount = (msg.value * PLATFORM_FEE) / PERCENTAGE_BASE;
        uint256 creatorAmount = msg.value - platformFeeAmount;
        
        // Mint tickets
        for (uint256 i = 0; i < _quantity; i++) {
            _tokenIds.increment();
            uint256 tokenId = _tokenIds.current();
            
            _safeMint(msg.sender, tokenId);
            
            // Create ticket record
            tickets[tokenId] = Ticket({
                tokenId: tokenId,
                eventId: _eventId,
                owner: msg.sender,
                purchasePrice: eventData.ticketPrice,
                isScanned: false,
                isTransformed: false,
                purchaseTimestamp: block.timestamp,
                qrCodeHash: _qrCodeHashes[i]
            });
            
            tokenToEvent[tokenId] = _eventId;
            eventTickets[_eventId].push(tokenId);
            
            // Set token URI
            string memory tokenURI = string(abi.encodePacked(
                "https://ipfs.io/ipfs/",
                eventData.ipfsMetadataHash,
                "/",
                tokenId.toString()
            ));
            _setTokenURI(tokenId, tokenURI);
            
            emit TicketPurchased(tokenId, _eventId, msg.sender, eventData.ticketPrice);
        }
        
        // Update counters
        eventData.currentSupply += _quantity;
        eventTicketCounts[_eventId][msg.sender] += _quantity;
        
        // Transfer payments
        payable(platformTreasury).transfer(platformFeeAmount);
        payable(eventData.creator).transfer(creatorAmount);
    }
    
    /**
     * @dev Scan a ticket at the event
     */
    function scanTicket(uint256 _tokenId) external onlyEventCreator(tokenToEvent[_tokenId]) {
        require(_exists(_tokenId), "Token does not exist");
        
        Ticket storage ticket = tickets[_tokenId];
        Event storage eventData = events[ticket.eventId];
        
        require(!ticket.isScanned, "Ticket already scanned");
        require(block.timestamp >= eventData.eventDate, "Event not started");
        require(block.timestamp <= eventData.eventDate + 24 hours, "Scanning period ended");
        
        ticket.isScanned = true;
        
        emit TicketScanned(_tokenId, ticket.eventId, msg.sender);
    }
    
    /**
     * @dev Complete an event (only creator can call after event date)
     */
    function completeEvent(uint256 _eventId) external onlyEventCreator(_eventId) eventExists(_eventId) {
        Event storage eventData = events[_eventId];
        require(!eventData.eventCompleted, "Event already completed");
        require(block.timestamp > eventData.eventDate + 24 hours, "Event still ongoing");
        
        eventData.eventCompleted = true;
        emit EventCompleted(_eventId, msg.sender);
    }
    
    /**
     * @dev Transform scanned tickets into collectible art after event
     */
    function transformTicket(
        uint256 _tokenId,
        string memory _newTokenURI
    ) external onlyEventCreator(tokenToEvent[_tokenId]) {
        require(_exists(_tokenId), "Token does not exist");
        
        Ticket storage ticket = tickets[_tokenId];
        Event storage eventData = events[ticket.eventId];
        
        require(eventData.eventCompleted, "Event not completed");
        require(ticket.isScanned, "Ticket was not scanned");
        require(!ticket.isTransformed, "Ticket already transformed");
        require(bytes(_newTokenURI).length > 0, "New URI required");
        
        ticket.isTransformed = true;
        _setTokenURI(_tokenId, _newTokenURI);
        
        emit TicketTransformed(_tokenId, ticket.eventId, _newTokenURI);
    }
    
    /**
     * @dev Resell ticket (with price restrictions)
     */
    function resellTicket(
        uint256 _tokenId,
        uint256 _price
    ) external onlyTokenOwner(_tokenId) whenNotPaused {
        require(_exists(_tokenId), "Token does not exist");
        
        Ticket storage ticket = tickets[_tokenId];
        Event storage eventData = events[ticket.eventId];
        
        require(eventData.isActive && !eventData.eventCompleted, "Event not active for resale");
        require(block.timestamp < eventData.eventDate, "Event has started");
        require(!ticket.isScanned, "Cannot resell scanned ticket");
        require(_price <= eventData.maxResalePrice, "Price exceeds maximum");
        require(_price >= eventData.ticketPrice / 2, "Price too low");
        
        // Approve this contract to handle the transfer
        approve(address(this), _tokenId);
    }
    
    /**
     * @dev Buy a resold ticket
     */
    function buyResoldTicket(uint256 _tokenId) external payable nonReentrant whenNotPaused {
        require(_exists(_tokenId), "Token does not exist");
        
        address seller = ownerOf(_tokenId);
        require(seller != msg.sender, "Cannot buy own ticket");
        require(getApproved(_tokenId) == address(this), "Ticket not approved for sale");
        
        Ticket storage ticket = tickets[_tokenId];
        Event storage eventData = events[ticket.eventId];
        
        require(eventData.isActive && !eventData.eventCompleted, "Event not active");
        require(block.timestamp < eventData.eventDate, "Event has started");
        require(!ticket.isScanned, "Cannot buy scanned ticket");
        require(msg.value <= eventData.maxResalePrice, "Payment exceeds max price");
        require(msg.value >= eventData.ticketPrice / 2, "Payment too low");
        
        // Calculate distribution
        uint256 platformFeeAmount = (msg.value * PLATFORM_FEE) / PERCENTAGE_BASE;
        uint256 royaltyAmount = (msg.value * eventData.royaltyPercentage) / PERCENTAGE_BASE;
        uint256 sellerAmount = msg.value - platformFeeAmount - royaltyAmount;
        
        // Transfer ticket
        _transfer(seller, msg.sender, _tokenId);
        
        // Update ticket record
        ticket.owner = msg.sender;
        eventTicketCounts[ticket.eventId][seller]--;
        eventTicketCounts[ticket.eventId][msg.sender]++;
        
        // Distribute payments
        payable(platformTreasury).transfer(platformFeeAmount);
        payable(eventData.creator).transfer(royaltyAmount);
        payable(seller).transfer(sellerAmount);
        
        emit TicketResold(_tokenId, seller, msg.sender, msg.value);
        if (royaltyAmount > 0) {
            emit RoyaltyPaid(ticket.eventId, eventData.creator, royaltyAmount);
        }
    }
    
    /**
     * @dev Get event details
     */
    function getEvent(uint256 _eventId) external view returns (Event memory) {
        require(events[_eventId].creator != address(0), "Event does not exist");
        return events[_eventId];
    }
    
    /**
     * @dev Get ticket details
     */
    function getTicket(uint256 _tokenId) external view returns (Ticket memory) {
        require(_exists(_tokenId), "Token does not exist");
        return tickets[_tokenId];
    }
    
    /**
     * @dev Get events created by an address
     */
    function getCreatorEvents(address _creator) external view returns (uint256[] memory) {
        return creatorEvents[_creator];
    }
    
    /**
     * @dev Get tickets for an event
     */
    function getEventTickets(uint256 _eventId) external view returns (uint256[] memory) {
        return eventTickets[_eventId];
    }
    
    /**
     * @dev Get tickets owned by address for specific event
     */
    function getOwnerTicketsForEvent(address _owner, uint256 _eventId) external view returns (uint256[] memory) {
        uint256[] memory allEventTickets = eventTickets[_eventId];
        uint256[] memory ownerTickets = new uint256[](eventTicketCounts[_eventId][_owner]);
        uint256 count = 0;
        
        for (uint256 i = 0; i < allEventTickets.length; i++) {
            if (ownerOf(allEventTickets[i]) == _owner) {
                ownerTickets[count] = allEventTickets[i];
                count++;
            }
        }
        
        return ownerTickets;
    }
    
    /**
     * @dev Get current event count
     */
    function getCurrentEventId() external view returns (uint256) {
        return _eventIds.current();
    }
    
    /**
     * @dev Get current token count
     */
    function getCurrentTokenId() external view returns (uint256) {
        return _tokenIds.current();
    }
    
    /**
     * @dev Emergency functions
     */
    function pause() external {
        require(msg.sender == owner() || msg.sender == emergencyAdmin, "Not authorized");
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function updateMarketplaceTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid address");
        marketplaceTreasury = _newTreasury;
    }
    
    /**
     * @dev Emergency cancel listing (admin only)
     */
    function emergencyCancelListing(uint256 _listingId) external onlyOwner listingExists(_listingId) {
        Listing storage listing = listings[_listingId];
        if (listing.isActive) {
            listing.isActive = false;
            delete tokenToListing[listing.tokenId];
            
            // Return ticket to seller
            ticketContract.transferFrom(address(this), listing.seller, listing.tokenId);
            
            emit ListingCancelled(_listingId, listing.tokenId, listing.seller);
        }
    }
}