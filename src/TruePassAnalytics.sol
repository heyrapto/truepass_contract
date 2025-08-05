// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

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
            metrics.averagePrice = metrics.ticketsSold > 0 ? metrics.totalRevenue / metrics.ticketsSold : 0;
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
