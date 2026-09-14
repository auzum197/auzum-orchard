# orchard [![Crates.io](https://img.shields.io/crates/v/orchard.svg)](https://crates.io/crates/orchard) #

## How this repository is structured

A fork of [zcash/orchard](https://github.com/zcash/orchard) that integrates three
upstreams by **merging** them into one long-lived branch: nothing is rebased, and
`main` is never force-pushed.

### Remotes and sources

| remote | repository | branch | what it carries |
| --- | --- | --- | --- |
| `origin` | `auzum197/auzum-orchard` | `main` | this fork |
| `zcash-upstream` | `zcash/orchard` | `main` | the real upstream |
| `zsa` | `QED-it/orchard` | `zsa1` | Zcash Shielded Assets support (the ZSA source of truth) |
| `zakura` | `zakura-core/common` | `main` | perf fork of the proving stack (monorepo) |

### Branches

- **`main`** — the integration branch consumers use. It merges, in order,
  `zcash-upstream/main`, `zsa/zsa1` and `zakura-orchard`. Port commits (dependency pins,
  the `ff 0.14` port of the ZSA code, test repairs) live here as ordinary commits and
  are carried forward by later merges.
- **`main-upstream`** — a local mirror of `zcash-upstream/main`, refreshed by `just sync`.
- **`zakura-orchard`** — the monorepo (which shares no history with upstream) filtered
  to `crates/orchard`, moved to the repo root and grafted onto zcash/orchard `29d1d55`,
  zakura's fork point, so it can be merged. Regenerated deterministically and
  force-updated by `scripts/zakura-orchard.sh [zakura-rev] [branch]`. `just sync`
  regenerates it at the pinned monorepo rev below (not at `zakura/main`, which moves
  ahead of the pin) and reports how many commits the pin is behind.
- `zakura-patches`, `zakura-rebased` — **superseded**. They come from an earlier
  rebase-based approach and are kept only for reference until deleted.

### Dependency pins

`main` pins the whole proving stack to forks that must agree with each other:

- `halo2_proofs`, `halo2_gadgets`, `poseidon` → `https://github.com/auzum197/halo2.git`
  rev `edd368d4d0b703e27e3c115f40a02a5b1759c350`
  (packages `zakura-halo2-proofs`, `zakura-halo2-gadgets`, `zakura-halo2-poseidon`)
- `pasta_curves`, `sinsemilla`, `reddsa` → `https://github.com/zakura-core/common.git`
  rev `66ddff6adf11ee134efef0e3e28ac5f72ea92824`
  (packages `zakura-pasta-curves`, `zakura-sinsemilla`, `zakura-reddsa`)

**Invariant:** the halo2 fork pins the *same* `zakura-core/common` rev, so exactly one
copy of each `zakura-*` crate may exist in the graph. `just pins` checks both.

`zcash_note_encryption` and `zcash_spec` are patched to the revisions QED-it/orchard pins
(`zcash/zcash_note_encryption` `40b73b15`, `QED-it/zcash_spec` `d5e84264`). QED-it's
`sinsemilla` and halo2 patches are replaced by the pins above; the one sinsemilla API they
add, `CommitDomain::new_with_separate_domains`, is built locally for the OrchardZSA note
commitment.

### ZSA

ZSA support comes from [QED-it/orchard](https://github.com/QED-it/orchard) (`zsa1`), the
implementation of ZIP 226 and ZIP 227. Nothing is taken from `zcash-shielded-assets`.
OrchardZSA is selected at runtime: the ZSA bundle versions build proofs with
`OrchardCircuitVersion::ZSA`, and the Vanilla versions keep the Orchard circuit. Issuance
(ZIP 227) is behind the `zsa-issuance` feature.

### Workflow

```sh
just sync     # fetch remotes, refresh main-upstream, regenerate zakura-orchard
just status   # what each source has that main lacks; check the pins
just merge    # merge upstream -> zsa -> zakura-orchard into main, one at a time
just check    # cargo check --all-targets matrix (default / zsa-issuance / all features)
just test     # cargo test, default and with zsa-issuance
```

`just merge` runs only on a clean `main` and stops at the first conflict: resolve it,
`git add`, `git commit`, then run `just merge` again for the next source. `just --list`
shows the full set of recipes.

Requires Rust 1.91+.

## Documentation

- [The Orchard Book](https://zcash.github.io/orchard/)
- [Crate documentation](https://docs.rs/orchard)

## `no_std` compatibility

In order to take advantage of `no_std` builds, downstream users of this crate
must enable the `spin_no_std` feature of the `lazy_static` crate. This is
needed because the `--no-default-features` build of `lazy_static` still relies
on `std`.

## License

Copyright 2020-2023 The Electric Coin Company.

All code in this workspace is licensed under either of

 * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.
