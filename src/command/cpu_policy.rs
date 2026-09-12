//! Process scheduling for the long-lived, fixed-profile preview service.

#[derive(clap::ValueEnum, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ServiceCpuPolicy {
    /// Prefer performance cores for native previews on Windows hybrid CPUs.
    #[default]
    Auto,
    /// Keep OS scheduling on all cores allowed by the parent process.
    All,
}

impl ServiceCpuPolicy {
    /// Called before service workers start; failure leaves OS scheduling intact.
    pub(super) fn configure(self) -> std::io::Result<Option<u32>> {
        if self == Self::All {
            return Ok(None);
        }
        #[cfg(all(windows, feature = "in-process-decode"))]
        return windows::prefer_performance_cores();
        #[cfg(not(all(windows, feature = "in-process-decode")))]
        Ok(None)
    }
}

// Decode the variable-sized Windows CPU-set records without depending on the
// size of a future SDK struct. Unknown record types and trailing fields are OK.
#[cfg(any(test, all(windows, feature = "in-process-decode")))]
fn performance_mask(mut bytes: &[u8], allowed: usize) -> Option<usize> {
    let mut classes = Vec::new();
    while !bytes.is_empty() {
        let size = u32::from_le_bytes(bytes.get(..4)?.try_into().ok()?) as usize;
        let kind = u32::from_le_bytes(bytes.get(4..8)?.try_into().ok()?);
        if size < 8 || size > bytes.len() {
            return None;
        }
        let record = &bytes[..size];
        bytes = &bytes[size..];
        if kind != 0 {
            continue;
        }
        let group = u16::from_le_bytes(record.get(12..14)?.try_into().ok()?);
        let logical = u32::from(*record.get(14)?);
        // A single affinity mask cannot describe multiple processor groups.
        if group != 0 || logical >= usize::BITS {
            return None;
        }
        let class = *record.get(18)?;
        let flags = *record.get(19)?;
        let exclusive_elsewhere = flags & 2 != 0 && flags & 4 == 0;
        classes.push((class, 1_usize << logical, exclusive_elsewhere));
    }
    let highest = classes.iter().map(|&(class, _, _)| class).max()?;
    if classes.iter().all(|&(class, _, _)| class == highest) {
        return None;
    }
    let mask = classes.iter().fold(0, |mask, &(class, bit, unavailable)| {
        if class == highest && !unavailable {
            mask | (bit & allowed)
        } else {
            mask
        }
    });
    (mask != 0 && mask != allowed).then_some(mask)
}

#[cfg(all(windows, feature = "in-process-decode"))]
mod windows {
    use std::{ffi::c_void, io};

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcess() -> *mut c_void;
        fn GetProcessAffinityMask(process: *mut c_void, own: *mut usize, system: *mut usize)
        -> i32;
        fn SetProcessAffinityMask(process: *mut c_void, mask: usize) -> i32;
        fn GetProcessDefaultCpuSets(
            process: *mut c_void,
            ids: *mut u32,
            count: u32,
            required: *mut u32,
        ) -> i32;
        fn GetSystemCpuSetInformation(
            buffer: *mut c_void,
            length: u32,
            required: *mut u32,
            process: *mut c_void,
            flags: u32,
        ) -> i32;
    }

    pub(super) fn prefer_performance_cores() -> io::Result<Option<u32>> {
        // The pseudo-handle belongs to this process and must not be closed.
        let process = unsafe { GetCurrentProcess() };
        let (mut own, mut system) = (0, 0);
        if unsafe { GetProcessAffinityMask(process, &mut own, &mut system) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // An inherited restriction is an explicit policy; do not narrow it.
        if own == 0 || own != system {
            return Ok(None);
        }
        let mut selected_count = 0;
        let selected_result = unsafe {
            GetProcessDefaultCpuSets(process, std::ptr::null_mut(), 0, &mut selected_count)
        };
        if selected_count != 0 {
            return Ok(None);
        }
        if selected_result == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut required = 0;
        unsafe { GetSystemCpuSetInformation(std::ptr::null_mut(), 0, &mut required, process, 0) };
        if required == 0 {
            return Err(io::Error::last_os_error());
        }
        if required > 1024 * 1024 {
            return Ok(None);
        }
        // u64 storage provides the API's required alignment. Parse only the
        // initialized byte count reported by the successful second call.
        let mut storage = vec![0_u64; (required as usize).div_ceil(8)];
        let capacity = (storage.len() * 8) as u32;
        if unsafe {
            GetSystemCpuSetInformation(
                storage.as_mut_ptr().cast(),
                capacity,
                &mut required,
                process,
                0,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        if required > capacity {
            return Ok(None);
        }
        let bytes =
            unsafe { std::slice::from_raw_parts(storage.as_ptr().cast(), required as usize) };
        let Some(mask) = super::performance_mask(bytes, own) else {
            return Ok(None);
        };
        if unsafe { SetProcessAffinityMask(process, mask) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Some(mask.count_ones()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(group: u16, logical: u8, class: u8, flags: u8) -> Vec<u8> {
        let mut bytes = vec![0; 32];
        bytes[..4].copy_from_slice(&32_u32.to_le_bytes());
        bytes[12..14].copy_from_slice(&group.to_le_bytes());
        bytes[14] = logical;
        bytes[18] = class;
        bytes[19] = flags;
        bytes
    }

    #[test]
    fn hybrid_selection_respects_allowed_and_exclusive_cores() {
        let records = [
            record(0, 0, 0, 0),
            record(0, 1, 1, 0),
            record(0, 2, 1, 2),
            record(0, 3, 1, 6),
        ]
        .concat();
        assert_eq!(performance_mask(&records, 0b1111), Some(0b1010));
        assert_eq!(performance_mask(&records, 0b0011), Some(0b0010));
        assert_eq!(performance_mask(&records, 0b0001), None);
    }

    #[test]
    fn unsupported_or_malformed_topology_keeps_os_policy() {
        assert_eq!(performance_mask(&[], usize::MAX), None);
        assert_eq!(performance_mask(&record(0, 0, 1, 0), usize::MAX), None);
        let multi_group = [record(0, 0, 0, 0), record(1, 0, 1, 0)].concat();
        assert_eq!(performance_mask(&multi_group, usize::MAX), None);
        let mut invalid = record(0, 0, 0, 0);
        invalid[..4].copy_from_slice(&0_u32.to_le_bytes());
        assert_eq!(performance_mask(&invalid, usize::MAX), None);
        assert_eq!(
            performance_mask(&record(0, 0, 0, 0)[..19], usize::MAX),
            None
        );
    }

    #[test]
    fn unknown_records_and_extended_records_are_skipped_safely() {
        let mut unknown = record(0, 0, 0, 0);
        unknown[4..8].copy_from_slice(&42_u32.to_le_bytes());
        let mut extended = record(0, 1, 1, 0);
        extended.extend_from_slice(&[0; 16]);
        extended[..4].copy_from_slice(&48_u32.to_le_bytes());
        let records = [unknown, record(0, 0, 0, 0), extended].concat();
        assert_eq!(performance_mask(&records, 0b11), Some(0b10));
    }
}
