# Set the pathological diff time budget

Type: grilling
Status: resolved
Blocked by: 01

## Question

What measured rebuild-time budget must side-by-side matching and intraline comparison meet, and which deterministic simpler result should each algorithm use above its derived input limit?

## Answer

Each algorithm has a p95 cap of 332,137 ns on the baseline Apple M1 host in ReleaseFast mode. The cap is 1.25 times the provisional theoretical time for 250,000 work units at the measured ceiling of 940,881,277 units per second.

The implementation tickets must benchmark their own work because one calibration unit does not equal one algorithm cell. Each ticket must select the largest input limit whose measured p95 stays at or below the cap. The intraline limit uses the product of the old and new lexical-part counts. The side-by-side limit includes both the removed-Line by added-Line area and all lexical comparison work.

Above the side-by-side limit, pair removed and added Lines by index and leave extra Lines unmatched. Above the intraline limit, preserve both Lines and emphasize each complete Line.
