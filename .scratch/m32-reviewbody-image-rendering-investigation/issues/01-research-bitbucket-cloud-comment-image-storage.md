# 01: Research Bitbucket Cloud Comment image storage

Status: resolved
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

- [x] `research/bitbucket-comment-images.md` answers Q1 to Q4, each with a source and a confidence mark.
- [x] The note gives a Bitbucket host list with exact hosts and no wildcard.
- [x] The note says, for each redirect host, whether Bitbucket controls it.
- [x] The note has a checklist for ticket 04 with one check for each open answer.
- [x] The note holds no real image URL, no Comment text, and no Credential value.
- [x] The note names every spec choice that its answers change, or states that none changes.
- [x] `python3 tools/check_agent_docs.py` passes.

## Completion

The research note is [bitbucket-comment-images.md](../research/bitbucket-comment-images.md).

- Q1 is `reported`. A pasted image becomes a `https://bitbucket.org/repo/<hash>/images/<n>-<file>` reference in `content.raw`.
- Q2 is `reported`. Reports say that an app password or OAuth does not open the image in a private Repository. No source tests an API token. Only a browser session cookie works.
- Q2 also finds a redirect to a signed Amazon S3 URL that expires. The authored URL does not expire.
- Q3 is `unknown` for the relative base. A Comment has no attachment form (`reported`).
- Q4 keeps exactly `api.bitbucket.org` and `bitbucket.org`. The image path never sends the Credential to `api.bitbucket.org`, and sends it to `bitbucket.org` only for `/repo/<segment>/images/<segment>`.
- Spec choice 5 changes. The prototype allows the storage host `bbuseruploads.s3.amazonaws.com` only directly after a `bitbucket.org` hop, and never sends it the Credential.
- Spec choice 3 keeps its two hosts. Ticket 05 drops `bitbucket.org` if ticket 04 shows that the Credential has no effect there.
- The note holds the checks C1 to C10 for ticket 04, with the exact requests for the human. No agent sent these requests.

Checks: `python3 tools/check_agent_docs.py` passes.
Review: the runner read the note and its prototype consequences.

## Comments

On 2026-11-02, the M32 review fix run corrected the Q2 line (M32I-7).
The earlier line said that the Credential does not open the image.
The reports test only app passwords and OAuth, and the bbr Credential is an API token.
The run also added the image path rule to the Q4 line (M32I-3).
