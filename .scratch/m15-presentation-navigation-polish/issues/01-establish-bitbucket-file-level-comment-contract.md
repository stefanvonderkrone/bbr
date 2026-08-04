# Establish Bitbucket's File-level Comment contract

Type: research
Status: resolved
Blocked by: none

## Question

Does Bitbucket Cloud natively represent a Comment scoped to a File without line coordinates, and if so what request, response, display, threading, resolution, and update behavior must bbr's Review and Bitbucket contexts preserve? If it does not, what hard evidence rules the feature out of M15?

## Answer

Bitbucket Cloud natively represents a File-level root Comment through the ordinary pull-request comments endpoint with `inline.path` present and all line coordinates absent/null. It uses the ordinary reply, resolve/reopen, and content-update APIs. Scope remains owned by the root; bbr must distinguish path-only File-level Comments from line-anchored inline Comments and place their Threads at the File header.

Context: `docs/research/bitbucket-file-level-comments.md` on branch `research/bitbucket-file-level-comments`, commit `7c70f6c5315edfe818d8bb5132a01d3e14397b1b`.
