# 05: Decide the ReviewBody image behavior

Status: ready-for-human
Blocked by: 04
Spec: [M32 spec](../SPEC.md)

## What to build

A human compares Variant A, the inline image, with Variant B, the image preview Overlay.
The human uses the screenshots and measurements from ticket 04.
The human records one decision and the values that the implementation needs.
This is a decision checkpoint, so an agent cannot close it.

## Steps

1. Read the research notes from tickets 01 and 02 and the evidence from ticket 04.
2. Look at the screenshots of each situation for both variants.
3. Pick one decision:
   inline image, image preview, both, text fallback only, or no change.
4. For each target terminal, decide if bbr shows images there or uses the fallback text.
   A terminal with stale images or broken scroll in ticket 04 can get the fallback text.
5. Decide the values in the list under "Acceptance criteria".
6. Review each choice in the "Choices this spec records" section of the spec.
   Keep it or change it, and give the reason.
7. Record the answers under `## Answer` in this ticket.

## Inputs

- The screenshots, `summarize` output, and matrix columns of ticket 04.
- The research notes of tickets 01 and 02, and the prototype at `da08e54` that ticket 03 names.

### Decode facts

The M32 review and the hardened prototype give these facts for the PNG path and the type limits.

Safe on Zig 0.16:

- bbr checks the header and the file structure with no allocation, as `m32.admit` does.
- Then bbr sends the original bytes to the terminal, and the terminal decodes them.
- kitty gets PNG with `f=100`. iTerm2 gets PNG, JPEG, or GIF.

Unsafe on Zig 0.16, because the decoders panic or allocate without a bound (M32P-1, M32P-2, M32P-3, X-3):

- zigimg or std flate on a PNG. A 141-byte PNG with valid chunk CRCs and a short deflate stream panics std flate with `integer overflow` (M32P-1).
- zigimg on a JPEG. A 762-byte truncated JPEG with `FF D9` at the end panics zigimg with `index out of bounds` at `jpeg/Scan.zig:58` (M32P-2).
- zigimg on a GIF. A 6,920-byte GIF with 300 frames grows the RSS from 13 MB to 326 MB (M32P-3).

A panic in `ReleaseSafe` stops bbr, and any Comment author can supply the bytes.
So the "decode with `zigimg`" PNG path in the acceptance criteria is unsafe for untrusted images.

Not proved: whether a hostile image can crash the terminal itself.
The prototype sends the original bytes, so the terminal decoder sees the hostile input.

## Acceptance criteria

- [ ] `## Answer` names one decision and gives the reason from the evidence.
- [ ] `## Answer` names, for each matrix column, whether bbr shows images or the fallback text.
- [ ] For inline images, `## Answer` names the maximum rows, the upscale rule, and the aspect ratio rule.
- [ ] `## Answer` names the behavior at each Reply indentation and in a collapsed ReviewCard disclosure.
- [ ] `## Answer` names the Action and keys for the image preview, if Variant B stays.
- [ ] `## Answer` names the PNG path: decode with `zigimg`, or `f=100`.
- [ ] `## Answer` names the final byte, dimension, type, and concurrency limits, and a memory budget.
- [ ] `## Answer` names the cache lifetime and when bbr frees a terminal image.
- [ ] `## Answer` names the final fallback text for each state.
- [ ] `## Answer` keeps or changes each recorded choice of the spec, with a reason.
- [ ] `python3 tools/check_agent_docs.py` passes.

## Comments

On 2026-11-02, the M32 prototype alignment run added the `## Inputs` section with the decode facts.
The facts come from the M32 review findings M32P-1, M32P-2, M32P-3, and X-3, and from the prototype at `da08e54`.
The status stays `ready-for-human`, because only the human makes this decision.
