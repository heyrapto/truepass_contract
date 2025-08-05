# TruePass Integration Guide for Camp Network

## Overview

TruePass is a comprehensive Web3 ticketing platform built specifically for Camp Network, leveraging its unique IP-NFT capabilities and Origin SDK integration. This guide covers the complete deployment and integration process.

## 🏗️ Architecture Overview

The TruePass platform consists of five main smart contracts:

1. **TruePassTicketNFT** - Core NFT contract for tickets with IP registration
2. **TruePassMarketplace** - Secondary market for ticket resales
3. **TruePassFactory** - Factory for deploying new TruePass instances
4. **TruePassGovernance** - Governance contract for platform parameters
5. **TruePassAnalytics** - Analytics and metrics tracking

## 🚀 Deployment Process

### Prerequisites

1. **Node.js** v16+ and **npm**
2. **Hardhat** development environment
3. **Camp Network** RPC endpoint and private key
4. **IPFS** node or Pinata account for metadata storage

### Step 1: Environment Setup

Create a `.env` file with the following variables:

```bash
# Camp Network Configuration
CAMP_NETWORK_RPC_URL=https://rpc.campnetwork.xyz
PRIVATE_KEY=your_private_key_here
PLATFORM_TREASURY=0x...  # Platform treasury address
EMERGENCY_ADMIN=0x...    # Emergency admin address

# IPFS Configuration
IPFS_API_KEY=your_ipfs_api_key
IPFS_SECRET=your_ipfs_secret

# Origin SDK Configuration
ORIGIN_SDK_API_KEY=your_origin_sdk_key
```

### Step 2: Hardhat Configuration

Update your `hardhat.config.js`:

```javascript
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    campNetwork: {
      url: process.env.CAMP_NETWORK_RPC_URL,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 325000, // Camp Network chain ID
      gasPrice: "auto"
    }
  },
  etherscan: {
    apiKey: {
      campNetwork: process.env.CAMP_EXPLORER_API_KEY
    },
    customChains: [
      {
        network: "campNetwork",
        chainId: 325000,
        urls: {
          apiURL: "https://explorer.campnetwork.xyz/api",
          browserURL: "https://explorer.campnetwork.xyz"
        }
      }
    ]
  }
};
```

### Step 3: Deploy Contracts

Run the deployment script:

```bash
npx hardhat run scripts/deploy.js --network campNetwork
```

This will deploy all contracts and save the configuration to `deployments/camp-network.json`.

## 🔗 Origin SDK Integration

### Setting up IP NFT Registration

```javascript
import { OriginSDK } from '@camp-network/origin-sdk';

const originSDK = new OriginSDK({
  apiKey: process.env.ORIGIN_SDK_API_KEY,
  network: 'camp-network'
});

// Register event as IP NFT
async function registerEventIP(eventMetadata) {
  const ipRegistration = await originSDK.registerIP({
    title: eventMetadata.name,
    description: eventMetadata.description,
    content: eventMetadata,
    licenseTerms: {
      commercialUse: true,
      derivatives: true,
      royaltyPercentage: eventMetadata.royaltyPercentage
    }
  });
  
  return ipRegistration.ipfsHash;
}
```

## 📝 Frontend Integration

### Core Functions for Event Creators

```javascript
// Create a new event
async function createEvent(eventData) {
  const { contract } = await getTicketContract();
  
  // First register IP with Origin SDK
  const ipfsHash = await registerEventIP(eventData);
  
  // Create event on-chain
  const tx = await contract.createEvent(
    eventData.name,
    eventData.description,
    eventData.location,
    Math.floor(eventData.eventDate / 1000),
    ethers.utils.parseEther(eventData.ticketPrice),
    eventData.maxSupply,
    eventData.maxResalePercentage,
    eventData.royaltyPercent