# M32 ReviewBody image rendering investigation

Status: ready-for-agent
Milestone: M32

The [M32 brief](brief.md) records the approved decisions.
This spec turns the brief and the M32 section of [TODO.md](../../TODO.md) into a research plan.
The tickets live in [issues](issues/).
The M23 Markdown research is in [Cloud Markdown compatibility](../m23-comment-thread-markdown-presentation-fixes/research/cloud-markdown-compatibility.md).

## Problem Statement

Reviewers paste screenshots into Comments.
A screenshot shows a UI bug, a layout problem, or an expected result.
M23 shows an image reference in a ReviewCard only as text.
The text is the label `image: `, the alternative text, and the authored destination.
The reviewer must open a browser to see the image.

Nobody knows if bbr can show these images in the terminal well enough to help the reviewer.
Nobody knows how bbr can get the images without a leak of the Credential or of the reviewer's IP address.
Nobody knows what each target terminal and multiplexer does with image output in a ReviewCard.

## Solution

M32 makes a recorded decision, not a feature.

1. Ticket 01 finds out how Bitbucket Cloud stores pasted Comment images.
2. Ticket 02 fills the protocol matrix from specifications and source code, and defines the multiplexer detection rule.
3. Ticket 03 builds a throwaway prototype on a branch that never merges.
4. A human runs the prototype in each target terminal and on a real PullRequest.
5. A human compares an inline image with a separate image preview and selects the behavior.
6. Ticket 06 records the decision in an ADR and adds the implementation milestone to `TODO.md`.

A later milestone implements the selected behavior.
M32 changes no production code on the M32 branch.

## User Stories

1. As a reviewer, I want to see a pasted screenshot in bbr, so that I do not open a browser.
2. As a reviewer, I want bbr to send my Credential only to Bitbucket hosts, so that it stays safe.
3. As a reviewer, I want external image loads only when I allow them, so that a tracking pixel fails.
4. As a reviewer, I want a clear text fallback without an image protocol, so that I know about the image.
5. As a reviewer, I want images to stay in place on a scroll, so that no stale image covers text.
6. As a reviewer, I want images to work inside tmux and herdr, so that I can keep my multiplexer.
7. As a reviewer, I want an image to fit the ReviewCard, so that I can read it.
8. As a reviewer, I want image loads to never block navigation, so that a slow host does not freeze bbr.
9. As a maintainer, I want limits on size and type, so that a hostile image cannot exhaust memory.
10. As a maintainer, I want the decision to rest on evidence from each target terminal, so that it holds later.

## Current behavior

These code paths decide the current behavior.
M32 reads them and does not change them on the M32 branch.

| Concern | Owner |
| --- | --- |
| Image reference parsing | `parseInline` in `src/tui/review_body.zig`. A `![` span adds the generated span `image: ` before the label. The destination span has `marks.link_destination` and a `LinkTarget`. |
| Image reference projection | `src/tui/review_card.zig` wraps the text as `image: diagram ‹destination› "title"`. |
| ReviewCard paint | `drawReviewCard` in `src/tui/render.zig` maps each `review_card.Part` to cells. No Part holds an image. |
| ReviewCard row budget | `[comments] collapsed_rows` in `src/tui/config.zig`. The default is `Configuration.default_comments_collapsed_rows`, 6 rows. |
| Terminal adapter | `src/tui/app.zig` creates vaxis with `vaxis.init` and paints with `vx.render`. |
| vaxis | Version 0.6.0 at commit `ca781b3`, from `build.zig.zon`. It depends on `zigimg` for decoding. |
| vaxis image API | `Vaxis.loadImage`, `transmitImage`, `transmitPreEncodedImage`, `transmitLocalImagePath`, and `freeImage` send the kitty graphics protocol. `Image.draw` places an image in a `Window` with the scale modes `none`, `fill`, `fit`, and `contain`. `Cell.image` holds a placement. |
| HTTP seam | `HttpClient` in `src/http/client.zig`. `Response` holds the status and the body, but no headers. Production uses `StdHttpClient`. Tests use `FakeHttpClient`. |
| Credential header | `Credential.basicAuthHeader` in `src/bitbucket/`. `src/bitbucket/client.zig` adds it to each request to `https://api.bitbucket.org/2.0`. |
| Configuration | `src/tui/config.zig` reads `config.toml`. It knows the tables `[keymap]`, `[highlight]`, `[files.cache]`, `[comments]`, `[input.mouse]`, and `[external_edit]`. |

### Findings that the prototype must respect

The spec author found these facts in the code.
They are not decisions.

- bbr never calls `Vaxis.queryTerminal` or `enableDetectedFeatures`.
  So `vx.caps.kitty_graphics` stays false, and every vaxis image call returns `error.NoGraphicsCapability`.
  `queryTerminal` also turns on other detected features, such as the kitty keyboard protocol.
  The prototype records each side effect.
- vaxis 0.6.0 has no iTerm2 inline image protocol, no Sixel, and no tmux passthrough.
  vaxis 0.6.0 has no kitty Unicode placeholder support.
- `StdHttpClient.send` passes every request header as a `std.http` `extra_headers` entry.
  It follows up to three redirects for a request without a body.
  `std.http.Client` keeps `extra_headers` on a redirect to another domain.
  It strips only `privileged_headers`.
  So a request with the Credential that gets a redirect to another host sends the Credential to that host.
  The image path must not use this behavior.
  Ticket 06 also records this finding for the existing API requests.
- `StdHttpClient.send` reads the whole response body with no size limit.
  The image path needs a byte limit while it reads.

## Research questions

Each question names the ticket that answers it.

| Id | Question | Ticket |
| --- | --- | --- |
| Q1 | How does Bitbucket Cloud store an image that a user pastes into a Comment? What URL does `content.raw` hold? | 01, 04 |
| Q2 | Does a pasted image URL need the Credential? Does it redirect, and to which host? Does the final URL expire? | 01, 04 |
| Q3 | What do `content.html` and the web UI do with a relative image reference? Is there a Bitbucket attachment form for Comments? | 01 |
| Q4 | Which hosts are Bitbucket hosts for the Credential host rule? | 01 |
| Q5 | Which image protocol does each target terminal support, and which protocol features? | 02, 04 |
| Q6 | How does bbr detect tmux, herdr, and the outer terminal from the environment and from terminal replies? | 02, 04 |
| Q7 | What does it cost to add the iTerm2 protocol and tmux passthrough to the vaxis path? | 02, 03 |
| Q8 | How long does image acquisition take, and how long does decoding take? | 03, 04 |
| Q9 | How much memory and how many output bytes does one image cost? | 03, 04 |
| Q10 | What size, aspect ratio, and row count make an inline image readable in a ReviewCard? | 04, 05 |
| Q11 | How does an inline image behave with Reply indentation, the ReviewCard disclosure, scrolling, resize, and Overlays? | 04, 05 |
| Q12 | Does the reviewer prefer an inline image or a separate image preview? | 05 |
| Q13 | How long does bbr keep an image, and when does it free the image in the terminal? | 03, 05 |
| Q14 | What text does the reviewer see when bbr cannot show an image? | 03, 05 |

## Protocol matrix

Ticket 02 fills each cell from specifications and source code, with a source for each cell.
Ticket 04 confirms or corrects each cell in a hands-on run.
A cell holds `yes`, `no`, `partial`, or `unknown`, and a note.

| Row | Ghostty | kitty | WezTerm | iTerm2 | tmux in Ghostty | tmux in iTerm2 | herdr in Ghostty | herdr in kitty | No protocol (Apple Terminal) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Tested version | | | | | | | | | |
| kitty graphics protocol | | | | | | | | | |
| kitty transmission by direct data (`t=d`) | | | | | | | | | |
| kitty transmission by file or temp file (`t=f`, `t=t`) | | | | | | | | | |
| kitty PNG payload (`f=100`) | | | | | | | | | |
| kitty Unicode placeholders (`U=1`) | | | | | | | | | |
| kitty delete by id (`a=d,d=I`) | | | | | | | | | |
| kitty capability query reply | | | | | | | | | |
| iTerm2 inline image protocol (OSC 1337) | | | | | | | | | |
| Cell pixel size from the window size | | | | | | | | | |
| Image stays correct after a scroll | | | | | | | | | |
| Image stays correct after a resize | | | | | | | | | |
| No stale image copy after an Overlay closes | | | | | | | | | |
| Passthrough setting needed | | | | | | | | | |
| Environment values that identify it | | | | | | | | | |
| vaxis 0.6.0 path works without change | | | | | | | | | |
| Selected path for the prototype | | | | | | | | | |

The "No protocol" column also covers every terminal that bbr cannot identify.
Ticket 04 adds one column for each other kitty-protocol terminal that the human uses for the herdr test.
Sixel is not a target.
Ticket 02 records Sixel support only as a note.

### Multiplexer detection rule

A multiplexer can pass on the outer terminal's `TERM_PROGRAM`.
So `TERM_PROGRAM` alone does not identify the terminal that receives bbr's output.

Ticket 02 defines one detection rule for each multiplexer and for the nested cases.
The rule starts from these facts and checks each one.

- herdr sets `HERDR_ENV=1`.
  herdr renders the kitty graphics protocol itself when `terminal.kitty_graphics` is on, and the setting is on by default.
  herdr has no tmux-style passthrough.
- tmux sets `TMUX`, and recent versions set `TERM_PROGRAM=tmux`.
  tmux forwards an image sequence only through passthrough with `allow-passthrough on`.
- The rule covers tmux inside herdr and herdr inside tmux.
- The rule states the order of the checks: environment first, then the terminal reply to a capability query.
- The rule states the result when the checks disagree.
- The rule never reads a variable that `src/xdg.zig` owns.

## Fixed image set

Ticket 03 generates the synthetic images with a script, so the set holds no customer data.
The human run uses the same files in every terminal.

| Id | Image | Purpose |
| --- | --- | --- |
| I1 | PNG screenshot, 800 x 500 px | The common case. |
| I2 | PNG Retina screenshot, 3024 x 1964 px | A large common case. |
| I3 | JPEG photo, 4000 x 3000 px | Decode time for a large JPEG. |
| I4 | PNG, 600 x 6000 px | A tall page screenshot. Tests the row limit. |
| I5 | PNG, 6000 x 400 px | A wide image. Tests the width fit. |
| I6 | PNG with alpha, 800 x 500 px | Transparency over the Theme base background. |
| I7 | Animated GIF, 400 x 300 px, 10 frames | Only the first frame shows. |
| I8 | PNG icon, 16 x 16 px | No upscale above the native size. |
| I9 | Truncated PNG | Decoder failure. |
| I10 | PNG header with 100,000 x 100,000 px | Decompression bomb. Rejected before decode. |
| I11 | SVG file | Unsupported type. |
| I12 | PNG above the byte limit | Download limit. |
| I13 | I1 on an external test host | External-load config key, both values. |
| I14 | A relative reference such as `images/a.png` | Relative reference behavior. |
| I15 | A real pasted screenshot on a Bitbucket PullRequest | Bitbucket storage and the Credential host rule. Used only in ticket 04. |

I1 to I12 load from local files through the prototype fixture mode, so the terminal runs need no network.
I13 needs a local or test HTTP server that the human controls.
I15 is the only network case against Bitbucket.

## ReviewCard situations

The prototype opens one fixture Review that holds every situation.
Each situation uses images from the fixed image set.

| Id | Situation | What to check |
| --- | --- | --- |
| R1 | One image in a root Comment. | Size, aspect ratio, and position in the card. |
| R2 | Several images in one Comment, with prose between them. | Order, spacing, and the row count. |
| R3 | A long Thread with 12 Replies, each with one image. | Output bytes and frame time while the cursor moves. |
| R4 | Nested Replies at depth 1, 3, and the deepest indent. | Width at each Reply indentation. The rails and the Anchor Indicator stay visible. |
| R5 | A collapsed disclosure with an image below the row budget, then expanded. | The image hides and shows with the disclosure. No stale image stays. |
| R6 | A resolved Thread, collapsed and expanded. | No image shows while the Thread is hidden. |
| R7 | Scroll so that an image is partly above the top and partly below the bottom of the DiffPane. | Clipping, and no image over the status or a Pane border. |
| R8 | Resize: narrow, wide, short, and tall, while an image shows. | New size, new position, and no stale copy. |
| R9 | An Overlay over an image: the help Overlay, the Composer, a List Overlay, and the herdr popup. | The Overlay covers the image, and the image returns after close. |
| R10 | Selection and yank over a ReviewCard with an image. | The clipboard gets the M23 text, not image data. |
| R11 | A File Jump away and back, and a Session replacement through `refresh`. | The image frees and returns. No stale copy. |
| R12 | Review Search and Buffer Search over the image alternative text. | The Search Occurrence still maps to the authored text. |

## Variants to compare

The prototype builds two variants.
A runtime switch selects the variant, so one build serves the whole run.

- Variant A, inline image: the ReviewCard shows the image in its body rows, below the M23 image text.
  The image takes the card content width and at most a maximum number of rows.
  The image rows count toward the ReviewCard row budget.
- Variant B, image preview: the ReviewCard shows only the M23 image text.
  An Action on the image text opens an image preview Overlay.
  The Overlay shows the image at the largest size that fits, and Escape closes it.
  The Overlay follows the Overlay border and background rules in `AGENTS.md`.

The prototype starts with these sizing values.
Ticket 04 can change them during the run and records the values that it used.

- The maximum inline height is 12 rows.
- The image never scales above its native pixel size.
- The aspect ratio uses the cell pixel size from the terminal window size.
  When the terminal reports no pixel size, the prototype assumes a cell twice as high as wide and records it.

## Prototype

### Where it lives

The prototype lives on the branch `m32-image-prototype`.
Ticket 03 creates the branch from the M32 branch in its own Worktree.
The branch never merges.
The M32 branch keeps only the tracker files, the research notes, the evidence, and the ADR.
Ticket 03 records the branch name and the final prototype commit under `## Completion`.
The branch stays until the implementation milestone resolves, so the evidence stays reproducible.

### Scope

The prototype changes the real bbr code on its branch.
The ReviewCard situations need the real Buffer and the real paint path.
It must contain:

- The kitty graphics path through the vaxis 0.6.0 API, with capability detection.
- tmux passthrough for the kitty path, as a wrapper around the vaxis output.
- The iTerm2 inline image path, only as far as needed to measure its cost.
  When the path costs more than a small adapter, ticket 03 records the cost and stops.
- The multiplexer detection rule from ticket 02.
- Variant A and Variant B.
- The fixture mode: an image destination `fixture:I1` to `fixture:I12` loads the local file of that image.
- A fixture Review that holds the situations R1 to R12, set up by one command or script.
- The network path for I13 to I15, with the security rules below.
- The probe log from the "Measurements" section.

The prototype does not need:

- A configuration diagnostic or a help entry for its switches.
  Environment variables with the `BBR_M32_` prefix are enough.
- Production error messages or tests for every edge.
  It needs only the tests in the "Prototype tests" section.

### Measurements

The prototype writes one `key=value` line for each event to the probe log.
The path comes from `BBR_M32_PROBE_LOG`.
A line never holds a URL, a URL path, a query string, a header, Comment text, or a Credential value.
A line names an image only by its fixed image set id or by an ordinal.

| Event | Keys |
| --- | --- |
| Acquisition | `image`, `host_class` (`bitbucket`, `external`, `fixture`), `hops`, `status`, `bytes`, `latency_ms`, `credential_sent` |
| Decode | `image`, `type`, `width_px`, `height_px`, `header_ms`, `decode_ms`, `decoded_bytes`, `result` |
| Transmit | `image`, `protocol`, `medium`, `payload_bytes`, `output_bytes`, `transmit_ms` |
| Place | `image`, `rows`, `cols`, `output_bytes` |
| Frame | `frame`, `images_visible`, `output_bytes`, `paint_ms` |
| Free | `image`, `reason` (`scroll`, `disclosure`, `session`, `limit`), `output_bytes` |
| Memory | `retained_encoded_bytes`, `retained_decoded_bytes`, `peak_rss_bytes` |

Ticket 03 adds a `summarize` script that prints, for each image and terminal:

- The acquisition latency median and maximum.
- The decode time median and maximum.
- The peak retained memory and the peak RSS.
- The output bytes for the first transmit and for one placement.
- The output bytes and paint time for each frame of a 20-row scroll through R3.

### Prototype tests

The prototype adds tests whose names start with `M32 image`.
They run on `FakeHttpClient`, with no network and no Credential.

- A request to a Bitbucket host carries the Credential.
- A request to any other host never carries the Credential.
- A redirect from a Bitbucket host to another host drops the Credential at that hop.
- With the external-load key off, bbr sends no request to an external host.
- With the external-load key on, bbr sends the request without the Credential.
- A body above the byte limit stops the read and gives the `too_large` state.
- A type outside the allowed list gives the `unsupported` state.
- A header with dimensions above the limit gives the `too_large` state before decode.
- I9 and I10 give a failure state and no crash in a `ReleaseSafe` build.
- The probe log holds no URL, query string, Comment text, or Credential.
  Every input of the test holds a sentinel.

## Security rules

These rules hold in the prototype and in the later implementation.
The ADR from ticket 06 keeps them or tightens them.

### Credential host rule

- bbr sends the Credential only over `https`, and only to a host on the Bitbucket host list.
- The prototype starts with the exact hosts `bitbucket.org` and `api.bitbucket.org`.
- Ticket 01 can add a host only with a source that shows Bitbucket owns and needs it.
- A match is an exact host match. bbr never matches a suffix or a wildcard.
- The image path follows each redirect itself.
  It applies the host rule again at each hop.
  It allows at most three hops.
- A host that is not on the list never gets the Credential.
  This rule also holds for the target of a redirect from Bitbucket.
- In a LocalReview, bbr reads no Credential.
  So a Bitbucket-hosted image in a LocalReview loads without the Credential, or it shows the fallback text.

### External-load config key

- The key is `allow_external` in a new `[images]` table in `config.toml`.
- The default is `false`.
- With `false`, bbr sends no request to a host outside the Bitbucket host list.
  This includes a redirect target outside the list.
  A redirect from Bitbucket to a storage host can be an exception.
  It is not an external load when ticket 01 shows that Bitbucket controls the storage host.
  Ticket 01 records that evidence.
- With `true`, bbr loads the image without the Credential, over `https` only.
- The prototype reads the value from `BBR_M32_ALLOW_EXTERNAL`.
  The implementation milestone adds the key to `src/tui/config.zig`.

### Download limits

- bbr reads at most 10 MiB of response body for one image.
  It stops the read at the limit.
- bbr accepts only the status `200` as an image.
- bbr gets at most two images at a time.
  Image acquisition never delays Candidate Session acquisition or File Enrichment.
- An image acquisition never runs on the paint path.
  It runs as an owned command under ADR-0012, and its result passes the Session Epoch check.

### Type and decoder rules

- bbr finds the type from the magic bytes of the body.
  It does not trust the file extension.
  `HttpClient.Response` has no headers, so the `Content-Type` header is not available.
- The allowed types are PNG, JPEG, and GIF.
  For GIF, bbr shows only the first frame.
- bbr never decodes SVG, PDF, or HTML.
- bbr reads the width and height from the image header before it decodes.
  It rejects a side above 8192 px or a total above 33,177,600 px.
- The decoder runs in the bbr process.
  The prototype records whether a decode can block the event loop.
- The prototype compares two paths for PNG:
  decode with `zigimg` and send RGBA, or send the PNG bytes as `f=100` and let the terminal decode.
  The second path moves the decode risk to the terminal, and ticket 05 decides if that is acceptable.
- The prototype runs I9 and I10 in a `ReleaseSafe` build and records the result.

### Cache lifetime

- The prototype keeps images only in memory, for one Session.
- A Session replacement frees every image in memory and in the terminal.
- The prototype writes no image to disk.
  A kitty `t=t` temp file is the exception, and the terminal deletes it.
- The prototype frees a terminal image when its ReviewCard leaves the Buffer.
  It records the cost of a second transmit.
- The prototype records the retained memory with all images of the fixture Review loaded.

## Fallback text behavior

The fallback text is the M23 text: `image: `, the alternative text, the destination, and the title.
bbr shows it in every case where it cannot show the image.
The fallback never hides the destination, so the reviewer can copy it and open a browser.

The prototype adds a short state after the M23 text, to test with the human.

| State | Cause |
| --- | --- |
| `loading` | The acquisition or decode runs. |
| `blocked` | The host is external, and `allow_external` is `false`. |
| `failed` | The request failed, the status was not `200`, or the decode failed. |
| `too large` | The body or the dimensions exceed a limit. |
| `unsupported` | The type is not PNG, JPEG, or GIF. |
| (none) | The terminal has no image protocol. |

Ticket 05 decides if the state text stays and what words it uses.
In a terminal with no image protocol, bbr sends no image request.

## Decision document

Ticket 06 writes the ADR at the next free number in `docs/adr/`.
The M28 spec plans ADR-0014, so ticket 06 checks the number when it runs.
The ADR has these sections:

1. Context: the problem and a link to this spec.
2. Decision: inline image, image preview, both, or text fallback only.
3. Protocol support: the filled protocol matrix, or a link to it in ticket 04.
4. Detection: the multiplexer detection rule and the capability query.
5. Acquisition: the Bitbucket storage findings, the Credential host rule, the Bitbucket host list, the redirect rule, and the external-load key.
6. Limits: the byte limit, the type list, the dimension limit, the concurrency limit, and the memory budget.
7. Decoding: the selected decode path and the decoder safety evidence.
8. Presentation: sizing, aspect ratio, the maximum rows, Reply indentation, the ReviewCard disclosure, scrolling, resize, and Overlays.
9. Cache lifetime: when bbr keeps, frees, and transmits an image again.
10. Fallback text: the final text for each state.
11. Evidence: the measurements, the screenshot list, and links to tickets 04 and 05.
12. Consequences: the AGENTS.md rules to add, the glossary terms, the vaxis changes, and the cost of the iTerm2 path.
13. Reopen conditions: for example a new vaxis release or a new target terminal.

The ADR holds no URL of a real image, no Comment text, and no Credential value.

## Handoff to the implementation milestone

Ticket 06 adds a new milestone section to `TODO.md` with the next free milestone number.
The section has `needs M32` in its title line.
Its lines come from the ADR decision, the limits, the security rules, and the proposed AGENTS.md rules.
Its first line links the ADR.

The implementation milestone then follows the normal flow.
It gets a brief, a spec, and tickets in its own `.scratch/` directory.
It reads the ADR and the prototype branch as references.
It does not merge or cherry-pick prototype commits.
It writes production code and tests from the ADR.

When the decision is "text fallback only", the new milestone is small.
It can hold only the final fallback text and the security finding about redirects.
When the decision rejects every change, ticket 06 adds no milestone.
It records the reopen conditions in the ADR instead.

## Glossary changes

M32 adds no glossary term while it researches.
The ADR proposes these terms, and the implementation milestone adds the terms that it keeps.

- Image Reference, in the [Presentation glossary](../../src/tui/GLOSSARY.md): one `![alt](destination)` span of a ReviewBody.
- Image Preview, in the Presentation glossary: the Overlay of Variant B, if the decision keeps it.
- Bitbucket Host, in the [Bitbucket glossary](../../src/bitbucket/GLOSSARY.md): a host that may get the Credential.
- The Credential entry gets the rule that only a Bitbucket Host gets it.

The spec uses existing terms from the Review, Presentation, and Bitbucket glossaries.
Examples are Comment, Reply, Thread, Draft, ReviewBody, ReviewCard, Overlay, Session, Session Epoch, Credential, and LocalReview.

## AGENTS.md rules

The prototype branch can break a rule, because it never merges.
The implementation milestone must keep these existing rules:

- "`presentation.zig` does not import vaxis or `theme.zig`."
  Presentation can hold image state as data, such as an id, a state, and a cell size.
  Only `render.zig` and `app.zig` call the vaxis image API.
- "A terminal surface is a View tree in `src/tui/layouts.zig`."
  The image preview Overlay is a View tree, and a content painter draws the image into a Slot's content rect.
- "Every Overlay surface has a rounded border."
  The image preview Overlay builds its surface with `overlaySurface`.
- "An Overlay paints the Theme's base background."
- "A ReviewCard paints the Theme's base background on every row."
  An image with alpha shows the Theme base background behind it.
- "A ReviewCard has a rounded border with its Title in the top border."
  The image stays inside the card content rect, so it never covers a border, a rail, or the Anchor Indicator.
- "The status paints each part through `Theme.statusStyle`."
  An image state in the status uses an existing part or a new arm of `StatusPart`.
- "Only `src/xdg.zig` reads `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME`."
  The detection rule reads no XDG variable.

The ADR proposes at least these new rules for the implementation milestone:

| Rule | Proposed enforcement |
| --- | --- |
| Only a Bitbucket Host gets the Credential, also after a redirect. | A test on `FakeHttpClient` with a redirect to another host. |
| bbr sends no request to an external host while `allow_external` is `false`. | A test on `FakeHttpClient` that counts external requests. |
| An image body above the byte limit stops the read. | A test with a body one byte above the limit. |

## Testing Decisions

The M32 branch adds no code, so it adds no test.
The prototype branch adds only the tests in the "Prototype tests" section.
The implementation milestone writes its own test plan from the ADR.

The prototype tests use these seams:

- `FakeHttpClient` from `src/http/fake_client.zig` for every request.
- The fixture mode for images without network.
- A `vaxis.Screen` with a fixed pixel size, to check placement rows and columns.

## Out of Scope

- A production implementation of any variant.
- Sixel and any terminal outside the target list, except the fallback text.
- A disk cache for images.
- Image upload or image authoring in the Composer.
- Image dimension attributes such as `{width=640}`. M23 found no Cloud Comment guarantee.
- Product reference previews. M31 owns them.
- A change to the existing API redirect behavior. Ticket 06 records the finding for a later milestone.

## Further Notes

- The brief fixes the target terminals.
  If a terminal is not available to the human, ticket 04 records it, and ticket 05 decides without it.
- I15 needs a real PullRequest with a pasted screenshot.
  The human picks one and records only its host log, never its URL or Comment text.
- Screenshots of the fixture Review hold only synthetic data, so they can live in `evidence/` in this directory.
  Screenshots of a real PullRequest never enter the repository.

## Choices this spec records

The brief does not answer these questions.
This spec records a choice for each one.
The human can change a choice at ticket 05.

1. Prototype location: the branch `m32-image-prototype`, not a scratch directory, because the situations need the real paint path.
2. Config key: `[images] allow_external`, default `false`.
3. Bitbucket host list: exact `bitbucket.org` and `api.bitbucket.org` until ticket 01 adds a host with evidence.
4. Redirects: the image path follows each hop itself and applies the host rule at each hop.
5. A storage host that Bitbucket redirects to: not an external load when ticket 01 shows that Bitbucket controls it.
6. LocalReview: bbr reads no Credential, so a Bitbucket-hosted image loads without it or falls back.
7. Starting limits: 10 MiB body, 8192 px per side, 33,177,600 px total, two images at a time.
8. Allowed types: PNG, JPEG, and the first frame of a GIF. No SVG.
9. Cache: memory only, for one Session. No disk cache.
10. Starting inline size: the card content width, at most 12 rows, no upscale.
11. Fallback: the M23 text, plus a short state that ticket 05 accepts or removes.
12. Decision document: an ADR at the next free number, because M28 plans ADR-0014.
13. Relative references: the prototype shows the fallback until ticket 01 finds the base that Bitbucket uses.
