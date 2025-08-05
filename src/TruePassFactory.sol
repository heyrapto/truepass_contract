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