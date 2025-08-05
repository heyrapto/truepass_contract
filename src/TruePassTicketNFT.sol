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

/**
 * @title TruePassFactory
 * @dev Factory contract for deploying TruePass instances
 */
contract TruePassFactory is Ownable {
    using Counters for Counters.Counter;
    
    Counters.Counter private _deploymentIds;
    
    struct Deployment {
        uint256 deploymentId;
        address ticketContract;
        address marketplaceContract;
        address deployer;
        uint256 deployedAt;
        string name;
        bool isActive;
    }
    
    mapping(uint256 => Deployment) public deployments;
    mapping(address => uint256[]) public deployerContracts;
    mapping(address => bool) public authorizedDeployers;
    
    address public platformTreasury;
    address public emergencyAdmin;
    uint256 public deploymentFee = 0.01 ether;
    
    event ContractsDeployed(
        uint256 indexed deploymentId,
        address indexed deployer,
        address ticketContract,
        address marketplaceContract,
        string name
    );
    
    event DeploymentDeactivated(uint256 indexed deploymentId, address indexed admin);
    
    constructor(address _platformTreasury, address _emergencyAdmin) {
        require(_platformTreasury != address(0), "Invalid platform treasury");
        require(_emergencyAdmin != address(0), "Invalid emergency admin");
        
        platformTreasury = _platformTreasury;
        emergencyAdmin = _emergencyAdmin;
        authorizedDeployers[msg.sender] = true;
    }
    
    /**
     * @dev Deploy new TruePass contracts
     */
    function deployTruePass(string memory _name) external payable returns (uint256, address, address) {
        require(bytes(_name).length > 0, "Name required");
        require(msg.value >= deploymentFee || authorizedDeployers[msg.sender], "Insufficient deployment fee");
        
        _deploymentIds.increment();
        uint256 deploymentId = _deploymentIds.current();
        
        // Deploy ticket contract
        TruePassTicketNFT ticketContract = new TruePassTicketNFT(
            platformTreasury,
            emergencyAdmin
        );
        
        // Deploy marketplace contract
        TruePassMarketplace marketplaceContract = new TruePassMarketplace(
            address(ticketContract),
            platformTreasury
        );
        
        // Store deployment info
        deployments[deploymentId] = Deployment({
            deploymentId: deploymentId,
            ticketContract: address(ticketContract),
            marketplaceContract: address(marketplaceContract),
            deployer: msg.sender,
            deployedAt: block.timestamp,
            name: _name,
            isActive: true
        });
        
        deployerContracts[msg.sender].push(deploymentId);
        
        // Transfer deployment fee to treasury
        if (msg.value > 0) {
            payable(platformTreasury).transfer(msg.value);
        }
        
        emit ContractsDeployed(
            deploymentId,
            msg.sender,
            address(ticketContract),
            address(marketplaceContract),
            _name
        );
        
        return (deploymentId, address(ticketContract), address(marketplaceContract));
    }
    
    /**
     * @dev Get deployment details
     */
    function getDeployment(uint256 _deploymentId) external view returns (Deployment memory) {
        require(deployments[_deploymentId].deployer != address(0), "Deployment does not exist");
        return deployments[_deploymentId];
    }
    
    /**
     * @dev Get deployer's contracts
     */
    function getDeployerContracts(address _deployer) external view returns (uint256[] memory) {
        return deployerContracts[_deployer];
    }
    
    /**
     * @dev Admin functions
     */
    function setDeploymentFee(uint256 _newFee) external onlyOwner {
        deploymentFee = _newFee;
    }
    
    function setAuthorizedDeployer(address _deployer, bool _authorized) external onlyOwner {
        authorizedDeployers[_deployer] = _authorized;
    }
    
    function updatePlatformTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid address");
        platformTreasury = _newTreasury;
    }
    
    function updateEmergencyAdmin(address _newAdmin) external onlyOwner {
        require(_newAdmin != address(0), "Invalid address");
        emergencyAdmin = _newAdmin;
    }
    
    function deactivateDeployment(uint256 _deploymentId) external {
        require(msg.sender == owner() || msg.sender == emergencyAdmin, "Not authorized");
        require(deployments[_deploymentId].deployer != address(0), "Deployment does not exist");
        
        deployments[_deploymentId].isActive = false;
        emit DeploymentDeactivated(_deploymentId, msg.sender);
    }
}

/**
 * @title TruePassGovernance
 * @dev Governance contract for platform parameters and upgrades
 */
contract TruePassGovernance is Ownable {
    using Counters for Counters.Counter;
    
    Counters.Counter private _proposalIds;
    
    enum ProposalType {
        PARAMETER_CHANGE,
        EMERGENCY_ACTION,
        TREASURY_WITHDRAWAL,
        CONTRACT_UPGRADE
    }
    
    enum ProposalStatus {
        PENDING,
        ACTIVE,
        SUCCEEDED,
        DEFEATED,
        EXECUTED,
        CANCELLED
    }
    
    struct Proposal {
        uint256 proposalId;
        address proposer;
        ProposalType proposalType;
        string title;
        string description;
        uint256 createdAt;
        uint256 votingStart;
        uint256 votingEnd;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        ProposalStatus status;
        bytes executionData;
        address target;
        bool executed;
    }
    
    struct Vote {
        bool hasVoted;
        uint8 support; // 0 = against, 1 = for, 2 = abstain
        uint256 votes;
        string reason;
    }
    
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Vote)) public proposalVotes;
    mapping(address => bool) public authorizedProposers;
    mapping(address => uint256) public votingPower;
    
    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant VOTING_DELAY = 1 days;
    uint256 public quorumRequired = 1000; // Minimum votes needed
    uint256 public proposalThreshold = 100; // Minimum voting power to propose
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType proposalType,
        string title,
        uint256 votingStart,
        uint256 votingEnd
    );
    
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8 support,
        uint256 votes,
        string reason
    );
    
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    
    modifier onlyAuthorizedProposer() {
        require(authorizedProposers[msg.sender] || msg.sender == owner(), "Not authorized proposer");
        require(votingPower[msg.sender] >= proposalThreshold, "Insufficient voting power");
        _;
    }
    
    constructor() {
        authorizedProposers[msg.sender] = true;
        votingPower[msg.sender] = 10000; // Initial voting power for deployer
    }
    
    /**
     * @dev Create a new proposal
     */
    function createProposal(
        ProposalType _proposalType,
        string memory _title,
        string memory _description,
        address _target,
        bytes memory _executionData
    ) external onlyAuthorizedProposer returns (uint256) {
        require(bytes(_title).length > 0, "Title required");
        require(bytes(_description).length > 0, "Description required");
        
        _proposalIds.increment();
        uint256 proposalId = _proposalIds.current();
        
        uint256 votingStart = block.timestamp + VOTING_DELAY;
        uint256 votingEnd = votingStart + VOTING_PERIOD;
        
        proposals[proposalId] = Proposal({
            proposalId: proposalId,
            proposer: msg.sender,
            proposalType: _proposalType,
            title: _title,
            description: _description,
            createdAt: block.timestamp,
            votingStart: votingStart,
            votingEnd: votingEnd,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            status: ProposalStatus.PENDING,
            executionData: _executionData,
            target: _target,
            executed: false
        });
        
        emit ProposalCreated(proposalId, msg.sender, _proposalType, _title, votingStart, votingEnd);
        return proposalId;
    }
    
    /**
     * @dev Cast a vote on a proposal
     */
    function castVote(
        uint256 _proposalId,
        uint8 _support,
        string memory _reason
    ) external {
        require(proposals[_proposalId].proposer != address(0), "Proposal does not exist");
        require(_support <= 2, "Invalid support value");
        require(votingPower[msg.sender] > 0, "No voting power");
        
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.votingStart, "Voting not started");
        require(block.timestamp <= proposal.votingEnd, "Voting ended");
        require(proposal.status == ProposalStatus.PENDING || proposal.status == ProposalStatus.ACTIVE, "Invalid proposal status");
        
        Vote storage vote = proposalVotes[_proposalId][msg.sender];
        require(!vote.hasVoted, "Already voted");
        
        uint256 votes = votingPower[msg.sender];
        
        vote.hasVoted = true;
        vote.support = _support;
        vote.votes = votes;
        vote.reason = _reason;
        
        if (_support == 0) {
            proposal.againstVotes += votes;
        } else if (_support == 1) {
            proposal.forVotes += votes;
        } else {
            proposal.abstainVotes += votes;
        }
        
        // Update proposal status
        if (proposal.status == ProposalStatus.PENDING) {
            proposal.status = ProposalStatus.ACTIVE;
        }
        
        emit VoteCast(_proposalId, msg.sender, _support, votes, _reason);
    }
    
    /**
     * @dev Execute a successful proposal
     */
    function executeProposal(uint256 _proposalId) external {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.proposer != address(0), "Proposal does not exist");
        require(block.timestamp > proposal.votingEnd, "Voting not ended");
        require(!proposal.executed, "Already executed");
        
        // Check if proposal succeeded
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        require(totalVotes >= quorumRequired, "Quorum not reached");
        require(proposal.forVotes > proposal.againstVotes, "Proposal defeated");
        
        proposal.executed = true;
        proposal.status = ProposalStatus.EXECUTED;
        
        // Execute the proposal
        if (proposal.target != address(0) && proposal.executionData.length > 0) {
            (bool success, ) = proposal.target.call(proposal.executionData);
            require(success, "Execution failed");
        }
        
        emit ProposalExecuted(_proposalId, msg.sender);
    }
    
    /**
     * @dev Cancel a proposal (only proposer or owner)
     */
    function cancelProposal(uint256 _proposalId) external {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.proposer != address(0), "Proposal does not exist");
        require(msg.sender == proposal.proposer || msg.sender == owner(), "Not authorized");
        require(proposal.status != ProposalStatus.EXECUTED, "Cannot cancel executed proposal");
        
        proposal.status = ProposalStatus.CANCELLED;
        emit ProposalCancelled(_proposalId, msg.sender);
    }
    
    /**
     * @dev Get proposal details
     */
    function getProposal(uint256 _proposalId) external view returns (Proposal memory) {
        require(proposals[_proposalId].proposer != address(0), "Proposal does not exist");
        return proposals[_proposalId];
    }
    
    /**
     * @dev Get vote details
     */
    function getVote(uint256 _proposalId, address _voter) external view returns (Vote memory) {
        return proposalVotes[_proposalId][_voter];
    }
    
    /**
     * @dev Admin functions
     */
    function setVotingPower(address _account, uint256 _power) external onlyOwner {
        votingPower[_account] = _power;
    }
    
    function setAuthorizedProposer(address _proposer, bool _authorized) external onlyOwner {
        authorizedProposers[_proposer] = _authorized;
    }
    
    function setQuorumRequired(uint256 _quorum) external onlyOwner {
        quorumRequired = _quorum;
    }
    
    function setProposalThreshold(uint256 _threshold) external onlyOwner {
        proposalThreshold = _threshold;
    }
}

/**
 * @title TruePassAnalytics
 * @dev Analytics contract for tracking platform metrics
 */
contract TruePassAnalytics is Ownable {
    struct EventMetrics {
        uint256 eventId;
        uint256 ticketsSold;
        uint256 totalRevenue;
        uint256 averagePrice;
        uint256 resaleCount;
        uint256 resaleRevenue;
        uint256 attendanceCount;
        uint256 transformedTickets;
    }
    
    struct PlatformMetrics {
        uint256 totalEvents;
        uint256 totalTicketsSold;
        uint256 totalRevenue;
        uint256 totalResaleRevenue;
        uint256 totalAttendance;
        uint256 activeEvents;
        uint256 completedEvents;
    }
    
    mapping(uint256 => EventMetrics) public eventMetrics;
    mapping(address => uint256) public creatorRevenue;
    mapping(address => uint256) public creatorEventCount;
    
    PlatformMetrics public platformMetrics;
    
    address public ticketContract;
    address public marketplaceContract;
    
    event MetricsUpdated(uint256 indexed eventId, string metricType, uint256 value);
    
    modifier onlyAuthorizedContracts() {
        require(
            msg.sender == ticketContract || 
            msg.sender == marketplaceContract || 
            msg.sender == owner(),
            "Not authorized"
        );
        _;
    }
    
    constructor(address _ticketContract, address _marketplaceContract) {
        ticketContract = _ticketContract;
        marketplaceContract = _marketplaceContract;
    }
    
    /**
     * @dev Update event metrics
     */
    function updateEventMetrics(
        uint256 _eventId,
        string memory _metricType,
        uint256 _value
    ) external onlyAuthorizedContracts {
        EventMetrics storage metrics = eventMetrics[_eventId];
        
        if (keccak256(abi.encodePacked(_metricType)) == keccak256(abi.encodePacked("ticket_sold"))) {
            metrics.ticketsSold++;
            metrics.totalRevenue += _value;
            metrics.averagePrice = metrics.totalRevenue / metrics.ticketsSold;
            platformMetrics.totalTicketsSold++;
            platformMetrics.totalRevenue += _value;
        } else if (keccak256(abi.encodePacked(_metricType)) == keccak256(abi.encodePacked("ticket_resold"))) {
            metrics.resaleCount++;
            metrics.resaleRevenue += _value;
            platformMetrics.totalResaleRevenue += _value;
        } else if (keccak256(abi.encodePacked(_metricType)) == keccak256(abi.encodePacked("ticket_scanned"))) {
            metrics.attendanceCount++;
            platformMetrics.totalAttendance++;
        } else if (keccak256(abi.encodePacked(_metricType)) == keccak256(abi.encodePacked("ticket_transformed"))) {
            metrics.transformedTickets++;
        }
        
        emit MetricsUpdated(_eventId, _metricType, _value);
    }
    
    /**
     * @dev Update creator metrics
     */
    function updateCreatorMetrics(address _creator, uint256 _revenue) external onlyAuthorizedContracts {
        creatorRevenue[_creator] += _revenue;
    }
    
    /**
     * @dev Get event metrics
     */
    function getEventMetrics(uint256 _eventId) external view returns (EventMetrics memory) {
        return eventMetrics[_eventId];
    }
    
    /**
     * @dev Get platform metrics
     */
    function getPlatformMetrics() external view returns (PlatformMetrics memory) {
        return platformMetrics;
    }
    
    /**
     * @dev Update contract addresses
     */
    function updateContracts(address _ticketContract, address _marketplaceContract) external onlyOwner {
        ticketContract = _ticketContract;
        marketplaceContract = _marketplaceContract;
    }
}
    
    function updatePlatformTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid address");
        platformTreasury = _newTreasury;
    }
    
    function updateEmergencyAdmin(address _newAdmin) external onlyOwner {
        require(_newAdmin != address(0), "Invalid address");
        emergencyAdmin = _newAdmin;
    }
    
    /**
     * @dev Deactivate event in emergency
     */
    function deactivateEvent(uint256 _eventId) external {
        require(msg.sender == owner() || msg.sender == emergencyAdmin, "Not authorized");
        require(events[_eventId].creator != address(0), "Event does not exist");
        events[_eventId].isActive = false;
    }
    
    // Required overrides
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }
    
    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }
    
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

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