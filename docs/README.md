# Documentation

This file is the routing index for Fasyn documentation. Start with the root
`../AGENTS.md`, identify the kind of work being performed, and read only the
specialist documents that own the relevant contracts. Read multiple specialist
documents together only when the work genuinely crosses their subjects.

## Design and Architecture

### General design, implementation, or code review

[`architecture/engineering-principles.md`](architecture/engineering-principles.md)

Owns minimum-sufficient design, protocol/runtime separation, incremental
processing, state ownership, boundedness, backpressure, platform boundaries,
and application isolation.

### Failure semantics, cleanup, cancellation, or invariant handling

[`architecture/failure-model.md`](architecture/failure-model.md)

Owns failure classes and scopes, cancellation/late-work behavior, cleanup
requirements, and handling of multiple failures.

### FastCGI wire behavior or completeness claims

[`architecture/protocol-conformance.md`](architecture/protocol-conformance.md)

Owns the FastCGI 1.0 protocol contract, role/lifecycle requirements, automated
evidence mapping, and conformance completion criteria.

### Resource limits, admission, buffering, or backpressure

[`architecture/resource-policy.md`](architecture/resource-policy.md)

Owns bounded resource policy, streaming/buffering limits, output backpressure,
fairness, allocation safety, and configuration consistency.

### Runtime ownership, concurrency, lifecycle, or Clair boundary

[`architecture/runtime-model.md`](architecture/runtime-model.md)

Owns runtime layers, package ownership, executor/application boundaries,
connection/request ownership, multiplexed output, cancellation, shutdown, and
the Clair runtime boundary.

### Security review or attack-shaped behavior

[`architecture/security-model.md`](architecture/security-model.md)

Owns trust boundaries, security properties, failure containment, validation
expectations, and security non-goals.

### Test design and required coverage

[`architecture/testing-policy.md`](architecture/testing-policy.md)

Owns required test levels, fragmentation/multiplexing/resource/negative tests,
fuzz/property expectations, long-run validation policy, and conformance
evidence requirements.

### Version and compatibility decisions

[`architecture/versioning.md`](architecture/versioning.md)

Owns source compatibility, release-version meaning, supported API boundaries,
and the absence of a general compiler-generated Ada binary ABI promise.

## Workflows and Conventions

### Building, dependency preparation, cross-builds, or cleaning

[`workflows/building.md`](workflows/building.md)

Owns toolchain selection, Clair source/artifact preparation, host/target
separation, GPRbuild/Rake entry points, Alire build integration, artifact
isolation, and cleanup procedures.

### Running tests, acceptance, soak, memory checks, or interoperability

[`workflows/testing.md`](workflows/testing.md)

Owns executable test commands, supported-platform acceptance, Valgrind and
resource gates, Alire consumer acceptance, NGINX interoperability, and test
fixture/dependency procedures.

### Editing Ada source or reviewing source style

[`conventions/style-guide.md`](conventions/style-guide.md)

Shared Clair/Fasyn Ada coding-style baseline. Fasyn architecture and safety
contracts take precedence where they are more restrictive.

## Current Delivery State

[`roadmaps/README.md`](roadmaps/README.md)

Routes only active implementation or delivery roadmaps. Completed work belongs
in Git history or in the durable specialist document that owns its contract;
roadmaps are not historical journals.
