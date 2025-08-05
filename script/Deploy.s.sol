// script/Deploy.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import "../src/TruePassTicketNFT.sol";
import "../src/TruePassMarketplace.sol";
import "../src/TruePassFactory.sol";z
import "../src/TruePassGovernance.sol";
import "../src/TruePassAnalytics.sol";

contract Deploy is Script {
    function run() public {
        // Read RPC/priv key from env or use forge flags. Provide PRIVATE_KEY as hex string (0x...).
        // If you prefer to use --private-key on cli, that's fine.
        // uint256 pk = vm.envUint("PRIVATE_KEY"); // alternative
        // vm.startBroadcast(pk);

        // We'll use vm.startBroadcast() without param if using --private-key flag on CLI:
        vm.startBroadcast();

        // Read platform addresses fallback to deployer
        address platformTreasury = vm.envAddress("PLATFORM_TREASURY");
        address emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");

        // If env var not set (== address(0)), fallback to msg.sender (the broadcasting address)
        address deployer = msg.sender;
        address _platformTreasury = platformTreasury == address(0) ? deployer : platformTreasury;
        address _emergencyAdmin = emergencyAdmin == address(0) ? deployer : emergencyAdmin;

        console.log("Deployer:", deployer);
        console.log("Platform treasury:", _platformTreasury);
        console.log("Emergency admin:", _emergencyAdmin);

        // 1. Deploy TruePassTicketNFT
        TruePassTicketNFT ticket = new TruePassTicketNFT(_platformTreasury, _emergencyAdmin);
        console.log("TruePassTicketNFT deployed to:", address(ticket));

        // 2. Deploy TruePassMarketplace
        TruePassMarketplace marketplace = new TruePassMarketplace(address(ticket), _platformTreasury);
        console.log("TruePassMarketplace deployed to:", address(marketplace));

        // 3. Deploy TruePassFactory
        TruePassFactory factory = new TruePassFactory(_platformTreasury, _emergency_admin());
        console.log("TruePassFactory deployed to:", address(factory));

        // 4. Deploy TruePassGovernance
        TruePassGovernance governance = new TruePassGovernance();
        console.log("TruePassGovernance deployed to:", address(governance));

        // 5. Deploy TruePassAnalytics
        TruePassAnalytics analytics = new TruePassAnalytics(address(ticket), address(marketplace));
        console.log("TruePassAnalytics deployed to:", address(analytics));

        vm.stopBroadcast();
    }

    // Helper to avoid repeating envAddress call inside inline expression (keeps logs tidy)
    function _emergency_admin() internal view returns (address) {
        address emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");
        if (emergencyAdmin == address(0)) {
            return msg.sender;
        }
        return emergencyAdmin;
    }
}
