# allocator-api2 0.2.21, patched for pgrust

Upstream `allocator-api2` 0.2.21 from crates.io (checksum
`683d7910e743518b0e34f1186f92494becacb047c7b6bf616c96772180fef923`), wired in through the
workspace's `[patch.crates-io]`. The changes, each marked `pgrust:`, are inline attributes in
`src/stable/raw_vec.rs`, plus one `#![allow(dangerous_implicit_autorefs)]` in `src/lib.rs`
(crates.io dependencies build under `--cap-lints allow`; a path dependency does not, and that
deny-by-default lint fires on upstream code):

- `RawVec::reserve_for_push` (what `Vec::push` calls when full): `#[inline(never)]`, as std's
  `RawVec::grow_one`.
- `reserve`'s `do_reserve_and_handle`: `#[cold] #[inline(never)]`, as std (upstream kept `#[cold]`
  but forced `#[inline(always)]`).
- `finish_grow`: `#[inline(never)]`, as std: one copy per allocator type.
- `grow_amortized`, `grow_exact`: no `#[inline(always)]`; LLVM inlines them into the out-of-line
  entry points above.

Why: every `RawVec` method is `#[inline(always)]` upstream, so each `PgVec::push` site in the
engine carried the whole growth path (capacity doubling, layout checks, `Mcx::allocate`'s
always-inlined backend dispatch or a call to `Mcx::grow`, and the OOM/overflow handlers). Callgrind
on the Speedtest's warm rows put about 2,600 of pgrust's hot per-statement instructions in
`raw_vec.rs` alone, spread over hundreds of push sites; C's `lappend` keeps its growth in one
out-of-line `enlarge_list`. Behaviour is unchanged: only where code is placed.
