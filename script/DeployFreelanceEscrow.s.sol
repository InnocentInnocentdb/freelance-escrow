// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FreelanceEscrow} from "../src/FreelanceEscrow.sol";

contract DeployFreelanceEscrow is Script {
    function run() external returns (FreelanceEscrow escrow) {
        vm.startBroadcast();
        escrow = new FreelanceEscrow();
        vm.stopBroadcast();

        console.log("FreelanceEscrow deployed at:", address(escrow));
    }
}
