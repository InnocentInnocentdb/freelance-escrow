// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FreelanceEscrow {
    // ENUM: the job's status (applies to the current milestone)
    enum Status {
        Created,
        Delivered,
        Approved,
        Disputed,
        Resolved
    }

    // STRUCT: the job's info card
    struct Job {
        address client;
        address freelancer;
        address arbiter;
        string description;
        uint256 totalAmount;
        uint256 paidAmount;
        uint256[] milestoneAmounts;
        uint256 currentMilestone;
        Status status;
    }

    // STORAGE
    uint256 public constant MAX_MILESTONES = 20;
    uint256 public jobCount;
    mapping(uint256 => Job) public jobs;
    bool private _locked;

    // CUSTOM ERRORS
    error NotClient();
    error NotFreelancer();
    error NotArbiter();
    error NotParty();
    error InvalidStatus();
    error InvalidAddress();
    error ZeroPayment();
    error NoMilestones();
    error TooManyMilestones();
    error ZeroMilestoneAmount();
    error AmountMismatch();
    error JobNotFound();
    error TransferFailed();
    error Reentrancy();

    // EVENTS
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed freelancer,
        uint256 totalAmount,
        uint256 milestoneCount
    );
    event JobDelivered(uint256 indexed jobId, uint256 milestone);
    event JobApproved(uint256 indexed jobId, uint256 milestone, uint256 amount);
    event JobDisputed(uint256 indexed jobId, uint256 milestone, address indexed raisedBy);
    event JobResolved(uint256 indexed jobId, uint256 milestone, address indexed winner, uint256 amount);

    // MODIFIERS: the bouncers
    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier jobExists(uint256 jobId) {
        if (jobId == 0 || jobId > jobCount) revert JobNotFound();
        _;
    }

    modifier onlyClient(uint256 jobId) {
        if (msg.sender != jobs[jobId].client) revert NotClient();
        _;
    }

    modifier onlyFreelancer(uint256 jobId) {
        if (msg.sender != jobs[jobId].freelancer) revert NotFreelancer();
        _;
    }

    modifier onlyArbiter(uint256 jobId) {
        if (msg.sender != jobs[jobId].arbiter) revert NotArbiter();
        _;
    }

    modifier inStatus(uint256 jobId, Status expected) {
        if (jobs[jobId].status != expected) revert InvalidStatus();
        _;
    }

    // CREATE JOB
    function createJob(address freelancer, address arbiter, string calldata description, uint256[] calldata amounts)
        external
        payable
        returns (uint256 jobId)
    {
        if (msg.value == 0) revert ZeroPayment();

        if (freelancer == address(0) || arbiter == address(0)) {
            revert InvalidAddress();
        }
        if (freelancer == msg.sender || arbiter == msg.sender || arbiter == freelancer) {
            revert InvalidAddress();
        }

        uint256 count = amounts.length;
        if (count == 0) revert NoMilestones();
        if (count > MAX_MILESTONES) revert TooManyMilestones();

        uint256 sum;
        for (uint256 i = 0; i < count; i++) {
            if (amounts[i] == 0) revert ZeroMilestoneAmount();
            sum += amounts[i];
        }
        if (sum != msg.value) revert AmountMismatch();

        jobId = ++jobCount;

        Job storage job = jobs[jobId];
        job.client = msg.sender;
        job.freelancer = freelancer;
        job.arbiter = arbiter;
        job.description = description;
        job.totalAmount = msg.value;
        job.milestoneAmounts = amounts;
        job.status = Status.Created;

        emit JobCreated(jobId, msg.sender, freelancer, msg.value, count);
    }

    // DELIVER
    function markDelivered(uint256 jobId)
        external
        jobExists(jobId)
        onlyFreelancer(jobId)
        inStatus(jobId, Status.Created)
    {
        Job storage job = jobs[jobId];

        job.status = Status.Delivered;

        emit JobDelivered(jobId, job.currentMilestone);
    }

    // APPROVE AND PAY THE CURRENT MILESTONE
    function approveJob(uint256 jobId)
        external
        nonReentrant
        jobExists(jobId)
        onlyClient(jobId)
        inStatus(jobId, Status.Delivered)
    {
        Job storage job = jobs[jobId];

        uint256 milestone = job.currentMilestone;
        uint256 amount = job.milestoneAmounts[milestone];

        job.paidAmount += amount;

        if (milestone + 1 == job.milestoneAmounts.length) {
            job.status = Status.Approved;
        } else {
            job.currentMilestone = milestone + 1;
            job.status = Status.Created;
        }

        emit JobApproved(jobId, milestone, amount);

        _pay(job.freelancer, amount);
    }

    // RAISE DISPUTE
    function raiseDispute(uint256 jobId) external jobExists(jobId) {
        Job storage job = jobs[jobId];

        if (msg.sender != job.client && msg.sender != job.freelancer) {
            revert NotParty();
        }
        if (job.status != Status.Created && job.status != Status.Delivered) {
            revert InvalidStatus();
        }

        job.status = Status.Disputed;

        emit JobDisputed(jobId, job.currentMilestone, msg.sender);
    }

    // ARBITER DECIDES THE CURRENT MILESTONE
    function resolveDispute(uint256 jobId, bool payFreelancer)
        external
        nonReentrant
        jobExists(jobId)
        onlyArbiter(jobId)
        inStatus(jobId, Status.Disputed)
    {
        Job storage job = jobs[jobId];

        uint256 milestone = job.currentMilestone;
        address winner;
        uint256 amount;

        if (payFreelancer) {
            winner = job.freelancer;
            amount = job.milestoneAmounts[milestone];
            job.paidAmount += amount;

            if (milestone + 1 == job.milestoneAmounts.length) {
                job.status = Status.Resolved;
            } else {
                job.currentMilestone = milestone + 1;
                job.status = Status.Created;
            }
        } else {
            winner = job.client;
            amount = job.totalAmount - job.paidAmount;
            job.status = Status.Resolved;
        }

        emit JobResolved(jobId, milestone, winner, amount);

        _pay(winner, amount);
    }

    // READ-ONLY: show a job's payment slices
    function getMilestones(uint256 jobId) external view jobExists(jobId) returns (uint256[] memory) {
        return jobs[jobId].milestoneAmounts;
    }

    // PAYMENT HELPER: the one place money leaves
    function _pay(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
