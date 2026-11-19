# Security policy

Scoops can read mail, run shell commands and operate computers. We take security reports seriously and thank
everyone who reports a problem responsibly.

## Reporting a vulnerability

**Please do not open a public issue.** Instead:

1. Use [GitHub's private vulnerability reporting](../../security/advisories/new), or
2. send an email to **hello@ais-con.com** with "Security" in the subject.

Please include what you found, how to reproduce it and what an attacker could do with it. We confirm receipt within
three working days and keep you posted until the issue is fixed. With your permission we credit you in the release
notes.

## Supported versions

Only the latest release of the server, the apps and the Cloud functions gets security fixes. The server app
updates itself, so most installations follow quickly.

## Especially interesting

- ways to run actions **without an approval card** that should require one
- prompt injection that makes a Scoop leak memory, files or vault entries to another chat, a guest or the web
- guests of shared Scoops reaching data or tools they should not see
- anything that exposes subscription logins, API keys or tokens
- pairing, session or push-relay flaws in `Cloud/`

## Out of scope

- what a model says or does inside the boundaries you approved
- attacks that need full control of the server Mac
- missing hardening headers without a concrete impact
