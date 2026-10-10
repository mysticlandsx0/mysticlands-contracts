# Security Policy

## Reporting a vulnerability

If you find a security issue in the MysticLands contracts, please report it privately:

- **Email:** security@mysticlands.online
- Include the affected contract and function, the impact, and steps or a test to reproduce it.
- Please do not disclose the issue publicly or exploit it on any network until it is fixed.

We will acknowledge your report within 72 hours and keep you updated until it is resolved.
Researchers who report valid issues responsibly will be credited (if they wish).

## Scope

| In scope | Out of scope |
|---|---|
| Contracts in [`src/`](src) and their deployments listed in the README | Test-only mocks in `src/mocks/` |
| Logic, access control, randomness, payments, upgrades of roles | Third-party libraries (report upstream to OpenZeppelin / Chainlink) |
| | The game website and API (report to the same email, separately) |

## Status

The contracts are live on Polygon mainnet and **not externally audited yet**. They are covered by unit and attack tests (see [`test/`](test)).
