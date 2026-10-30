# 01: Research Bitbucket Cloud Comment image storage

Status: ready-for-agent
Blocked by: none
Spec: [M32 spec](../SPEC.md)

## What to build

A research note that answers the questions Q1 to Q4 of the spec from public sources.
The note says how Bitbucket Cloud stores an image that a user pastes into a Comment.
It says if the image URL needs the Credential, if it redirects, and if it expires.
It defines the Bitbucket host list for the Credential host rule.

This ticket makes no request to Bitbucket and reads no Credential.
Ticket 04 confirms the findings on a real PullRequest.

## Scope

- Write `research/bitbucket-comment-images.md` in the M32 directory.
- Read the Bitbucket Cloud REST documentation for PullRequest Comments, `content.raw`, and `content.html`.
- Read public Atlassian documentation, Atlassian community answers, and public Jira issues about pasted images and attachments.
- Read the M23 note [Cloud Markdown compatibility](../../m23-comment-thread-markdown-presentation-fixes/research/cloud-markdown-compatibility.md) for the relative image findings.
- Answer each question with a source, and mark each answer as `documented`, `reported`, or `unknown`.
  - Q1: the URL form of a pasted image in `content.raw`. Give a synthetic example, not a real URL.
  - Q2: whether the URL needs the Credential, the redirect chain and its hosts, and whether a URL expires.
  - Q3: the base of a relative image reference, and whether PullRequest Comments have an attachment form.
  - Q4: the Bitbucket host list. Name each host and the reason that it may get the Credential.
- For each storage host in a redirect chain, record if Bitbucket controls it.
  The spec uses this evidence for the external-load rule.
- Write a checklist for ticket 04.
  Each `unknown` or `reported` answer gets one check on a real PullRequest.
- An answer can change a choice in the "Choices this spec records" section of the spec.
  If so, name the choice and the change.

## Acceptance criteria

- [ ] `research/bitbucket-comment-images.md` answers Q1 to Q4, each with a source and a confidence mark.
- [ ] The note gives a Bitbucket host list with exact hosts and no wildcard.
- [ ] The note says, for each redirect host, whether Bitbucket controls it.
- [ ] The note has a checklist for ticket 04 with one check for each open answer.
- [ ] The note holds no real image URL, no Comment text, and no Credential value.
- [ ] The note names every spec choice that its answers change, or states that none changes.
- [ ] `python3 tools/check_agent_docs.py` passes.
