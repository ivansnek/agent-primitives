# Herd security standards — phase security audit

This is the engine's default security standard, used when a repo configures none of its own
(`.claude/herd.config.json` → `securityStandards`). It is the bar for every herd audit stage,
which runs after a plan is implemented and before its code-quality review. Your brief
(`audit-N.brief.md`) owns the mechanics — what to fix, what to defer, how to verify, what to
commit. This file owns the *bar*.

The audit is a focused, adversarial read of the reviewed range. Assume an attacker controls
every input that crosses a trust boundary, and ask what the new code lets them do. Report
vulnerabilities, not style: a finding needs a concrete attacker, a concrete path through the
code, and a concrete impact.

## Core prompt

> Perform a security audit of the reviewed range.
> Trace every new or changed entry point from the untrusted input to the sensitive sink.
> For each path, decide whether an attacker can read, write, execute, or deny something they
> should not. Prove it from the code, then close it with the smallest correct fix.

## What to check

1. **Injection.** SQL/NoSQL built from strings, shell commands built from input (`exec`,
   `system`, `child_process`, backticks), template or `eval`-style execution, LDAP/XPath,
   header and log injection (CR/LF), path building from input. Parameterize; never escape by
   hand when the platform offers a safe API.
2. **Broken access control.** Every new route, handler, query, job, and file access: is the
   caller authenticated, and is the caller *authorized for this specific object* (IDOR)? Are
   owner / organization filters applied server-side, not trusted from the client? Are admin-only
   paths guarded in the canonical layer the codebase already uses?
3. **Authentication and sessions.** Password, token, and session handling; token expiry and
   revocation; comparison of secrets in constant time; no auth decisions made on client-
   controlled flags; no credential or token in a URL, log line, or error message.
4. **Secrets and sensitive data.** Hard-coded keys, tokens, passwords, connection strings,
   private URLs; secrets committed to fixtures or tests; sensitive fields returned by an API
   or written to logs, analytics, or client bundles (e.g. server-only env vars exposed to a
   browser build).
5. **Input validation and deserialization.** Untrusted data parsed without a schema; unsafe
   deserialization; mass assignment (spreading a request body into a model or query);
   missing size, type, range, or count limits that let one request exhaust memory or CPU.
6. **Cross-site and client-side issues.** XSS (unescaped output, `dangerouslySetInnerHTML`,
   `innerHTML`, `v-html`, URL schemes like `javascript:`), CSRF on state-changing requests,
   open redirects, permissive CORS (`*` with credentials, reflected origins), clickjacking
   headers where the app sets headers.
7. **Server-side request forgery and files.** Server-side fetches of user-supplied URLs;
   path traversal (`../`) in file reads, writes, uploads, and archive extraction; uploads
   without type and size checks; files written to web-served directories.
8. **Cryptography.** Weak or home-grown crypto, `Math.random`-style RNG for tokens or IDs,
   static IVs or salts, MD5/SHA-1 for passwords, disabled TLS verification.
9. **Error handling and information leaks.** Stack traces, SQL errors, internal paths, or
   user-existence oracles returned to clients; fail-open branches where a failed check lets
   the request through.
10. **Dependencies and configuration.** New dependencies with known vulnerabilities or no
    clear provenance; debug modes, permissive defaults, or disabled security middleware
    introduced by the range; infrastructure or policy files (RLS policies, IAM, firewall,
    CSP) loosened by the range.
11. **Concurrency and business logic.** Check-then-act races on balances, quotas, or
    permissions; replayable operations without idempotency; trusting client-computed
    prices, totals, or roles.

## Severity

| Severity | Meaning |
|---|---|
| `critical` | Remote, unauthenticated or cross-account compromise: code execution, auth bypass, full data read/write, leaked live secret. |
| `high` | Authenticated user can reach data or actions they must not (IDOR, privilege escalation), stored XSS, SSRF to internal services. |
| `medium` | Exploitable with preconditions or limited impact: reflected XSS, CSRF on a minor action, missing rate limit on a sensitive endpoint, information leak that aids an attack. |
| `low` | Defense-in-depth gap with no demonstrated exploit path. |

## Bar

- Report only what the range introduces or makes reachable. Pre-existing issues outside the
  range are out of scope unless the range newly exposes them — then they are in scope.
- No finding without evidence: name the input, the path (`file:line` → `file:line`), and the
  impact. "Could be insecure" is not a finding.
- Prefer a small number of real vulnerabilities over a long list of hardening suggestions.
  `low` findings are recorded; they never crowd out a `high`.
- Never copy a secret's value into the findings file, a commit message, or the terminal:
  name its location only.
- A range with no security-relevant surface (docs, pure refactors, styling) is a legitimate
  clean result. Record what you checked, in the form your brief asks for.
