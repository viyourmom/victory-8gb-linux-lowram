//! The console's resolution ladder, and the self-check that guards it, as
//! the title stores them.
//!
//! Everything here is a byte pattern and a replacement, never a stored
//! offset, so nothing from the executable lives in the tree
//! (docs/asset-policy.md).

/// The console's resolution ladder as the title stores it: each entry is
/// `width, height, 60, 1` (sixteen bytes), from 720p to the Series X's 4K.
const LADDER: [(u32, u32); 5] = [
    (1280, 720),
    (1664, 936),
    (1920, 1080),
    (2560, 1440),
    (3840, 2160),
];

/// Caps every ladder entry above `w`x`h` at that size and returns how many
/// entries changed.
///
/// The title picks its window, swap chain and render target size from this
/// table, so lowering its ceiling is what makes it run below 4K (the display
/// mode it is told about is not the lever). The table is found by its five
/// entries; a build without it changes nothing.
///
/// # Safety
/// `base` must point at `size` writable bytes of the mapped image.
pub unsafe fn cap_ladder(base: *mut u8, size: usize, w: u32, h: u32) -> usize {
    if base.is_null() || size < LADDER.len() * 16 {
        return 0;
    }
    // SAFETY: the caller guarantees `size` writable bytes.
    let image = unsafe { std::slice::from_raw_parts_mut(base, size) };
    let mut pattern = Vec::with_capacity(LADDER.len() * 16);
    for (lw, lh) in LADDER {
        pattern.extend_from_slice(&lw.to_le_bytes());
        pattern.extend_from_slice(&lh.to_le_bytes());
        pattern.extend_from_slice(&60u32.to_le_bytes());
        pattern.extend_from_slice(&1u32.to_le_bytes());
    }
    let Some(at) = image.windows(pattern.len()).position(|s| s == pattern) else {
        return 0;
    };
    let target = u64::from(w) * u64::from(h);
    let mut changed = 0;
    for (i, &(lw, lh)) in LADDER.iter().enumerate() {
        if u64::from(lw) * u64::from(lh) <= target {
            continue;
        }
        let entry = at + 16 * i;
        image[entry..entry + 4].copy_from_slice(&w.to_le_bytes());
        image[entry + 4..entry + 8].copy_from_slice(&h.to_le_bytes());
        changed += 1;
    }
    changed
}

/// The `int3` of the title's pool-offset self-check, as an absolute address,
/// or `None` if this build does not have it.
///
/// The check is
/// `mov rax,[rsp+0x78]; sub rax,[rsp+0x70]; add rax,[rip+disp]; cmp rax,
/// 0x1fffff; jbe +1; int3`. It compares a ring-buffer offset, not a size;
/// with a capped ladder that offset grows past 2 MiB on our builds and the
/// check fires on a value that is unrelated to the cap. Stepping over the
/// one `int3` (see `victory_loader::step_over_breakpoint_at`) lets the title
/// continue.
///
/// # Safety
/// `base` must point at `size` readable bytes of the mapped image.
pub unsafe fn assert_site(base: usize, size: usize) -> Option<usize> {
    /// `mov rax,[rsp+0x78]` then `sub rax,[rsp+0x70]`.
    const PREFIX: [u8; 10] = [0x48, 0x8b, 0x44, 0x24, 0x78, 0x48, 0x2b, 0x44, 0x24, 0x70];
    /// `add rax,[rip+disp32]`: four displacement bytes follow.
    const ADD: [u8; 3] = [0x48, 0x03, 0x05];
    /// `cmp rax,0x1fffff`.
    const CMP: [u8; 6] = [0x48, 0x3d, 0xff, 0xff, 0x1f, 0x00];
    /// `jbe` over the `int3`.
    const JBE: u8 = 0x76;
    /// The instruction sequence is 26 bytes, `int3` the last of them.
    const LEN: usize = 26;

    if base == 0 || size < LEN {
        return None;
    }
    // SAFETY: the caller guarantees `size` readable bytes.
    let image = unsafe { std::slice::from_raw_parts(base as *const u8, size) };
    let mut at = 0;
    while at + LEN <= image.len() {
        if image[at..at + 10] == PREFIX
            && image[at + 10..at + 13] == ADD
            && image[at + 17..at + 23] == CMP
            && image[at + 23] == JBE
            && image[at + 25] == 0xcc
        {
            return Some(base + at + 25);
        }
        at += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An image holding the ladder at `at`, padded with `0x90`.
    fn image_with_ladder(at: usize) -> Vec<u8> {
        let mut image = vec![0x90u8; at + LADDER.len() * 16 + 16];
        for (i, &(w, h)) in LADDER.iter().enumerate() {
            let entry = at + 16 * i;
            image[entry..entry + 4].copy_from_slice(&w.to_le_bytes());
            image[entry + 4..entry + 8].copy_from_slice(&h.to_le_bytes());
            image[entry + 8..entry + 12].copy_from_slice(&60u32.to_le_bytes());
            image[entry + 12..entry + 16].copy_from_slice(&1u32.to_le_bytes());
        }
        image
    }

    #[test]
    fn caps_the_entries_above_the_target() {
        let mut image = image_with_ladder(64);
        // SAFETY: the buffer is that long.
        let changed = unsafe { cap_ladder(image.as_mut_ptr(), image.len(), 1920, 1080) };
        assert_eq!(changed, 2, "1440p and 2160p");
        let entry = |i: usize| {
            let at = 64 + 16 * i;
            (
                u32::from_le_bytes(image[at..at + 4].try_into().unwrap()),
                u32::from_le_bytes(image[at + 4..at + 8].try_into().unwrap()),
            )
        };
        assert_eq!(entry(0), (1280, 720), "below the target, untouched");
        assert_eq!(entry(1), (1664, 936), "below the target, untouched");
        assert_eq!(entry(2), (1920, 1080), "the target itself, untouched");
        assert_eq!(entry(3), (1920, 1080), "capped");
        assert_eq!(entry(4), (1920, 1080), "capped");
    }

    #[test]
    fn a_build_without_the_ladder_is_unchanged() {
        let mut image = vec![0x90u8; 256];
        let before = image.clone();
        // SAFETY: the buffer is that long.
        let changed = unsafe { cap_ladder(image.as_mut_ptr(), image.len(), 1920, 1080) };
        assert_eq!(changed, 0);
        assert_eq!(image, before);
    }

    #[test]
    fn finds_the_self_check_and_its_int3() {
        let mut image = [0x90u8; 128];
        let code: [u8; 26] = [
            0x48, 0x8b, 0x44, 0x24, 0x78, 0x48, 0x2b, 0x44, 0x24, 0x70, 0x48, 0x03, 0x05, 0xcb,
            0xc0, 0x16, 0x05, 0x48, 0x3d, 0xff, 0xff, 0x1f, 0x00, 0x76, 0x01, 0xcc,
        ];
        image[40..40 + code.len()].copy_from_slice(&code);
        // SAFETY: the buffer is that long.
        let site = unsafe { assert_site(image.as_ptr() as usize, image.len()) };
        assert_eq!(site.map(|at| at - image.as_ptr() as usize), Some(65));
    }

    #[test]
    fn a_near_miss_is_not_the_self_check() {
        let mut image = [0x90u8; 128];
        // The same sequence with a different immediate: a different check.
        image[40..50].copy_from_slice(&[
            0x48, 0x8b, 0x44, 0x24, 0x78, 0x48, 0x2b, 0x44, 0x24, 0x70,
        ]);
        image[50..53].copy_from_slice(&[0x48, 0x03, 0x05]);
        image[57..63].copy_from_slice(&[0x48, 0x3d, 0xff, 0xff, 0xff, 0x00]);
        image[63] = 0x76;
        image[65] = 0xcc;
        // SAFETY: the buffer is that long.
        assert_eq!(unsafe { assert_site(image.as_ptr() as usize, image.len()) }, None);
    }
}
