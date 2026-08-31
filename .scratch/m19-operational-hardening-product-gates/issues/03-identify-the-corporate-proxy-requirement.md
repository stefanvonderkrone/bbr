# Identify the corporate proxy requirement

Type: task
Status: resolved
Blocked by: none

## Question

What proxy protocol and authentication method does the representative corporate environment require, and what sanitized connectivity evidence shows whether the current `StdHttpClient` can reach the Bitbucket Cloud API through it?

## Answer

The representative corporate environment permits direct HTTPS access to Bitbucket Cloud. It requires no proxy protocol, proxy authentication, or TLS interception.

The current shell had no `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, or lowercase equivalent. macOS `scutil --proxy` returned an empty proxy configuration. Through the Keychain-backed `run-bbr` wrapper, `./run-bbr detect pr-webapp` completed successfully with `StdHttpClient` and listed open PullRequests. The check printed no Credential values.
