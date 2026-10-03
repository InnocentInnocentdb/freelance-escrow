// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FreelanceEscrow {
    // ENUM: the job's mood label
    enum Status {
        Created,
        Delivered,
        Approved,
        Disputed,
        Resolved,
        Cancelled
    }

    // STRUCT: the job's info card
    struct Job {
        address client;
        address freelancer;
        address arbiter;
        uint256 amount;
        string description;
        Status status;
    }

    // STORAGE
    uint256 public jobCount;
    mapping(uint256 => Job) public jobs;
    bool private _locked;

    // CUSTOM ERRORS
    error NotClient();
    error NotFreelancer();
    error NotArbiter();
    error NotParty();
    error InvalidStatus();
    error ZeroPayment();
    error InvalidAddress();
    error TransferFailed();
    error JobNotFound();
    error Reentrancy();

    // EVENTS
    event JobCreated(uint256 indexed jobId, address indexed client, address indexed freelancer, uint256 amount);
    event JobDelivered(uint256 indexed jobId);
    event JobApproved(uint256 indexed jobId);
    event JobDisputed(uint256 indexed jobId, address indexed raisedBy);
    event JobResolved(uint256 indexed jobId, address indexed winner);
    event JobCancelled(uint256 indexed jobId);

    // MODIFIERS: the bouncers
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

    // REENTRANCY LOCK: one at a time
    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // CREATE JOB
    function createJob(address freelancer, address arbiter, string calldata description)
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

        jobId = ++jobCount;

        jobs[jobId] = Job({
            client: msg.sender,
            freelancer: freelancer,
            arbiter: arbiter,
            amount: msg.value,
            description: description,
            status: Status.Created
        });

        emit JobCreated(jobId, msg.sender, freelancer, msg.value);
    }

    // DELIVER
    function markDelivered(uint256 jobId)
        external
        jobExists(jobId)
        onlyFreelancer(jobId)
        inStatus(jobId, Status.Created)
    {
        jobs[jobId].status = Status.Delivered;

        emit JobDelivered(jobId);
    }

    // APPROVE AND PAY
    function approveJob(uint256 jobId)
        external
        nonReentrant
        jobExists(jobId)
        onlyClient(jobId)
        inStatus(jobId, Status.Delivered)
    {
        Job storage job = jobs[jobId];

        job.status = Status.Approved;

        emit JobApproved(jobId);

        _pay(job.freelancer, job.amount);
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

        emit JobDisputed(jobId, msg.sender);
    }

    // ARBITER DECIDES
    function resolveDispute(uint256 jobId, bool payFreelancer)
        external
        nonReentrant
        jobExists(jobId)
        onlyArbiter(jobId)
        inStatus(jobId, Status.Disputed)
    {
        Job storage job = jobs[jobId];

        job.status = Status.Resolved;

        address winner = payFreelancer ? job.freelancer : job.client;

        emit JobResolved(jobId, winner);

        _pay(winner, job.amount);
    }

    // PAYMENT HELPER: the one place money leaves
    function _pay(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
