// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

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