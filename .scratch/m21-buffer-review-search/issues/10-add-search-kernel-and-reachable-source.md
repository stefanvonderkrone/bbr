# 10 — Add the Search Kernel and Reachable Source

**What to build:** Give Buffer Search and Review Search one shared Unicode search contract with exact Search Occurrence identity. Every source match remains reachable because DiffPane source Lines always wrap.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] A validated Query accepts at most 256 Unicode scalars and refuses invalid UTF-8, NUL, and line endings without changing published state.
- [x] Smart case uses an ASCII fast path and one-scalar Unicode case folding from one pinned Unicode release. It does not use normalization, locale mappings, or multi-scalar mappings.
- [x] Generated Unicode data records the Unicode version and source checksums. M21 adds no runtime dependency.
- [x] Literal scans return leftmost, non-overlapping Search Occurrences in canonical corpus order, with exact half-open UTF-8 ranges and one-based Unicode scalar columns.
- [x] Fuzzy scans return one best complete-query alignment per Candidate and follow the specified `fzy` score, boundary rewards, gap penalties, exact ranges, and deterministic tie order.
- [x] A deterministic fallback handles scans above the benchmark-selected dynamic-programming cell limit. Exact results always rank before fallback results.
- [x] The bounded benchmark covers long generated Lines, long Unicode Lines, and a 256-scalar Query. The chosen limit is recorded beside the fallback policy.
- [x] ReviewBody Candidates search logical authored lines, cross zero-width Markdown delimiters, stop at generated boundaries, and map matches back to authored UTF-8 ranges.
- [x] Buffer Candidates include semantic source Lines and owned ReviewBodies before disclosure projection. They exclude generated Presentation text and give shared context one identity.
- [x] Review source Candidates preserve File, version relation, path, Line, and canonical corpus identity needed for later coalescing and navigation.
- [x] Search ranges project onto every covered wrapped visual row without changing cell count or wrapping.
- [x] DiffPane source wrapping is unconditional. The wrapping Action, default binding, and preference are removed, and strict configuration rejects the removed Action.
- [x] Pure, Buffer, Keymap, configuration, Frame, and headless rendering tests cover the accepted kernel and wrapping behavior.
