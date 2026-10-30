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
