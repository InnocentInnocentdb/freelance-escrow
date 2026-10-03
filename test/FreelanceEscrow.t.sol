// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FreelanceEscrow} from "../src/FreelanceEscrow.sol";

contract FreelanceEscrowTest is Test {
    FreelanceEscrow escrow;

    address client = makeAddr("client");
    address freelancer = makeAddr("freelancer");
    address arbiter = makeAddr("arbiter");

    uint256 constant PAY = 1 ether;

    function setUp() public {
        escrow = new FreelanceEscrow();
        vm.deal(client, 10 ether);
    }

    function _createJob() internal returns (uint256) {
        vm.prank(client);
        return escrow.createJob{value: PAY}(
            freelancer,
            arbiter,
            "Design a logo"
        );
    }

    function test_CreateJobLocksPayment() public {
        uint256 id = _createJob();

        assertEq(id, 1);
        assertEq(escrow.jobCount(), 1);
        assertEq(address(escrow).balance, PAY);

        (
            address c,
            address f,
            address a,
            uint256 amt,
            string memory d,
            FreelanceEscrow.Status st
        ) = escrow.jobs(id);

        assertEq(c, client);
        assertEq(f, freelancer);
        assertEq(a, arbiter);
        assertEq(amt, PAY);
        assertEq(d, "Design a logo");
        assertEq(uint256(st), uint256(FreelanceEscrow.Status.Created));
    }

    function test_FullHappyPath() public {
        uint256 id = _createJob();

        vm.prank(freelancer);
        escrow.markDelivered(id);

        vm.prank(client);
        escrow.approveJob(id);

        assertEq(freelancer.balance, PAY);
        assertEq(address(escrow).balance, 0);
    }

    function test_DisputeArbiterPaysFreelancer() public {
        uint256 id = _createJob();

        vm.prank(freelancer);
        escrow.markDelivered(id);

        vm.prank(client);
        escrow.raiseDispute(id);

        vm.prank(arbiter);
        escrow.resolveDispute(id, true);

        assertEq(freelancer.balance, PAY);
        assertEq(address(escrow).balance, 0);
    }

    function test_DisputeArbiterRefundsClient() public {
        uint256 id = _createJob();

        vm.prank(freelancer);
        escrow.raiseDispute(id);

        vm.prank(arbiter);
        escrow.resolveDispute(id, false);

        assertEq(client.balance, 10 ether);
        assertEq(freelancer.balance, 0);
        assertEq(address(escrow).balance, 0);
    }

    function test_OnlyArbiterCanResolve() public {
        uint256 id = _createJob();

        vm.prank(client);
        escrow.raiseDispute(id);

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.NotArbiter.selector);
        escrow.resolveDispute(id, true);
    }

    function test_RevertWhen_ZeroPayment() public {
        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.ZeroPayment.selector);
        escrow.createJob{value: 0}(freelancer, arbiter, "No pay");
    }

    function test_RevertWhen_FreelancerIsClient() public {
        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.InvalidAddress.selector);
        escrow.createJob{value: PAY}(client, arbiter, "Self hire");
    }

    function test_RevertWhen_FreelancerApproves() public {
        uint256 id = _createJob();

        vm.prank(freelancer);
        escrow.markDelivered(id);

        vm.prank(freelancer);
        vm.expectRevert(FreelanceEscrow.NotClient.selector);
        escrow.approveJob(id);
    }

    function test_RevertWhen_ClientMarksDelivered() public {
        uint256 id = _createJob();

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.NotFreelancer.selector);
        escrow.markDelivered(id);
    }

    function test_RevertWhen_ApproveBeforeDelivery() public {
        uint256 id = _createJob();

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.InvalidStatus.selector);
        escrow.approveJob(id);
    }

    function test_RevertWhen_StrangerRaisesDispute() public {
        uint256 id = _createJob();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FreelanceEscrow.NotParty.selector);
        escrow.raiseDispute(id);
    }

    function test_RevertWhen_ApprovedTwice() public {
        uint256 id = _createJob();

        vm.prank(freelancer);
        escrow.markDelivered(id);

        vm.prank(client);
        escrow.approveJob(id);

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.InvalidStatus.selector);
        escrow.approveJob(id);
    }

    function test_RevertWhen_JobDoesNotExist() public {
        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.JobNotFound.selector);
        escrow.approveJob(999);
    }

    function test_ReentrancyAttackIsBlocked() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(escrow);

        vm.prank(client);
        uint256 id = escrow.createJob{value: PAY}(
            address(attacker),
            arbiter,
            "Attack"
        );

        attacker.setTarget(id);
        attacker.deliver();

        vm.prank(client);
        escrow.approveJob(id);

        assertTrue(attacker.reentryAttempted());
        assertFalse(attacker.reentrySucceeded());
        assertEq(
            bytes4(attacker.reentryError()),
            FreelanceEscrow.Reentrancy.selector
        );
        assertEq(address(attacker).balance, PAY);
        assertEq(address(escrow).balance, 0);
    }
}

// THE THIEF: tries to re-enter the escrow when it receives payment
contract ReentrancyAttacker {
    FreelanceEscrow public escrow;
    uint256 public targetId;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor(FreelanceEscrow _escrow) {
        escrow = _escrow;
    }

    function setTarget(uint256 id) external {
        targetId = id;
    }

    function deliver() external {
        escrow.markDelivered(targetId);
    }

    receive() external payable {
        reentryAttempted = true;
        (bool ok, bytes memory data) = address(escrow).call(
            abi.encodeCall(FreelanceEscrow.approveJob, (targetId))
        );
        reentrySucceeded = ok;
        reentryError = data;
    }
}
