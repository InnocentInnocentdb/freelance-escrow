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

    // HELPER: a simple job, one slice with the full payment
    function _simpleJob() internal returns (uint256) {
        uint256[] memory a = new uint256[](1);
        a[0] = PAY;

        vm.prank(client);
        return escrow.createJob{value: PAY}(freelancer, arbiter, "Design a logo", a);
    }

    // HELPER: a milestone job, three slices that add up to 1 ether
    function _milestoneJob() internal returns (uint256) {
        uint256[] memory a = new uint256[](3);
        a[0] = 0.3 ether;
        a[1] = 0.3 ether;
        a[2] = 0.4 ether;

        vm.prank(client);
        return escrow.createJob{value: PAY}(freelancer, arbiter, "Brand package", a);
    }

    // HELPER: read the job's progress
    function _info(uint256 id) internal view returns (uint256 paid, uint256 cur, FreelanceEscrow.Status st) {
        (,,,,, paid, cur, st) = escrow.jobs(id);
    }

    function _deliver(uint256 id) internal {
        vm.prank(freelancer);
        escrow.markDelivered(id);
    }

    function _approve(uint256 id) internal {
        vm.prank(client);
        escrow.approveJob(id);
    }

    function test_CreateSimpleJobLocksPayment() public {
        uint256 id = _simpleJob();

        assertEq(id, 1);
        assertEq(escrow.jobCount(), 1);
        assertEq(address(escrow).balance, PAY);

        (address c, address f, address a,, uint256 total,,,) = escrow.jobs(id);
        assertEq(c, client);
        assertEq(f, freelancer);
        assertEq(a, arbiter);
        assertEq(total, PAY);

        (uint256 paid, uint256 cur, FreelanceEscrow.Status st) = _info(id);
        assertEq(paid, 0);
        assertEq(cur, 0);
        assertEq(uint256(st), uint256(FreelanceEscrow.Status.Created));

        uint256[] memory slices = escrow.getMilestones(id);
        assertEq(slices.length, 1);
        assertEq(slices[0], PAY);
    }

    function test_CreateMilestoneJobStoresSlices() public {
        uint256 id = _milestoneJob();

        assertEq(address(escrow).balance, PAY);

        uint256[] memory slices = escrow.getMilestones(id);
        assertEq(slices.length, 3);
        assertEq(slices[0], 0.3 ether);
        assertEq(slices[1], 0.3 ether);
        assertEq(slices[2], 0.4 ether);
    }

    function test_SimpleJobHappyPath() public {
        uint256 id = _simpleJob();

        _deliver(id);
        _approve(id);

        assertEq(freelancer.balance, PAY);
        assertEq(address(escrow).balance, 0);

        (uint256 paid,, FreelanceEscrow.Status st) = _info(id);
        assertEq(paid, PAY);
        assertEq(uint256(st), uint256(FreelanceEscrow.Status.Approved));
    }

    function test_MilestoneJobPaidSliceBySlice() public {
        uint256 id = _milestoneJob();

        // slice 1
        _deliver(id);
        _approve(id);
        assertEq(freelancer.balance, 0.3 ether);
        assertEq(address(escrow).balance, 0.7 ether);
        (, uint256 cur, FreelanceEscrow.Status st) = _info(id);
        assertEq(cur, 1);
        assertEq(uint256(st), uint256(FreelanceEscrow.Status.Created));

        // slice 2
        _deliver(id);
        _approve(id);
        assertEq(freelancer.balance, 0.6 ether);
        assertEq(address(escrow).balance, 0.4 ether);

        // slice 3 (the last one)
        _deliver(id);
        _approve(id);
        assertEq(freelancer.balance, PAY);
        assertEq(address(escrow).balance, 0);
        (uint256 paid,, FreelanceEscrow.Status last) = _info(id);
        assertEq(paid, PAY);
        assertEq(uint256(last), uint256(FreelanceEscrow.Status.Approved));
    }

    function _dispute(uint256 id, address who) internal {
        vm.prank(who);
        escrow.raiseDispute(id);
    }

    function _resolve(uint256 id, bool payFreelancer) internal {
        vm.prank(arbiter);
        escrow.resolveDispute(id, payFreelancer);
    }

    function test_DisputeArbiterPaysFreelancer_SimpleJob() public {
        uint256 id = _simpleJob();

        _deliver(id);
        _dispute(id, client);
        _resolve(id, true);

        assertEq(freelancer.balance, PAY);
        assertEq(address(escrow).balance, 0);

        (uint256 paid,, FreelanceEscrow.Status st) = _info(id);
        assertEq(paid, PAY);
        assertEq(uint256(st), uint256(FreelanceEscrow.Status.Resolved));
    }

    function test_DisputeArbiterRefundsClient_SimpleJob() public {
        uint256 id = _simpleJob();

        _dispute(id, freelancer);
        _resolve(id, false);

        assertEq(client.balance, 10 ether);
        assertEq(freelancer.balance, 0);
        assertEq(address(escrow).balance, 0);

        (,, FreelanceEscrow.Status st) = _info(id);
        assertEq(uint256(st), uint256(FreelanceEscrow.Status.Resolved));
    }

    function test_DisputeFreelancerWinsMidJobAndWorkContinues() public {
        uint256 id = _milestoneJob();

        // slice 1 paid normally
        _deliver(id);
        _approve(id);

        // slice 2 disputed, arbiter sides with the freelancer
        _deliver(id);
        _dispute(id, client);
        _resolve(id, true);

        assertEq(freelancer.balance, 0.6 ether);
        assertEq(address(escrow).balance, 0.4 ether);

        (uint256 paid, uint256 cur, FreelanceEscrow.Status st) = _info(id);
        assertEq(paid, 0.6 ether);
        assertEq(cur, 2);
        assertEq(uint256(st), uint256(FreelanceEscrow.Status.Created));

        // slice 3 completes normally
        _deliver(id);
        _approve(id);

        assertEq(freelancer.balance, PAY);
        assertEq(address(escrow).balance, 0);

        (,, FreelanceEscrow.Status last) = _info(id);
        assertEq(uint256(last), uint256(FreelanceEscrow.Status.Approved));
    }

    function test_DisputeClientWinsRefundsRemaining() public {
        uint256 id = _milestoneJob();

        // slice 1 paid normally
        _deliver(id);
        _approve(id);

        // slice 2 disputed, arbiter sides with the client
        _dispute(id, freelancer);
        _resolve(id, false);

        assertEq(freelancer.balance, 0.3 ether);
        assertEq(client.balance, 9.7 ether);
        assertEq(address(escrow).balance, 0);

        (uint256 paid,, FreelanceEscrow.Status st) = _info(id);
        assertEq(paid, 0.3 ether);
        assertEq(uint256(st), uint256(FreelanceEscrow.Status.Resolved));
    }

    function test_OnlyArbiterCanResolve() public {
        uint256 id = _simpleJob();
        _dispute(id, client);

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.NotArbiter.selector);
        escrow.resolveDispute(id, true);
    }

    function test_RevertWhen_ZeroPayment() public {
        uint256[] memory a = new uint256[](1);
        a[0] = PAY;

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.ZeroPayment.selector);
        escrow.createJob{value: 0}(freelancer, arbiter, "No pay", a);
    }

    function test_RevertWhen_FreelancerIsClient() public {
        uint256[] memory a = new uint256[](1);
        a[0] = PAY;

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.InvalidAddress.selector);
        escrow.createJob{value: PAY}(client, arbiter, "Self hire", a);
    }

    function test_RevertWhen_NoMilestones() public {
        uint256[] memory a = new uint256[](0);

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.NoMilestones.selector);
        escrow.createJob{value: PAY}(freelancer, arbiter, "Empty", a);
    }

    function test_RevertWhen_TooManyMilestones() public {
        uint256[] memory a = new uint256[](21);
        for (uint256 i = 0; i < 21; i++) {
            a[i] = 1;
        }

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.TooManyMilestones.selector);
        escrow.createJob{value: 21}(freelancer, arbiter, "Too many", a);
    }

    function test_RevertWhen_ZeroMilestoneAmount() public {
        uint256[] memory a = new uint256[](3);
        a[0] = 0.5 ether;
        a[1] = 0;
        a[2] = 0.5 ether;

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.ZeroMilestoneAmount.selector);
        escrow.createJob{value: PAY}(freelancer, arbiter, "Zero slice", a);
    }

    function test_RevertWhen_AmountMismatch() public {
        uint256[] memory a = new uint256[](1);
        a[0] = 0.3 ether;

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.AmountMismatch.selector);
        escrow.createJob{value: PAY}(freelancer, arbiter, "Mismatch", a);
    }

    function test_RevertWhen_FreelancerApproves() public {
        uint256 id = _simpleJob();
        _deliver(id);

        vm.prank(freelancer);
        vm.expectRevert(FreelanceEscrow.NotClient.selector);
        escrow.approveJob(id);
    }

    function test_RevertWhen_ClientMarksDelivered() public {
        uint256 id = _simpleJob();

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.NotFreelancer.selector);
        escrow.markDelivered(id);
    }

    function test_RevertWhen_ApproveBeforeDelivery() public {
        uint256 id = _simpleJob();

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.InvalidStatus.selector);
        escrow.approveJob(id);
    }

    function test_RevertWhen_ApproveNextSliceBeforeItsDelivery() public {
        uint256 id = _milestoneJob();

        _deliver(id);
        _approve(id);

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.InvalidStatus.selector);
        escrow.approveJob(id);
    }

    function test_RevertWhen_StrangerRaisesDispute() public {
        uint256 id = _simpleJob();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FreelanceEscrow.NotParty.selector);
        escrow.raiseDispute(id);
    }

    function test_RevertWhen_ApprovedTwice() public {
        uint256 id = _simpleJob();
        _deliver(id);
        _approve(id);

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.InvalidStatus.selector);
        escrow.approveJob(id);
    }

    function test_RevertWhen_DisputeAfterCompletion() public {
        uint256 id = _simpleJob();
        _deliver(id);
        _approve(id);

        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.InvalidStatus.selector);
        escrow.raiseDispute(id);
    }

    function test_RevertWhen_JobDoesNotExist() public {
        vm.prank(client);
        vm.expectRevert(FreelanceEscrow.JobNotFound.selector);
        escrow.approveJob(999);
    }

    function test_ReentrancyAttackIsBlocked() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(escrow);

        uint256[] memory a = new uint256[](2);
        a[0] = 0.4 ether;
        a[1] = 0.6 ether;

        vm.prank(client);
        uint256 id = escrow.createJob{value: PAY}(address(attacker), arbiter, "Attack", a);

        attacker.setTarget(id);
        attacker.deliver();
        _approve(id);

        assertTrue(attacker.reentryAttempted());
        assertFalse(attacker.reentrySucceeded());
        assertEq(bytes4(attacker.reentryError()), FreelanceEscrow.Reentrancy.selector);
        assertEq(address(attacker).balance, 0.4 ether);
        assertEq(address(escrow).balance, 0.6 ether);
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
        (bool ok, bytes memory data) = address(escrow).call(abi.encodeCall(FreelanceEscrow.approveJob, (targetId)));
        reentrySucceeded = ok;
        reentryError = data;
    }
}
