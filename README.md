# Freelance Escrow

[![CI](https://github.com/InnocentInnocentdb/freelance-escrow/actions/workflows/test.yml/badge.svg)](https://github.com/InnocentInnocentdb/freelance-escrow/actions/workflows/test.yml)

A smart contract where a client locks payment upfront, a freelancer delivers the work, and funds are released **only when the client approves**. If the two disagree, a neutral third address, the **arbiter**, decides the outcome. Payment can be split into **milestones**, so the freelancer is paid step by step instead of in one lump sum.

Built with Solidity and Foundry for the Option 8 brief (Freelance Escrow).

For design details, security analysis, and a guide for developers who fork or extend this project, read [WHITEPAPER.md](WHITEPAPER.md).

**Quick links:** [Whitepaper](WHITEPAPER.md) · [Verified contract](https://sepolia.etherscan.io/address/0xfE7E2b649B4D76bea09F9F7990A3C7FE43A5Aee3#code) · [Deployment transaction](https://sepolia.etherscan.io/tx/0x4990ad72a349a023185c49dac8269838da010b9e3d8ad61eee822881cf35846a) · [Release v1.0.0](https://github.com/InnocentInnocentdb/freelance-escrow/releases/tag/v1.0.0)

## Official deployment

| | |
|---|---|
| **Network** | Sepolia testnet (chain ID 11155111) |
| **Contract address** | `0xfE7E2b649B4D76bea09F9F7990A3C7FE43A5Aee3` |
| **Etherscan** | [Verified source code](https://sepolia.etherscan.io/address/0xfE7E2b649B4D76bea09F9F7990A3C7FE43A5Aee3#code) |
| **Deployment transaction** | `0x4990ad72a349a023185c49dac8269838da010b9e3d8ad61eee822881cf35846a` |
| **Block** | 11842182 |
| **Source** | `src/FreelanceEscrow.sol` (verified, exact match) |

This is the one official deployment. Everything in this repository describes this contract.

## Deployment history

An earlier prototype of the core escrow, without milestone support, was deployed on Sepolia at `0x9cdCEd629204154071A33a2388B880f2Bab62b1a`. It was **superseded by the contract above. It is not the final version and should not be used.** Blockchains cannot delete contracts, so it remains visible on-chain. The Git tag `v1-core` marks that earlier code.

## How it works

There are three roles, and they must be three different addresses:

- **Client:** hires the freelancer and funds the job.
- **Freelancer:** does the work and gets paid.
- **Arbiter:** a neutral third party who decides disputes.

**The flow**

1. The client calls `createJob` with a description and a list of payment amounts, sending the full payment in ETH. The contract holds it.
2. The freelancer calls `markDelivered` when the current step is done.
3. The client calls `approveJob`. The contract pays the freelancer for that step.
4. Steps are paid **in order**, one at a time. After the last step is approved, the job is complete.
5. If either side disagrees, they call `raiseDispute`. The money stays frozen until the arbiter calls `resolveDispute`.

**Simple job or milestone job**

A simple job is a job with one payment step, the full amount. A milestone job has several. The same code handles both.

Example: a 1 ETH brand package split as `[0.3, 0.3, 0.4]`. The client locks 1 ETH. The freelancer receives 0.3 ETH when step 1 is approved, 0.3 ETH for step 2, and 0.4 ETH for step 3.

**Disputes**

- If the arbiter sides with the **freelancer**, the current step is paid. If more steps remain, the job continues with the next one. If it was the last step, the job is closed.
- If the arbiter sides with the **client**, everything not yet paid goes back to the client, and the job is closed. Steps already paid stay with the freelancer.

## Choosing a payment mode

One contract handles both. The mode is set when the job is created, by the list of amounts the client passes to `createJob`. The client and the freelancer agree on it beforehand.

| Mode | Amounts list | ETH sent | How it pays |
|---|---|---|---|
| Lump sum | `[1 ETH]` | 1 ETH | One step, paid in full when the client approves |
| Milestones | `[0.3 ETH, 0.3 ETH, 0.4 ETH]` | 1 ETH | Three steps, paid one at a time, in order |

The amounts must add up exactly to the ETH sent, and on-chain they are written in wei (1 ETH = 10^18 wei). Once a job is created, its mode cannot be changed.

The client sets the amounts and the arbiter when creating the job, and the freelancer's agreement happens off-chain. Before starting work, the freelancer should check the job on-chain (`jobs(jobId)` and `getMilestones(jobId)`) to confirm that the steps and the arbiter match what was agreed.

## Job status

The status belongs to the job and always describes the step currently in progress.

| Status | Meaning |
|---|---|
| `Created` | Waiting for the freelancer to deliver the current step |
| `Delivered` | Waiting for the client to approve the current step |
| `Disputed` | Frozen until the arbiter decides |
| `Approved` | Finished: every step was approved and paid |
| `Resolved` | Finished: closed by the arbiter's decision |

## Functions

| Function | Who can call it | When |
|---|---|---|
| `createJob(freelancer, arbiter, description, amounts)` | Anyone (becomes the client) | Sends ETH equal to the sum of `amounts` |
| `markDelivered(jobId)` | Freelancer | Status is `Created` |
| `approveJob(jobId)` | Client | Status is `Delivered` |
| `raiseDispute(jobId)` | Client or freelancer | Status is `Created` or `Delivered` |
| `resolveDispute(jobId, payFreelancer)` | Arbiter | Status is `Disputed` |
| `getMilestones(jobId)` | Anyone (read-only) | Shows the payment steps of a job |

`createJob` requires: a payment above zero, three different non-zero addresses, between 1 and 20 steps, no step of zero, and step amounts that add up exactly to the ETH sent.

## Safety

- **Access control:** modifiers (`onlyClient`, `onlyFreelancer`, `onlyArbiter`, `inStatus`, `jobExists`) enforce who can act and when.
- **Reentrancy lock:** `nonReentrant` guards both functions that send money.
- **Update first, pay second:** the contract records a payment before it sends the ETH, so nothing can be paid twice.
- **One payout path:** every payment goes through a single private function.
- **Custom errors** give clear, cheap failure messages.
- **Bounded loop:** at most 20 steps per job.

## Limitations

- The arbiter is fully trusted. There is no timeout, so if the arbiter never decides, a disputed job stays frozen.
- There is no cancel feature.
- Payments are in ETH only.
- A job has at most 20 payment steps.
- This code has not been professionally audited.

## Tests

24 tests, all passing:

- creating simple and milestone jobs (2)
- paying simple and milestone jobs (2)
- disputes, including a freelancer win mid-job and a client refund of the remaining balance (5)
- a reentrancy attack that the contract blocks (1)
- 14 rejections: zero payment, bad addresses, wrong caller, wrong order, double approval, disputes after completion, and a job that does not exist

## Run it yourself

```bash
git clone --recurse-submodules https://github.com/InnocentInnocentdb/freelance-escrow.git
cd freelance-escrow
forge build
forge test
```

To deploy to Sepolia, set `SEPOLIA_RPC_URL` and `PRIVATE_KEY` in your environment, then run:

```bash
forge script script/DeployFreelanceEscrow.s.sol --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY" --broadcast
```

Never commit private keys or API keys.

## License and disclaimer

MIT. This project is for education and runs on a test network. Do not use it with real funds without an independent security audit.

Author: Innocent Taylor (Figadstro)
