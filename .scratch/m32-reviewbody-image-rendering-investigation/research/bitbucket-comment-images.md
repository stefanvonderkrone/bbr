# Bitbucket Cloud Comment image storage

Research date: 2026-10-31.
Ticket: [01 Research Bitbucket Cloud Comment image storage](../issues/01-research-bitbucket-cloud-comment-image-storage.md).
Spec: [M32 spec](../SPEC.md).
Earlier research: [Cloud Markdown compatibility](../../m23-comment-thread-markdown-presentation-fixes/research/cloud-markdown-compatibility.md).

This note answers the questions Q1 to Q4 of the spec from public sources.
The research sent no request to Bitbucket with a Credential and read no Credential.
Every URL in an example is synthetic.
The note holds no real image URL and no Comment text.

## Summary

| Id | Answer | Mark |
| --- | --- | --- |
| Q1 | A pasted image becomes a Markdown image with an absolute URL of the form `https://bitbucket.org/repo/{repohash}/images/{number}-{filename}`. | `reported` |
| Q2 | The image URL follows the Repository permissions. The Credential does not open it. It redirects to Amazon S3 with a signed URL that expires. | `reported` |
| Q3 | No source gives the base of a relative image reference. A Comment has no attachment form. Attachments exist only on the PullRequest. | `unknown` for the base, `reported` for attachments |
| Q4 | The Bitbucket host list is exactly `api.bitbucket.org` and `bitbucket.org`. | `documented` for ownership, `reported` for the need |

The marks have these meanings:

| Mark | Meaning |
| --- | --- |
| `documented` | An Atlassian document, the Cloud OpenAPI definition, or an Atlassian product blog states the fact. |
| `reported` | A public Jira issue, a community answer, or a public client project reports the fact. No Atlassian document states it. |
| `unknown` | The sources that this research read do not settle the fact. |

The most important finding is in Q2.
Users and one Atlassian support engineer report that an app password cannot open a pasted image URL in a private Repository.
No source reports a test with an API token.
Only a browser session cookie opens it. [S3][S4][S6][S7][S8]
bbr has no session cookie and must not ask for one.
So bbr can probably show a pasted image only from a public Repository.
Ticket 04 must confirm this on a real PullRequest before ticket 05 decides.

## Q1: URL form of a pasted image

**Answer.**
The web editor uploads the image and writes a Markdown image into the Comment.
The destination is an absolute URL on `bitbucket.org`.
The path starts with `/repo/`, then a short Repository hash, then a folder, then a file name.
For pasted images, the folder is `images`.
The file name is a number, a hyphen, and the original file name.

This is a synthetic example of `content.raw`:

```markdown
![example.png](https://bitbucket.org/repo/Ab12Cd3/images/1234567890-example.png)
```

**Mark.** `reported`.
The 2014 Atlassian blog documents the mechanism.
The editor uploads the image and inserts the link into the markup. [S2]
An Atlassian knowledge base article documents the path form `https://bitbucket.org/repo/{repohash}/{folder}/{filename.extension}`.
That article is about the issue tracker, not about PullRequest Comments. [S1]
Three public reports show the same form for PullRequest descriptions and Comments. [S3][S4][S10]
A GitLab importer change uses the prefix `https://bitbucket.org/repo/` to find Bitbucket images in PullRequest text. [S11]

**Limits.**

- No source shows a capture of `content.raw` and `content.html` for one pasted image.
  So the research does not know if `content.html` holds the same URL.
- The current PullRequest editor has a WYSIWYG mode with an "Image, video, or file" action. [S21]
  No source says if that action writes the same `/repo/` URL or uses Atlassian Media.
  This is `unknown`.
- The Repository hash is not the Repository slug or UUID.
  No source documents how to compute it.

## Q2: Credential, redirects, and expiry

### Does the URL need authentication?

**Answer.**
An image in a private Repository needs authentication.
An image in a public Repository needs none.

**Mark.** `documented` for the rule, `reported` for public access.
The 2014 blog states that uploaded images use the security settings of their Repository. [S2]
A GitLab maintainer reports that the URLs are public for public Repositories and need authentication for private ones. [S10]

### Does the Credential open the URL?

**Answer.**
Probably not.
The reports agree that only a browser session cookie opens a private image.

**Mark.** `reported`.
The evidence is:

- BCLOUD-18906 reports that a token request gets `403` with "This endpoint does not support token-based authentication". [S6]
  It also reports a `302` redirect that needs a "Session" credential.
  Atlassian closed the suggestion as "Won't Fix".
- An Atlassian support engineer tested app password authentication on these URLs. [S7]
  The engineer found no quick fix and named the cookie as the only workaround.
  The engineer also said that Atlassian does not support the cookie method.
- A user reports a "permission denied" error with an app password on a PullRequest image URL. [S3]
- A public export script reports `401` for an app password on `/repo/` image URLs. [S8]
- An Atlassian community answer states that the REST API cannot fetch images in a PullRequest Comment. [S4]
  The related suggestion BCLOUD-22105 is still open with the status "Gathering Interest". [S5]

The REST documentation supports the same result from another side.
It states that an API token cannot log in to the Bitbucket website. [S16]
It states that all REST requests start with `https://api.bitbucket.org/2.0`. [S16]
The Cloud OpenAPI definition has no path that returns a Comment image. [S17]

The bbr Credential is an Atlassian account email and an API token for HTTP Basic auth.
No source reports a test with an API token.
The REST docs mark app passwords as deprecated and name API tokens as their replacement. [S16]
So ticket 04 must test the API token itself.

### Does the URL redirect, and to which host?

**Answer.**
A browser request to a `/repo/` image URL redirects to Amazon S3.
For Repository Downloads, the S3 host is `bbuseruploads.s3.amazonaws.com`.
No source names the S3 host for Comment images.
A request without a valid session can also redirect to a sign-in page.

**Mark.** `reported` for the redirect to S3, `unknown` for the exact image host.
A user reports a redirect to "an amazon s3 storage" when they open a `/repo/` image in the browser. [S7]
BCLOUD-12613 shows a `302` from a `bitbucket.org` Downloads URL to `bbuseruploads.s3.amazonaws.com`. [S12]
The GitLab import documentation names `bitbucket.org` and `bbuseruploads.s3.amazonaws.com` as the hosts of PullRequest images and attachments. [S13]
BCLOUD-22403 reports that PullRequest attachment images go to AWS S3. [S14]
BCLOUD-18906 reports the `302` to a session sign-in. [S6]
The export script treats a redirect to `id.atlassian.com` or `auth.atlassian.com` as a failed sign-in. [S8]

The sources disagree on one point.
The GitLab implementation plan says that Bitbucket serves the image directly with no S3 hop. [S10]
The other sources report an S3 hop.
Ticket 04 settles it.

This is a synthetic example of the reported chain:

```text
1. GET https://bitbucket.org/repo/Ab12Cd3/images/1234567890-example.png
   302 Location: https://bbuseruploads.s3.amazonaws.com/<uuid>/<path>/example.png?Signature=<sig>&Expires=<epoch>&AWSAccessKeyId=<key>
2. GET https://bbuseruploads.s3.amazonaws.com/<uuid>/<path>/example.png?Signature=<sig>&Expires=<epoch>&AWSAccessKeyId=<key>
   200 image/png
```

### Does a URL expire?

**Answer.**
The authored `/repo/` URL does not expire.
It stops working when someone deletes the Repository or makes it private.
The signed S3 URL expires.

**Mark.** `reported`.
A GitLab maintainer reports that the authored URLs do not expire. [S10]
The knowledge base article says that an image can disappear when its Repository is removed. [S1]
The S3 URL in BCLOUD-12613 holds `Signature` and `Expires` query parameters. [S12]
That example is a Download, not a Comment image.

So bbr must never keep a signed S3 URL.
Each acquisition starts again from the authored URL in `content.raw`.

### Storage and redirect hosts

The external-load rule needs to know if Bitbucket controls each host in a chain.

| Host | Role | Bitbucket controls it | Mark | Evidence |
| --- | --- | --- | --- | --- |
| `bitbucket.org` | Serves the authored image URL. | Yes. Atlassian operates `*.bitbucket.org`. | `documented` | [S15][S18] |
| `api.bitbucket.org` | REST API. Not in the image chain. | Yes. | `documented` | [S16][S18] |
| `bbuseruploads.s3.amazonaws.com` | S3 bucket behind Bitbucket uploads and Downloads. | Bitbucket controls the bucket and signs the URL. Amazon operates the host. | `reported` | [S12][S13][S14] |
| `id.atlassian.com`, `auth.atlassian.com` | Sign-in redirect for a missing session. | Atlassian controls them. They are not Bitbucket image storage. | `reported` | [S6][S8][S15] |
| `api.media.atlassian.com` | Atlassian Media upload host. Possibly used by PullRequest attachments. | Atlassian controls it. No source shows it in a Comment image chain. | `unknown` | [S15][S19] |
| `*.atl-paas.net` hosts, such as the avatar host | Atlassian platform assets. | Atlassian controls them. No source shows them in a Comment image chain. | `unknown` | [S15] |

The Atlassian domain list names `*.bitbucket.org`, `*.atlassian.com`, and `*.atl-paas.net` as first-party domains.
It states that Atlassian operates and manages these domains directly. [S15]
The list does not name `bbuseruploads.s3.amazonaws.com`.
So its control by Bitbucket is `reported`, not `documented`.
The bucket name and the signed redirects from `bitbucket.org` are strong signs. [S12]

## Q3: Relative references and attachments

### The base of a relative image reference

**Answer.**
No source states the base of a relative image reference in a Comment.

**Mark.** `unknown`.
The M23 note lists relative image bases as unresolved for Cloud Comments.
The Cloud docs give no Comment-specific URL base.
The README docs describe a different context, so their behavior does not transfer.

A browser resolves a relative `src` against the URL of the page that shows it.
For a Comment, that page is a PullRequest page on `bitbucket.org`.
This is an inference, not a Bitbucket fact.
It also depends on whether `content.html` keeps the relative destination.

Spec choice 13 holds.
bbr shows the fallback text for a relative reference.

### Is there an attachment form for Comments?

**Answer.**
No.
A Comment can only hold a Markdown image link.
A PullRequest can hold attachments, but only through the browser.

**Mark.** `documented` for PullRequest attachments, `reported` for the absence in Comments.
The 2020 Atlassian blog announces PullRequest attachments through the Atlassian Media Picker. [S19]
It says that a public API for PullRequest attachments "is on the way".
An Atlassian support engineer states that Comments cannot hold attachments. [S20]
The engineer also states that the attachment API suggestion BCLOUD-21023 is closed.
The Cloud OpenAPI definition has no path for attachments or for Comment images. [S17]

PullRequest attachments are not part of a ReviewBody.
So M32 does not cover them.

## Q4: Bitbucket host list

The Bitbucket host list holds exact host names.
It holds no wildcard and no suffix rule.
The image path has its own rule, which is stricter than the host list.

| Host | Reason it may get the Credential | Mark |
| --- | --- | --- |
| `api.bitbucket.org` | Every REST request goes to this host. The Credential exists for these requests. The image path never sends the Credential to this host, because the host is not in the image chain. | `documented` [S16] |
| `bitbucket.org` | It serves the authored image URL. Atlassian operates it. The image path sends the Credential here only for the path `/repo/<segment>/images/<segment>`, and only if ticket 04 shows that the Credential has an effect. | `documented` for ownership [S15][S18], `reported` for no effect [S6][S7] |

A Comment author chooses the image URL.
So a rule that sends the Credential to any path on a Bitbucket host lets the author choose an authenticated request.
The image path rule allows only the path form of a pasted image, with no query and no deeper segment.

These hosts must never get the Credential:

| Host | Reason |
| --- | --- |
| `bbuseruploads.s3.amazonaws.com` | A signed URL needs no Credential. Amazon operates the host. |
| `id.atlassian.com`, `auth.atlassian.com` | They are sign-in pages, not image storage. |
| `api.media.atlassian.com` | No source shows it in a Comment image chain. |
| `altssh.bitbucket.org` | It serves SSH only. [S18] |
| Every other host | The spec allows no host without evidence. |

`bitbucket.org` is on the list only for the first hop of an image request, and only for the image path form.
The reports say that an app password or OAuth does not open a private image there. No source tests an API token.
If ticket 04 shows that the Credential has no effect, ticket 05 removes the image path from the rule.
Then an image request never carries the Credential.

## Spec choices that the answers change

The spec section "Choices this spec records" has 13 choices.
The answers change one choice and add a condition to another.

- Choice 5 changes.
  The spec allows a storage host as a Bitbucket redirect target only when ticket 01 shows that Bitbucket controls it.
  The evidence for `bbuseruploads.s3.amazonaws.com` is `reported`, not `documented`.
  The prototype still needs the hop, or no Bitbucket image can load with `allow_external` set to `false`.
  So the prototype allows this one exact host as a provisional exception.
  It allows the host only as the target of a redirect from `bitbucket.org`.
  It never sends the Credential to it.
  Ticket 04 confirms the host, or ticket 05 removes the exception.
- Choice 3 keeps its hosts for the API, but the image path gets a stricter rule.
  The image path never sends the Credential to `api.bitbucket.org`.
  It sends the Credential to `bitbucket.org` only for `/repo/<segment>/images/<segment>`.
  If ticket 04 shows that the Credential has no effect there, ticket 05 removes that exception too.

These choices do not change: 1, 2, 4, 6, 7, 8, 9, 10, 11, 12, and 13.
Choice 6 matches the findings, because a LocalReview has no Credential.
Choice 13 holds, because the relative base is `unknown`.

The findings also give ticket 05 a new input.
If ticket 04 confirms the Q2 result, bbr cannot show an image from a private Repository.
A Repository in a company Workspace is usually private. This is a guess.
So the value of an inline image depends on that check.

## Consequences for the prototype

- **Host list.**
  On the image path, the only Credential target is `https://bitbucket.org/repo/<segment>/images/<segment>`.
  `api.bitbucket.org` never gets the Credential on the image path.
  The only storage host is exactly `bbuseruploads.s3.amazonaws.com`, and only directly after a `bitbucket.org` hop.
  Every other host is external.
- **Credential on the first hop.**
  In a RemoteReview, the prototype sends the Credential on the first hop to `bitbucket.org` over `https`, only for the image path form.
  Every other Bitbucket URL on the image path sends no request.
  The host is first-party, so the Credential reaches no third party.
  Ticket 04 needs the response to this request.
  The prototype never sends the Credential on a later hop to another host.
  In a LocalReview, the prototype sends no Credential.
- **Redirect behavior.**
  The prototype follows each redirect itself, with at most three hops.
  It applies the host rule at each hop.
  It follows only `https` targets.
  A redirect to a sign-in host, such as `id.atlassian.com`, ends the acquisition with the `failed` state.
  The prototype does not follow it.
  The prototype never keeps a signed URL. Each acquisition starts from the authored URL.
- **Relative-reference base.**
  The prototype uses no base.
  It shows the fallback text for a relative reference.
  It never resolves a relative reference against `bitbucket.org`.
- **Session cookie.**
  The prototype never reads, asks for, or stores a browser session cookie.

## Checklist for ticket 04

Each check covers one `reported` or `unknown` answer.
A human runs the checks on a real PullRequest with a pasted screenshot.
The human records only status codes, host names, and yes or no results.
The human never records a URL path, a query string, Comment text, or a Credential value.

The requests below use synthetic placeholders.
The `sed` filter removes everything after the host name, so the signed query never reaches the terminal log.

| Id | Question | Check | Expected from the reports |
| --- | --- | --- | --- |
| C1 | Q1 URL form | Read `content.raw` of a Comment with a pasted image. Record the host and whether the path starts with `/repo/` and holds `/images/`. | `bitbucket.org`, yes, yes. |
| C2 | Q1 HTML | Read `content.html` of the same Comment. Record whether the `img` `src` equals the destination in `content.raw`. | Unknown. |
| C3 | Q1 editor | Paste one image with the plain paste and one with "Image, video, or file". Record the host of each destination. | Unknown. Possibly a different host for the second form. |
| C4 | Q2 Credential | Request the image with the Credential and no redirect. Record the status and the `Location` host. | `403`, or `302` to a sign-in host. |
| C5 | Q2 private, no Credential | Request the same image without the Credential and no redirect. Record the status and the `Location` host. | `302` to a sign-in host, or `401` or `403`. |
| C6 | Q2 public | Repeat C5 on a public Repository with a pasted image, if one is available. Record each hop host. | `302` to an S3 host, then `200`. |
| C7 | Q2 storage host | From C4, C5, or C6, record the exact S3 host name. | `bbuseruploads.s3.amazonaws.com`. |
| C8 | Q2 hop count | Record the number of hops until `200` or a failure. | Two hops. |
| C9 | Q2 expiry | Record whether the S3 `Location` query has an expiry parameter, and the lifetime in seconds. Retry the S3 URL after the lifetime and record the status. | An expiry parameter, then `403` after the lifetime. |
| C10 | Q3 relative base | Only with a test Comment that the human may write: post `![a](images/a.png)` on a test PullRequest. Record the `src` in `content.html` and the URL path form that the web UI requests. | Unknown. |

These are the exact requests for C4 and C5.
Only the human runs them.
The agent never runs them, because they use the operator's Credential.

```sh
IMAGE='https://bitbucket.org/repo/<repohash>/images/<number>-<file>'

# C4: with the Credential, no redirect.
# printf is a shell builtin, so the token never enters the argv of a process.
NETRC="$TMPDIR/m32-c4.netrc"
(umask 077 && printf 'machine bitbucket.org login %s password %s\n' \
  "$BITBUCKET_USERNAME" "$BITBUCKET_TOKEN" > "$NETRC")
curl -sS -o /dev/null --max-redirs 0 --netrc-file "$NETRC" \
  -w '%{http_code} %{redirect_url}\n' "$IMAGE" \
  | sed -E 's#(https://[^/ ]+)[^ ]*#\1#'
rm -f "$NETRC"

# C5: without the Credential, no redirect.
curl -sS -o /dev/null --max-redirs 0 \
  -w '%{http_code} %{redirect_url}\n' "$IMAGE" \
  | sed -E 's#(https://[^/ ]+)[^ ]*#\1#'
```

For C6 to C8, the human repeats C5 with `--max-redirs 0` on each `Location` in turn.
The human records only the host of each hop.
For C9, the human reads the query parameter names of the S3 `Location`, never their values.

## Sources

All sources below were read on 2026-10-31, except the M23 note.

- [S1] [Issue tracker images not loading](https://support.atlassian.com/bitbucket-cloud/kb/issue-tracker-images-not-loading/). Atlassian knowledge base. The `/repo/{repohash}/{folder}/{filename}` form and Repository removal.
- [S2] [New direct image uploads for Bitbucket](https://www.atlassian.com/blog/bitbucket/new-direct-image-uploads-for-bitbucket). Atlassian blog, 2014. Upload, link insertion, and image privacy.
- [S3] [How to access PR description images from script?](https://community.atlassian.com/forums/Bitbucket-questions/How-to-access-PR-description-images-from-script/qaq-p/1058056). Atlassian community, 2019. App password gets "permission denied".
- [S4] [Access Images in Bitbucket pull request description via API?](https://community.atlassian.com/forums/discussion/2111299/access-images-in-bitbucket-pull-request-description-via-api). Atlassian community, 2022. Session authentication and no REST access.
- [S5] [BCLOUD-22105](https://jira.atlassian.com/browse/BCLOUD-22105). Suggestion to fetch PullRequest images through the REST API. Unresolved, "Gathering Interest".
- [S6] [BCLOUD-18906](https://jira.atlassian.com/browse/BCLOUD-18906). Token requests get `403`. A `302` needs a session. Closed as "Won't Fix".
- [S7] [Bitbucket export: process inline images](https://community.atlassian.com/forums/discussion/2137389/bitbucket-export-process-inline-images). Atlassian community, 2022. Redirect to Amazon S3. Atlassian support finds no app password access and does not support the cookie method.
- [S8] [Fetch Atlassian hosted inline images for exported Bitbucket Issues](https://gist.github.com/tempelmann/781d2752031970fcbd988ad3f23e1469). Public script, 2026. App passwords get `401`. Sign-in hosts. Credential removal on a host change.
- [S10] [GitLab issue 354807](https://gitlab.com/gitlab-org/gitlab/-/issues/354807). Bitbucket Cloud importer for Markdown images. The public notes were read through the public GitLab GraphQL API. Public access, expiry, and the S3 disagreement.
- [S11] [GitLab `markdown/attachment.rb`](https://gitlab.com/gitlab-org/gitlab/-/raw/master/lib/gitlab/bitbucket_import/markdown/attachment.rb). The `BITBUCKET_MEDIA_HOSTS` prefixes and their cited sources.
- [S12] [BCLOUD-12613](https://jira.atlassian.com/browse/BCLOUD-12613). A `302` from a Downloads URL to a signed `bbuseruploads.s3.amazonaws.com` URL with `Expires`.
- [S13] [GitLab: Migrate from Bitbucket Cloud](https://docs.gitlab.com/user/import/bitbucket_cloud/). Names `bitbucket.org` and `bbuseruploads.s3.amazonaws.com` as image and attachment hosts.
- [S14] [BCLOUD-22403](https://jira.atlassian.com/browse/BCLOUD-22403). PullRequest attachment images go to AWS S3.
- [S15] [Atlassian cloud IP ranges and domains](https://support.atlassian.com/organization-administration/docs/ip-addresses-and-domains-for-atlassian-cloud-products/). First-party domains, including `*.bitbucket.org`, `*.atlassian.com`, and `*.atl-paas.net`. `api.media.atlassian.com` for attachment uploads.
- [S16] [The Bitbucket Cloud REST API](https://developer.atlassian.com/cloud/bitbucket/rest/intro/). The `api.bitbucket.org` prefix, Basic auth with an API token, and no website login with a token.
- [S17] [Cloud OpenAPI definition](https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json). No path for attachments or Comment images.
- [S18] [Bitbucket Cloud IP addresses and domains](https://support.atlassian.com/bitbucket-cloud/docs/what-are-the-bitbucket-cloud-ip-addresses-i-should-use-to-configure-my-corporate-firewall/). `bitbucket.org`, `api.bitbucket.org`, and `altssh.bitbucket.org`.
- [S19] [Add file attachments to pull requests in Bitbucket Cloud](https://www.atlassian.com/blog/bitbucket/pr-attachments). Atlassian blog, 2020. PullRequest attachments through the Atlassian Media Picker.
- [S20] [How to enclose file to pull request comment via REST API](https://community.atlassian.com/forums/discussion/2149036/how-to-enclose-file-to-pull-request-comment-via-rest-api-in-bitbucket-cloud/p1). Atlassian community, 2022. No attachments in Comments. BCLOUD-21023 closed.
- [S21] [BCLOUD-23721](https://jira.atlassian.com/browse/BCLOUD-23721). The WYSIWYG "Image, video, or file" action in PullRequest Comments.
