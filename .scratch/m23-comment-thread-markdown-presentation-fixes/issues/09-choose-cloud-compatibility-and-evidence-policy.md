# Choose Cloud compatibility and evidence policy

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: 01, 02

## Question

Which source defines M23 behavior when the selected Data Center guide and Cloud evidence differ or leave behavior unknown?

The user selected the Data Center guide as the target while the application supports Cloud REST API 2.0.
Research establishes that the documented parsers differ.
Choose whether verified Cloud behavior overrides the guide or whether the guide defines an intentional project behavior.
Do not claim Cloud equivalence where evidence supports only an approximation.

Decide whether Cloud-only extensions outside the guide belong in M23 or remain literal text.
Examples include definition lists, footnotes, abbreviations, heading IDs, table of contents, and wiki links.
Product references can need Repository or integration context that a Markdown body alone does not contain.

Choose the evidence threshold for lists, fenced code, HTML handling, and emoji conversion.
Decide which unknown cases require live raw and HTML pairs before implementation.
Choose whether synthetic read-only existing Comments can satisfy that evidence need.
Any live authoring requires a separately agreed test location and scope.

The answer must name the source precedence, supported scope, compatibility claim, and required follow-up evidence.
Create focused research or prerequisite task tickets for evidence that becomes necessary.

## Comments

### Source rules and extension scope

The user agreed to both recommendations in the first question round.

- Verified Cloud behavior takes precedence over the selected Data Center guide for syntax rules.
- Project decisions control terminal presentation and retain the agreed literal code behavior.
- Cloud-only extensions outside the selected guide remain literal text in M23.
  Examples include footnotes, definition lists, and wiki links.

The first round left the evidence threshold and compatibility claim open.

### Evidence threshold and compatibility claim

The user agreed to both recommendations in the second question round.

- M23 can define explicit project behavior for unverified list, fence, HTML, and emoji cases.
- These decisions require documented acceptance examples.
- Live proof is required only for a claim of exact Cloud compatibility.
- Existing synthetic Comments can supply live evidence through paired raw Markdown and HTML.
- Support is best-effort.
- New Comment authoring requires a separately agreed test location and scope.

## Answer

### Source precedence

For supported syntax, verified Cloud behavior takes precedence over the selected Data Center guide.
The guide remains the reference for the requested syntax scope.
Project decisions control terminal presentation and preserve the agreed literal code behavior.
An upstream parser example alone does not verify Cloud behavior.

When Cloud evidence does not settle a case, M23 can define explicit project behavior with acceptance examples.
The specification must identify that behavior as a project decision rather than an observed Cloud fact.

### Supported scope

M23 covers the selected guide's syntax, subject to the remaining terminal presentation decisions.
Cloud-only extensions outside that guide remain literal text.
These include definition lists, footnotes, abbreviations, heading IDs, table of contents, and wiki links.

[Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md) selects the terminal representations, emoji catalog, and conversion contexts.
That ticket also selects the handling of automatic links and product-specific references within the agreed scope.
This policy does not add Cloud-only syntax to M23.

### Compatibility claim

Describe M23 support as best-effort compatibility for the chosen syntax scope.
Do not claim complete Cloud Markdown or emoji equivalence.
A Cloud compatibility claim cannot exceed the cases its evidence verifies.
Project acceptance examples establish bbr behavior, not Cloud behavior.

### Required evidence

Unverified list, fence, HTML, and emoji cases require explicit project decisions with documented acceptance examples.
No such case requires live Cloud proof before implementation unless M23 claims exact Cloud compatibility for that case.
Existing synthetic Comments can supply live evidence through paired raw Markdown and HTML for the same Comment.
An existing Comment verifies only the input and context it contains.
New Comment authoring requires a separately agreed test location and scope.

No follow-up research or prerequisite task is required by this decision.
The remaining presentation decisions must document their acceptance examples under this policy.
[Define the integrated M23 acceptance contract](./08-define-the-integrated-m23-acceptance-contract.md) checks those examples and the limits of their claims.
