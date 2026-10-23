//! Read a large Matroska video index without materializing subtitle CuePoints.
//!
//! This is deliberately optional: bounded reads and strict structural checks
//! finish before any index is installed. FFmpeg still owns demuxing and decoding.
use ffmpeg_next::{self as ffmpeg, format};

const SEGMENT: u32 = 0x1853_8067;
const SEEK_HEAD: u32 = 0x114d_9b74;
const TRACKS: u32 = 0x1654_ae6b;
const CUES: u32 = 0x1c53_bb6b;
const CLUSTER: u32 = 0x1f43_b675;
const MAX_CUES_BYTES: usize = 4 * 1024 * 1024;
const MAX_ENTRIES: usize = 65_536;

pub(super) struct Stats {
    pub entries: usize,
    pub points: usize,
}

/// The Input owns AVIO for the entire operation. Restore its byte position and
/// error state even when a speculative read rejects a file. A failed restore is
/// an error for the native attempt, since demuxing cannot safely continue there.
pub(super) fn prime(
    input: &mut format::context::Input,
    stream: usize,
) -> Result<Option<Stats>, ffmpeg::Error> {
    if input.nb_streams() < 8 || !input.format().name().split(',').any(|s| s == "matroska") {
        return Ok(None);
    }
    let Some(video) = input.stream(stream) else {
        return Ok(None);
    };
    let expected = match video.parameters().id() {
        ffmpeg::codec::Id::H264 => b"V_MPEG4/ISO/AVC".as_slice(),
        ffmpeg::codec::Id::HEVC => b"V_MPEGH/ISO/HEVC".as_slice(),
        _ => return Ok(None),
    };
    // All pointers are owned by the live Input; no demux calls occur while its
    // stream/index pointers are read. Do not replace an already populated index.
    let (io, old_flags, existing) = unsafe {
        let ctx = input.as_ptr();
        let count = ffmpeg::ffi::avformat_index_get_entries_count(video.as_ptr());
        if !(1..=2).contains(&count) || (*ctx).flags & ffmpeg::ffi::AVFMT_FLAG_IGNIDX != 0 {
            return Ok(None);
        }
        let mut existing = Vec::new();
        for i in 0..count {
            let entry = ffmpeg::ffi::avformat_index_get_entry(video.as_ptr().cast_mut(), i);
            if entry.is_null() {
                return Ok(None);
            }
            existing.push(((*entry).timestamp, (*entry).pos));
        }
        ((*ctx).pb, (*ctx).flags, existing)
    };
    if io.is_null() {
        return Ok(None);
    }
    // AVIO's normal seekability excludes live/network streams without random
    // access. This helper never opens another handle or replaces the input.
    let (saved, size, error, eof) = unsafe {
        if (*io).seekable & ffmpeg::ffi::AVIO_SEEKABLE_NORMAL == 0 {
            return Ok(None);
        }
        (
            ffmpeg::ffi::avio_seek(io, 0, 1),
            ffmpeg::ffi::avio_size(io),
            (*io).error,
            (*io).eof_reached,
        )
    };
    if saved < 0 || size <= 0 {
        return Ok(None);
    }
    let parsed = Source {
        io,
        size: size as u64,
    }
    .index(expected);
    // Restore even after an invalid offset, EOF or malformed element.
    unsafe {
        let restored = ffmpeg::ffi::avio_seek(io, saved, 0);
        if restored != saved {
            return Err(ffmpeg::Error::InvalidData);
        }
        (*io).error = error;
        (*io).eof_reached = eof;
    }
    let Some((entries, points)) = parsed else {
        return Ok(None);
    };
    if points < 2048 || entries.len() < 2 || points < entries.len().saturating_mul(4) {
        return Ok(None);
    }
    // Cross-check the track/time/position mapping against packets FFmpeg already
    // probed. A sparse or inconsistent index simply uses the normal parser.
    if !existing
        .iter()
        .all(|entry| entries.binary_search(entry).is_ok())
    {
        return Ok(None);
    }
    unsafe {
        let st = *(*input.as_mut_ptr()).streams.add(stream);
        for &(timestamp, position) in &entries {
            if ffmpeg::ffi::av_add_index_entry(
                st,
                position,
                timestamp,
                0,
                0,
                ffmpeg::ffi::AVINDEX_KEYFRAME,
            ) < 0
            {
                // Already-added entries are valid; leave IGNIDX unset so the
                // native parser can still populate its normal index.
                return Ok(None);
            }
        }
        // Matroska's deferred Cues parser respects IGNIDX. The complete video
        // index supports both forward lookahead and the existing backward retry.
        (*input.as_mut_ptr()).flags = old_flags | ffmpeg::ffi::AVFMT_FLAG_IGNIDX;
    }
    Ok(Some(Stats {
        entries: entries.len(),
        points,
    }))
}

struct Source {
    io: *mut ffmpeg::ffi::AVIOContext,
    size: u64,
}

impl Source {
    fn read(&mut self, offset: u64, size: usize) -> Option<Vec<u8>> {
        if size > MAX_CUES_BYTES || offset.checked_add(size as u64)? > self.size {
            return None;
        }
        let mut data = vec![0; size];
        // Source is only constructed from the Input's owned, seekable AVIO.
        unsafe {
            if ffmpeg::ffi::avio_seek(self.io, i64::try_from(offset).ok()?, 0) != offset as i64 {
                return None;
            }
            if ffmpeg::ffi::avio_read(self.io, data.as_mut_ptr(), size as i32) != size as i32 {
                return None;
            }
        }
        Some(data)
    }

    fn header(&mut self, offset: u64, limit: u64) -> Option<(u32, u64, u64)> {
        let data = self.read(
            offset,
            usize::try_from(limit.checked_sub(offset)?.min(12)).ok()?,
        )?;
        let (id, id_len) = vint(&data, true)?;
        let (size, size_len) = vint(&data[id_len..], false)?;
        let body = offset.checked_add((id_len + size_len) as u64)?;
        let end = if size == (1u64 << (7 * size_len)) - 1 {
            if id != u64::from(SEGMENT) {
                return None;
            }
            limit
        } else {
            body.checked_add(size)?
        };
        (end <= limit).then_some((id as u32, body, end))
    }

    fn index(&mut self, expected: &[u8]) -> Option<(Vec<(i64, i64)>, usize)> {
        let (id, _, mut offset) = self.header(0, self.size)?;
        if id != 0x1a45_dfa3 || offset > 65_536 {
            return None;
        }
        let (id, segment, end) = self.header(offset, self.size)?;
        if id != SEGMENT {
            return None;
        }
        offset = segment;
        let mut cue_position = None;
        let mut video_track = None;
        // Only inspect the bounded header preceding the first Cluster. Chained
        // SeekHeads, late Tracks and unusual layouts keep FFmpeg's normal path.
        for _ in 0..64 {
            if offset >= end || offset - segment > 1024 * 1024 {
                break;
            }
            let (id, body, next) = self.header(offset, end)?;
            match id {
                CLUSTER => break,
                SEEK_HEAD => {
                    if next - body > 65_536 {
                        return None;
                    }
                    if let Some(position) =
                        seek_position(&self.read(body, (next - body) as usize)?)?
                    {
                        if cue_position.replace(position).is_some() {
                            return None;
                        }
                    }
                }
                TRACKS => {
                    if next - body > 256 * 1024 || video_track.is_some() {
                        return None;
                    }
                    video_track = Some(track_number(
                        &self.read(body, (next - body) as usize)?,
                        expected,
                    )?);
                }
                _ => {}
            }
            if cue_position.is_some() && video_track.is_some() {
                break;
            }
            offset = next;
        }
        let position = segment.checked_add(cue_position?)?;
        let (id, body, finish) = self.header(position, end)?;
        if id != CUES || finish - body < 65_536 || finish - body > MAX_CUES_BYTES as u64 {
            return None;
        }
        let data = self.read(body, (finish - body) as usize)?;
        cue_entries(&data, video_track?, segment, end)
    }
}

fn vint(data: &[u8], id: bool) -> Option<(u64, usize)> {
    let first = *data.first()?;
    let width = first.leading_zeros() as usize + 1;
    if width > if id { 4 } else { 8 } {
        return None;
    }
    let bytes = data.get(..width)?;
    let mut value = u64::from(if id {
        first
    } else {
        first & (0xffu16 >> width) as u8
    });
    for &byte in &bytes[1..] {
        value = (value << 8) | u64::from(byte);
    }
    Some((value, width))
}

struct Elements<'a>(&'a [u8]);

impl<'a> Iterator for Elements<'a> {
    type Item = Option<(u32, &'a [u8])>;
    fn next(&mut self) -> Option<Self::Item> {
        if self.0.is_empty() {
            return None;
        }
        let data = std::mem::take(&mut self.0);
        Some((|| {
            let (id, n) = vint(data, true)?;
            let (size, m) = vint(data.get(n..)?, false)?;
            if size == (1u64 << (7 * m)) - 1 {
                return None;
            }
            let end = (n + m).checked_add(usize::try_from(size).ok()?)?;
            let body = data.get(n + m..end)?;
            self.0 = data.get(end..)?;
            Some((id as u32, body))
        })())
    }
}

fn uint(data: &[u8]) -> Option<u64> {
    if data.is_empty() || data.len() > 8 {
        return None;
    }
    Some(
        data.iter()
            .fold(0, |value, &byte| (value << 8) | u64::from(byte)),
    )
}

fn unique<T>(slot: &mut Option<T>, value: T) -> Option<()> {
    if slot.replace(value).is_some() {
        None
    } else {
        Some(())
    }
}

fn seek_position(data: &[u8]) -> Option<Option<u64>> {
    let mut cues = None;
    for element in Elements(data) {
        let (id, data) = element?;
        if id != 0x4dbb {
            continue;
        }
        let (mut kind, mut position) = (None, None);
        for element in Elements(data) {
            let (id, data) = element?;
            match id {
                0x53ab => unique(&mut kind, uint(data)?)?,
                0x53ac => unique(&mut position, uint(data)?)?,
                _ => {}
            }
        }
        if kind? == u64::from(CUES) {
            unique(&mut cues, position?)?;
        }
    }
    Some(cues)
}

fn track_number(data: &[u8], expected: &[u8]) -> Option<u64> {
    let mut video = None;
    let mut numbers = std::collections::BTreeSet::new();
    for element in Elements(data) {
        let (id, data) = element?;
        if id != 0xae {
            continue;
        }
        let (mut number, mut kind, mut codec, mut scale) = (None, None, None, None);
        for element in Elements(data) {
            let (id, data) = element?;
            match id {
                0xd7 => unique(&mut number, uint(data)?)?,
                0x83 => unique(&mut kind, uint(data)?)?,
                0x86 => unique(&mut codec, data)?,
                0x23314f => {
                    let unit = match data.len() {
                        4 => f32::from_be_bytes(data.try_into().ok()?) == 1.0,
                        8 => f64::from_be_bytes(data.try_into().ok()?) == 1.0,
                        _ => false,
                    };
                    unique(&mut scale, unit)?;
                }
                _ => {}
            }
        }
        let number = number?;
        if number == 0 || !numbers.insert(number) {
            return None;
        }
        if kind? == 1 {
            if codec? != expected || scale == Some(false) {
                return None;
            }
            unique(&mut video, number)?;
        }
    }
    video
}

fn cue_entries(
    data: &[u8],
    video: u64,
    segment: u64,
    end: u64,
) -> Option<(Vec<(i64, i64)>, usize)> {
    let mut entries = Vec::new();
    let mut points = 0usize;
    for element in Elements(data) {
        let (id, data) = element?;
        if id != 0xbb {
            continue;
        }
        points += 1;
        let (mut time, mut position) = (None, None);
        for element in Elements(data) {
            let (id, data) = element?;
            match id {
                0xb3 => unique(&mut time, uint(data)?)?,
                0xb7 => {
                    let (mut track, mut cluster) = (None, None);
                    for element in Elements(data) {
                        let (id, data) = element?;
                        match id {
                            0xf7 => unique(&mut track, uint(data)?)?,
                            0xf1 => unique(&mut cluster, uint(data)?)?,
                            _ => {}
                        }
                    }
                    if track? == video {
                        unique(&mut position, cluster?)?;
                    }
                }
                _ => {}
            }
        }
        let time = i64::try_from(time?).ok()?;
        if let Some(position) = position {
            let position = segment.checked_add(position)?;
            if position >= end || entries.len() == MAX_ENTRIES {
                return None;
            }
            let position = i64::try_from(position).ok()?;
            if entries.last().is_some_and(|&(prev_time, prev_position)| {
                time <= prev_time || position < prev_position
            }) {
                return None;
            }
            entries.push((time, position));
        }
    }
    Some((entries, points))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn element(id: u32, data: &[u8]) -> Vec<u8> {
        let bytes = id.to_be_bytes();
        let first = bytes.iter().position(|&b| b != 0).unwrap();
        let mut out = bytes[first..].to_vec();
        assert!(data.len() < 127);
        out.push(0x80 | data.len() as u8);
        out.extend(data);
        out
    }
    fn cue(time: u8, track: u8, position: u8) -> Vec<u8> {
        element(
            0xbb,
            &[
                element(0xb3, &[time]),
                element(
                    0xb7,
                    &[element(0xf7, &[track]), element(0xf1, &[position])].concat(),
                ),
            ]
            .concat(),
        )
    }

    #[test]
    fn extracts_only_video_positions_without_losing_other_point_count() {
        let data = [cue(0, 1, 10), cue(1, 9, 11), cue(2, 1, 12)].concat();
        assert_eq!(
            cue_entries(&data, 1, 100, 200),
            Some((vec![(0, 110), (2, 112)], 3))
        );
    }

    #[test]
    fn rejects_truncation_unknown_lengths_and_invalid_integers() {
        let data = cue(0, 1, 10);
        for end in 1..data.len() {
            assert!(cue_entries(&data[..end], 1, 100, 200).is_none());
        }
        assert!(Elements(&[0xbb, 0xff]).next().unwrap().is_none());
        assert!(Elements(&[0]).next().unwrap().is_none());
        assert!(uint(&[]).is_none());
        assert!(uint(&[0; 9]).is_none());
    }

    #[test]
    fn rejects_duplicate_times_reversed_positions_and_out_of_bounds() {
        for tail in [cue(0, 1, 12), cue(2, 1, 9), cue(2, 1, 100)] {
            assert!(cue_entries(&[cue(0, 1, 10), tail].concat(), 1, 100, 200).is_none());
        }
        assert!(cue_entries(&cue(0, 1, 10), 1, u64::MAX - 5, u64::MAX).is_none());
    }

    #[test]
    fn accepts_eight_byte_lengths_without_a_shift_overflow() {
        assert_eq!(vint(&[1, 0, 0, 0, 0, 0, 0, 1], false), Some((1, 8)));
        assert!(vint(&[8, 0, 0, 0, 0], true).is_none());
        assert!(
            Elements(&[0xbb, 1, 255, 255, 255, 255, 255, 255, 255])
                .next()
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn requires_unambiguous_video_track_and_unit_timestamp_scale() {
        let codec = b"V_MPEG4/ISO/AVC";
        let fields = [
            element(0xd7, &[1]),
            element(0x83, &[1]),
            element(0x86, codec),
        ]
        .concat();
        let video = element(0xae, &fields);
        assert_eq!(track_number(&video, codec), Some(1));
        assert!(track_number(&[video.clone(), video].concat(), codec).is_none());
        let scaled = element(
            0xae,
            &[fields.clone(), element(0x23314f, &0.5f64.to_be_bytes())].concat(),
        );
        assert!(track_number(&scaled, codec).is_none());
        assert!(track_number(&element(0xae, &fields), b"V_MPEGH/ISO/HEVC").is_none());
    }

    #[test]
    fn duplicate_or_missing_seek_fields_keep_the_native_parser() {
        let kind = element(0x53ab, &CUES.to_be_bytes());
        let seek = element(0x4dbb, &[kind.clone(), element(0x53ac, &[16])].concat());
        assert_eq!(seek_position(&seek), Some(Some(16)));
        assert!(seek_position(&[seek.clone(), seek].concat()).is_none());
        assert!(seek_position(&element(0x4dbb, &kind)).is_none());
    }
}
