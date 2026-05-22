// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Coordinator} from "./Coordinator.sol";
import {NLVerifier} from "./NLVerifier.sol";
import {RiscZeroMockVerifier} from "risc0/test/RiscZeroMockVerifier.sol";

contract DeployScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        NLVerifier nl = new NLVerifier();
        RiscZeroMockVerifier zk = new RiscZeroMockVerifier(bytes4(0));
        new Coordinator(nl, zk, bytes32(0));
        vm.stopBroadcast();
    }
}
