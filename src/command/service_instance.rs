//! Hold an OS file lock for the lifetime of the preview service.
use std::{fs::File, fs::OpenOptions, fs::TryLockError, io, path::Path};

pub(super) fn acquire() -> io::Result<Option<File>> {
    lock(&std::env::temp_dir().join("vimg-preview-service.lock"))
}

fn lock(path: &Path) -> io::Result<Option<File>> {
    // Keep the file on disk: removing it on shutdown would let another process
    // lock a different file at the same path. The OS releases locks on exit,
    // including crashes, so an existing file is never a stale instance marker.
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn excludes_duplicates_and_releases_on_drop() {
        let path = std::env::temp_dir().join(format!("vimg-lock-test-{}.lock", fastrand::u64(..)));
        let first = lock(&path).unwrap().unwrap();
        assert!(lock(&path).unwrap().is_none());
        drop(first);
        let next = lock(&path).unwrap().unwrap();
        drop(next);
        std::fs::remove_file(path).unwrap();
    }
}
