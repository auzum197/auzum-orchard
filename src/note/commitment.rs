//! Note commitments and their trapdoors.
//!
//! A [`NoteCommitment`] is the Sinsemilla commitment to the contents of a
//! note, binding the diversified transmission key, note value, ρ, and ψ. Its
//! x-coordinate is exposed as [`ExtractedNoteCommitment`] (the value
//! appearing in the commitment tree), and its randomness is
//! [`NoteCommitTrapdoor`].

use core::iter;

use alloc::{format, vec::Vec};

use crate::once::OnceTable;
use bitvec::{array::BitArray, order::Lsb0};
use group::ff::{PrimeField, PrimeFieldBits};
use pasta_curves::{arithmetic::CurveExt, pallas};
use subtle::{ConditionallySelectable, ConstantTimeEq, CtOption};

use crate::{
    constants::{
        L_ORCHARD_BASE,
        fixed_bases::{NOTE_COMMITMENT_PERSONALIZATION, NOTE_ZSA_COMMITMENT_PERSONALIZATION},
    },
    note::AssetBase,
    spec::extract_p,
    value::NoteValue,
};

static NOTE_COMMITMENT_DOMAIN: OnceTable<sinsemilla::CommitDomain> = OnceTable::new();

fn note_commitment_domain() -> &'static sinsemilla::CommitDomain {
    NOTE_COMMITMENT_DOMAIN
        .get_or_init(|| sinsemilla::CommitDomain::new(NOTE_COMMITMENT_PERSONALIZATION))
}

/// The OrchardZSA note commitment domain: the `z.cash:ZSA-NoteCommit` hash domain with the
/// Orchard blind domain `z.cash:Orchard-NoteCommit`, as specified in
/// [ZIP 226](https://zips.z.cash/zip-0226#note-structure-commitment).
///
/// This is `sinsemilla::CommitDomain::new_with_separate_domains(NOTE_ZSA_COMMITMENT_PERSONALIZATION,
/// NOTE_COMMITMENT_PERSONALIZATION)` from QED-it's sinsemilla fork, which the zakura sinsemilla
/// crate does not provide.
struct NoteZsaCommitDomain {
    m: sinsemilla::HashDomain,
    r: pallas::Point,
}

impl NoteZsaCommitDomain {
    fn new() -> Self {
        NoteZsaCommitDomain {
            m: sinsemilla::HashDomain::new(&format!("{}-M", NOTE_ZSA_COMMITMENT_PERSONALIZATION)),
            r: pallas::Point::hash_to_curve(&format!("{}-r", NOTE_COMMITMENT_PERSONALIZATION))(&[]),
        }
    }

    /// $\mathsf{SinsemillaCommit}$, with complete addition for the blinding factor.
    fn commit(&self, msg: impl Iterator<Item = bool>, r: &pallas::Scalar) -> CtOption<pallas::Point> {
        self.m.hash_to_point(msg).map(|p| p + self.r * r)
    }
}

static NOTE_ZSA_COMMITMENT_DOMAIN: OnceTable<NoteZsaCommitDomain> = OnceTable::new();

fn note_zsa_commitment_domain() -> &'static NoteZsaCommitDomain {
    NOTE_ZSA_COMMITMENT_DOMAIN.get_or_init(NoteZsaCommitDomain::new)
}

/// The trapdoor for a note commitment.
#[derive(Clone, Debug)]
#[cfg_attr(feature = "unstable-voting-circuits", visibility::make(pub))]
pub(crate) struct NoteCommitTrapdoor(pub(super) pallas::Scalar);

impl NoteCommitTrapdoor {
    /// Returns the inner scalar value.
    #[cfg_attr(feature = "unstable-voting-circuits", visibility::make(pub))]
    pub(crate) fn inner(&self) -> pallas::Scalar {
        self.0
    }

    /// Constructs a `NoteCommitTrapdoor` from the provided scalar value.
    ///
    /// This constructor is only available in tests.
    #[cfg(test)]
    pub fn new(trapdoor: pallas::Scalar) -> Self {
        Self(trapdoor)
    }
}

/// A commitment to a note.
#[derive(Clone, Debug)]
pub struct NoteCommitment(pub(super) pallas::Point);

impl NoteCommitment {
    /// Returns the inner Pallas curve point.
    #[cfg_attr(feature = "unstable-voting-circuits", visibility::make(pub))]
    pub(crate) fn inner(&self) -> pallas::Point {
        self.0
    }
}

impl NoteCommitment {
    /// $NoteCommit^{Orchard}$ when the asset is zatoshi,
    /// and $NoteCommit^{OrchardZSA}$ otherwise.
    ///
    /// $NoteCommit^{Orchard}$ is defined in
    /// [Zcash Protocol Spec § 5.4.8.4: Sinsemilla commitments][concretesinsemillacommit].
    /// $NoteCommit^{OrchardZSA}$ is defined in
    /// [ZIP-226: Transfer and Burn of Zcash Shielded Assets][notecommitzsa].
    ///
    /// [concretesinsemillacommit]: https://zips.z.cash/protocol/nu5.pdf#concretesinsemillacommit
    /// [notecommitzsa]: https://zips.z.cash/zip-0226#note-structure-and-commitment
    pub(crate) fn derive(
        g_d: [u8; 32],
        pk_d: [u8; 32],
        v: NoteValue,
        asset: AssetBase,
        rho: pallas::Base,
        psi: pallas::Base,
        rcm: NoteCommitTrapdoor,
    ) -> CtOption<Self> {
        let common_note_bits = iter::empty()
            .chain(BitArray::<_, Lsb0>::new(g_d).iter().by_vals())
            .chain(BitArray::<_, Lsb0>::new(pk_d).iter().by_vals())
            .chain(v.to_le_bits().iter().by_vals())
            .chain(rho.to_le_bits().iter().by_vals().take(L_ORCHARD_BASE))
            .chain(psi.to_le_bits().iter().by_vals().take(L_ORCHARD_BASE))
            .collect::<Vec<bool>>();

        let zec_note_bits = common_note_bits.clone().into_iter();

        let asset_bits = BitArray::<_, Lsb0>::new(asset.to_bytes());
        let zsa_note_bits = common_note_bits
            .into_iter()
            .chain(asset_bits.iter().by_vals());

        // Evaluate ZEC note commitment
        let commit_with_zec_domain = note_commitment_domain().commit(zec_note_bits, &rcm.0);

        // Evaluate ZSA note commitment
        let commit_with_zsa_domain = note_zsa_commitment_domain().commit(zsa_note_bits, &rcm.0);

        // Select the desired commitment in constant-time
        let commit = commit_with_zsa_domain.and_then(|zsa_commit| {
            commit_with_zec_domain.map(|zec_commit| {
                pallas::Point::conditional_select(&zsa_commit, &zec_commit, asset.is_zatoshi())
            })
        });

        commit.map(NoteCommitment)
    }
}

/// The x-coordinate of the commitment to a note.
#[derive(Copy, Clone, Debug)]
pub struct ExtractedNoteCommitment(pub(super) pallas::Base);

impl ExtractedNoteCommitment {
    /// Deserialize the extracted note commitment from a byte array.
    ///
    /// This method enforces the [consensus rule][cmxcanon] that the
    /// byte representation of cmx MUST be canonical.
    ///
    /// [cmxcanon]: https://zips.z.cash/protocol/protocol.pdf#actionencodingandconsensus
    pub fn from_bytes(bytes: &[u8; 32]) -> CtOption<Self> {
        pallas::Base::from_repr(*bytes).map(ExtractedNoteCommitment)
    }

    /// Serialize the value commitment to its canonical byte representation.
    pub fn to_bytes(self) -> [u8; 32] {
        self.0.to_repr()
    }
}

impl From<NoteCommitment> for ExtractedNoteCommitment {
    fn from(cm: NoteCommitment) -> Self {
        ExtractedNoteCommitment(extract_p(&cm.0))
    }
}

impl ExtractedNoteCommitment {
    /// Returns the inner field element.
    #[cfg_attr(feature = "unstable-voting-circuits", visibility::make(pub))]
    pub(crate) fn inner(&self) -> pallas::Base {
        self.0
    }
}

impl From<&ExtractedNoteCommitment> for [u8; 32] {
    fn from(cmx: &ExtractedNoteCommitment) -> Self {
        cmx.to_bytes()
    }
}

impl ConstantTimeEq for ExtractedNoteCommitment {
    fn ct_eq(&self, other: &Self) -> subtle::Choice {
        self.0.ct_eq(&other.0)
    }
}

impl PartialEq for ExtractedNoteCommitment {
    fn eq(&self, other: &Self) -> bool {
        self.ct_eq(other).into()
    }
}

impl Eq for ExtractedNoteCommitment {}
