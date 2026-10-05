# Repository Instructions

## Scope

These instructions apply to the entire repository. More specific instructions
may refine them for a narrower subtree but shall not silently weaken them.

## Project Definition

Fasyn is an Ada library and bounded asynchronous runtime that implements the
FastCGI 1.0 application-side interface completely. The protocol authority is the
FastCGI Specification, Document Version 1.0, 29 April 1996.

Fasyn is protocol infrastructure, not an application framework. Keep HTTP,
routing, templates, database facilities, process management, application-session
policy, MCP semantics, and unrelated framework behavior outside this project.

## Repository Invariants

- Treat the local working tree, local Git history, and repository documents as
  the development source of truth. Preserve unrelated user changes.
- Consider performance, safety, reliability, and maintainability under
  large-scale, long-running, hostile, and failure conditions from design time.
- Prefer the smallest complete structural solution over compatibility shims,
  duplicate abstractions, or temporary workarounds.
- Do not introduce mutable global or package-level runtime state. Runtime state
  belongs to explicit objects with controlled lifetimes.
- FastCGI request identity is not `requestId` alone; asynchronous work that can
  outlive one request instance must distinguish connection and request
  generation.
- Bound or account for externally amplifiable resources and propagate
  backpressure instead of growing unbounded queues.
- Only the I/O owner of a connection may read or write that connection socket.
  Worker tasks do not write FastCGI bytes directly to sockets.
- Use Clair for generic operating-system/runtime facilities already provided by
  Clair. Keep FastCGI-specific state and policy in Fasyn.
- Do not weaken FastCGI validation for one peer implementation or extend Fasyn
  into unrelated application-framework responsibilities.
- Project-controlled temporary files belong under `build/tmp/`. Consumer-owned
  dependency artifacts belong under `build/deps/`.
- Unless explicitly requested, do not create branches or Pull Requests, push,
  or rewrite Git history.

## Clair Dependency

By default the public Clair source authority is the sibling checkout `../clair`;
`FASYN_CLAIR_ROOT` may select another checkout. Fasyn shall consume Clair through
its public project/API boundary and shall not modify Clair merely as a side
effect of Fasyn work.

Detailed dependency preparation, host/target separation, and prepared-root
contracts are owned by `docs/workflows/building.md`.

## Documentation Routing

Use `README.md` for the project overview and `docs/README.md` before opening
detailed documentation. The latter is the repository's authoritative
documentation router and identifies which document owns each subject and when
it should be read.

Do not duplicate a detailed contract in `AGENTS.md`, `README.md`, a roadmap, and
a specialist document. Keep the authoritative definition in one specialist
document and use short summaries plus references elsewhere.

When adding, removing, moving, or renaming an independent specialist document,
update `docs/README.md` in the same work unit so the rule remains discoverable.

## Work Sequence

Complete each stable work unit in this order:

    implementation
        -> test/verification
        -> roadmap update
        -> diff review
        -> commit

Before a commit, the active roadmap or owning work record, when one exists,
shall state the current state, completed work, remaining work, verification, and
next work point. Do not create a roadmap merely to satisfy this sequence when no
current delivery state needs one.

## Verification

Follow `docs/architecture/testing-policy.md` for what must be tested and
`docs/workflows/testing.md` for executable validation procedures. Do not report
unperformed validation as passing.

## Copyright Lineage

Fasyn originated in 2023. New Fasyn source files that carry a copyright range
shall preserve the 2023 start year; in 2026 the range is `2023-2026`.

Do not copy the Open Market, Inc. copyright from the historical FastCGI
reference implementation into clean implementations based only on the public
specification. Use an SPDX identifier only when the repository license defines
it.
