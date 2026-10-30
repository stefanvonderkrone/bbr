# 03: Build the throwaway image prototype

Status: ready-for-agent
Blocked by: 01, 02
Spec: [M32 spec](../SPEC.md)

## What to build

A throwaway prototype on the branch `m32-image-prototype` that shows ReviewBody images in bbr.
It has Variant A, the inline image, and Variant B, the image preview Overlay.
It opens one fixture Review with the situations R1 to R12 of the spec.
It writes the probe log that the spec defines.

The branch never merges.
This ticket runs the prototype only far enough to prove that it works in one kitty-protocol terminal.
Ticket 04 does the full run.

## Scope

- Create the branch `m32-image-prototype` from the M32 branch in its own Worktree.
  Make every prototype commit on that branch.
  On the M32 branch, change only this ticket and add files under `evidence/`.
- Follow the "Prototype" section of the spec.
- Use the Bitbucket host list from ticket 01 and the detection rule from ticket 02.
- Add the kitty graphics path through the vaxis 0.6.0 API.
  Turn on capability detection and record each side effect that ticket 02 lists.
- Add tmux passthrough for the kitty path.
- Add the iTerm2 inline image path until it shows I1 in iTerm2 or WezTerm.
  If the path needs more than a small adapter, record the cost and stop.
- Add the fixture mode for `fixture:I1` to `fixture:I12`.
- Add a script that generates I1 to I12 with synthetic content.
- Add one command or script that sets up the fixture Review with the situations R1 to R12.
- Add the network path for I13 to I15 under the "Security rules" section of the spec.
  The image path follows each redirect itself and applies the Credential host rule at each hop.
- Add both PNG paths from the spec: decode with `zigimg`, and send PNG bytes as `f=100`.
- Add the environment switches with the `BBR_M32_` prefix:
  the variant, the PNG path, `BBR_M32_ALLOW_EXTERNAL`, the maximum inline rows, and `BBR_M32_PROBE_LOG`.
- Add the fallback text states from the "Fallback text behavior" section of the spec.
- Add the probe log and the `summarize` script from the "Measurements" section of the spec.
- Add the `M32 image` tests from the "Prototype tests" section of the spec.
- Write `evidence/run-guide.md` on the M32 branch.
  It tells the human how to build the prototype, set up the fixture Review, set each switch, and run `summarize`.
- Record a first measurement of I1 to I12 in one kitty-protocol terminal under `## Completion`.

Do not change production code on the M32 branch.
Do not call Bitbucket in this ticket.

## Acceptance criteria

- [ ] The branch `m32-image-prototype` exists, and `## Completion` names its last commit.
- [ ] The M32 branch has no source code change from this ticket.
- [ ] `zig build` passes on the prototype branch.
- [ ] Every `M32 image` test from the spec exists and passes on the prototype branch.
- [ ] The Credential test with a redirect to another host passes.
- [ ] I9 and I10 give a failure state and no crash in a `ReleaseSafe` build.
- [ ] Variant A and Variant B both show I1 in one kitty-protocol terminal.
- [ ] One command or script sets up the fixture Review with R1 to R12.
- [ ] The probe log holds every event and key from the spec.
- [ ] The probe log holds no URL, query string, Comment text, or Credential.
- [ ] `summarize` prints the numbers that the spec lists.
- [ ] `## Completion` records the cost of the iTerm2 path and of tmux passthrough.
- [ ] `## Completion` records the side effects of capability detection.
- [ ] `evidence/run-guide.md` exists on the M32 branch.
- [ ] `python3 tools/check_agent_docs.py` passes on the M32 branch.

## Required checks

On the prototype branch:

- `zig build`
- `zig build test --summary all`, with the `M32 image` tests in the run.
- A `ReleaseSafe` build that opens I9 and I10.

On the M32 branch:

- `python3 tools/check_agent_docs.py`
