# Security Policy

## Supported Versions

Turnip is pre-release (see [README](README.md) "Status"). There are no
tagged releases yet — security fixes apply to the `main` branch only.

| Version | Supported          |
| ------- | ------------------- |
| `main`  | :white_check_mark:  |

This table will be expanded once tagged releases exist.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, report it privately by emailing **github@hoie.kim** with:

- A description of the vulnerability and its potential impact
- Steps to reproduce, or a proof-of-concept if you have one
- Any affected version/commit information

If you'd prefer, you can also use
[GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
feature on this repository, if enabled.

### Response timeline

- **Acknowledgment**: within 3 business days of your report
- **Initial assessment** (severity, affected scope): within 7 business days
- **Fix or mitigation timeline**: communicated once the assessment is
  complete, prioritized by severity

We'll keep you updated as we work through the report and credit you in the
fix (unless you'd prefer to stay anonymous).

### Scope

Given the project's current on-device, no-server architecture (see
[`docs/DESIGN.md`](docs/DESIGN.md)), the main relevant surface today is the
`turnip-ios` app itself — e.g. unsafe handling of user media, unsafe use of
system frameworks, or dependency vulnerabilities in bundled libraries
(such as the MoveNet Thunder TFLite runtime). As the backend (`turnip-farm`)
and ML pipeline (`turnip-ml`) repos come online, this policy will extend to
cover them, including authentication (Sign in with Apple token validation),
data handling, and infrastructure concerns.
