// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {CrossingCounter} from "./CrossingCounter.sol";

contract DeployScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        CrossingCounter.Edge[] memory edges = new CrossingCounter.Edge[](0);
        new CrossingCounter(edges, false);
        vm.stopBroadcast();
    }
}
