//! Conservative WPP detection for the static preview's slice-thread policy.
//!
//! hvcC's parallelismType can be unspecified even when PPS enables WPP. Read
//! that flag from every PPS instead; unknown layouts retain one decoder thread.

pub(super) fn has_wavefront(extra: &[u8]) -> bool {
    configuration_wavefront(extra).unwrap_or(false)
}

fn configuration_wavefront(extra: &[u8]) -> Option<bool> {
    let header = extra.get(..23)?;
    if header[0] != 1 || header[21] & 3 == 2 {
        return None;
    }
    let mut data = &extra[23..];
    let mut found_pps = false;
    for _ in 0..header[22] {
        let (&array, tail) = data.split_first()?;
        data = tail;
        if array & 0x40 != 0 {
            return None;
        }
        let count = take_u16(&mut data)?;
        for _ in 0..count {
            let length = usize::from(take_u16(&mut data)?);
            let (nal, tail) = data.split_at_checked(length)?;
            data = tail;
            if nal.len() < 2
                || nal[0] & 0x80 != 0
                || nal[1] & 7 == 0
                || (nal[0] >> 1) & 0x3f != array & 0x3f
            {
                return None;
            }
            if array & 0x3f == 34 {
                found_pps = true;
                if !pps_wavefront(nal)? {
                    return Some(false);
                }
            }
        }
    }
    Some(found_pps && data.is_empty())
}

fn take_u16(data: &mut &[u8]) -> Option<u16> {
    let bytes = data.get(..2)?;
    let value = u16::from_be_bytes([bytes[0], bytes[1]]);
    *data = &data[2..];
    Some(value)
}

fn pps_wavefront(nal: &[u8]) -> Option<bool> {
    // Only the single-layer PPS layout is recognized here. This is a scheduling
    // hint, not a replacement for libavcodec's complete bitstream validation.
    if nal.get(..2)? != [68, 1] {
        return None;
    }
    let rbsp = unescape(nal.get(2..)?)?;
    let mut bits = Bits {
        data: &rbsp,
        position: 0,
    };
    if bits.ue()? > 63 || bits.ue()? > 15 {
        // pps_id, sps_id
        return None;
    }
    bits.take(7)?; // dependent slices, output flag, extra header bits, sign/CABAC flags
    if bits.ue()? > 14 || bits.ue()? > 14 {
        // default L0/L1 reference counts minus one
        return None;
    }
    bits.ue()?; // signed init_qp_minus26 has the same code length as ue(v)
    bits.take(2)?; // constrained intra prediction, transform skip
    if bits.take(1)? != 0 {
        // cu_qp_delta_enabled_flag
        bits.ue()?; // diff_cu_qp_delta_depth
    }
    bits.ue()?; // signed cb_qp_offset
    bits.ue()?; // signed cr_qp_offset
    bits.take(4)?; // chroma offsets, weighted prediction, transquant bypass
    let tiles = bits.take(1)? != 0;
    let wavefront = bits.take(1)? != 0;
    // FFmpeg's WPP decode path requires a single tile row and column. Leave
    // tile-enabled and mixed layouts single-threaded instead of guessing.
    Some(wavefront && !tiles)
}

fn unescape(data: &[u8]) -> Option<Vec<u8>> {
    let mut rbsp = Vec::with_capacity(data.len());
    let mut zeros = 0;
    for (index, &byte) in data.iter().enumerate() {
        if zeros == 2 {
            if byte == 3 {
                if *data.get(index + 1)? > 3 {
                    return None;
                }
                zeros = 0;
                continue;
            }
            if byte < 3 {
                return None;
            }
        }
        rbsp.push(byte);
        zeros = if byte == 0 { zeros + 1 } else { 0 };
    }
    Some(rbsp)
}

struct Bits<'a> {
    data: &'a [u8],
    position: usize,
}

impl Bits<'_> {
    fn take(&mut self, count: usize) -> Option<u32> {
        let mut value = 0;
        for _ in 0..count {
            let byte = self.data.get(self.position / 8)?;
            value = (value << 1) | u32::from((byte >> (7 - self.position % 8)) & 1);
            self.position += 1;
        }
        Some(value)
    }

    fn ue(&mut self) -> Option<u32> {
        let mut zeros = 0;
        while self.take(1)? == 0 {
            zeros += 1;
            if zeros > 31 {
                return None;
            }
        }
        Some((1u32 << zeros) - 1 + self.take(zeros)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pps(tiles: bool, wavefront: bool, qp_delta: bool) -> Vec<u8> {
        // All Exp-Golomb fields are zero. Exercise both paths around the
        // optional diff_cu_qp_delta_depth before the two parallelism flags.
        let mut bits = String::from("11000000011100");
        bits.push_str(if qp_delta { "11" } else { "0" });
        bits.push_str("110000");
        bits.push(if tiles { '1' } else { '0' });
        bits.push(if wavefront { '1' } else { '0' });
        bits.push('1'); // trailing stop bit; only the PPS prefix is inspected
        while bits.len() % 8 != 0 {
            bits.push('0');
        }
        let mut nal = vec![68, 1];
        nal.extend(
            bits.as_bytes()
                .chunks(8)
                .map(|b| b.iter().fold(0, |n, b| (n << 1) | (b - b'0'))),
        );
        nal
    }

    fn hvcc(nals: &[Vec<u8>]) -> Vec<u8> {
        let mut extra = vec![0; 23];
        extra[0] = 1;
        extra[21] = 3;
        extra[22] = 1;
        extra.push(34);
        extra.extend_from_slice(&(nals.len() as u16).to_be_bytes());
        for nal in nals {
            extra.extend_from_slice(&(nal.len() as u16).to_be_bytes());
            extra.extend_from_slice(nal);
        }
        extra
    }

    #[test]
    fn wavefront_requires_every_pps_and_no_tiles() {
        for delta in [false, true] {
            let wpp = pps(false, true, delta);
            assert!(has_wavefront(&hvcc(&[wpp.clone(), wpp.clone()])));
            for (tiles, wavefront) in [(false, false), (true, false), (true, true)] {
                assert!(!has_wavefront(&hvcc(&[
                    wpp.clone(),
                    pps(tiles, wavefront, delta)
                ])));
            }
        }
    }

    #[test]
    fn unknown_or_damaged_configuration_stays_single_threaded() {
        let valid = hvcc(&[pps(false, true, true)]);
        for end in 0..valid.len() {
            assert!(!has_wavefront(&valid[..end]));
        }
        assert!(!has_wavefront(&hvcc(&[])));
        for (offset, value) in [(0, 0), (21, 2), (23, 0x62), (27, 0xff), (28, 0x45), (29, 9)] {
            let mut bad = valid.clone();
            bad[offset] = value;
            assert!(!has_wavefront(&bad), "offset {offset}");
        }
        let mut trailing = valid.clone();
        trailing.push(0);
        assert!(!has_wavefront(&trailing));
        assert!(!has_wavefront(&hvcc(&[vec![68, 1, 0, 0, 0, 0, 0]])));
    }

    #[test]
    fn escaped_bytes_and_truncated_golomb_codes_are_bounded() {
        assert_eq!(unescape(&[0, 0, 3, 0, 0, 3, 1]), Some(vec![0, 0, 0, 0, 1]));
        for bad in [&[0, 0, 3][..], &[0, 0, 3, 4], &[0, 0, 0]] {
            assert!(unescape(bad).is_none());
        }
        assert_eq!(
            Bits {
                data: &[0xff],
                position: 0
            }
            .ue(),
            Some(0)
        );
        assert!(
            Bits {
                data: &[0; 5],
                position: 0
            }
            .ue()
            .is_none()
        );
        assert!(
            Bits {
                data: &[0],
                position: 0
            }
            .ue()
            .is_none()
        );
    }
}
