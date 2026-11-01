use std::path::Path;

pub fn schedule(home: &Path) {
    #[cfg(all(unix, not(any(target_os = "android", target_env = "ohos"))))]
    {
        use std::sync::atomic::{AtomicBool, Ordering};
        static PENDING: AtomicBool = AtomicBool::new(false);
        if unsafe { libc::getuid() } == 0
            || unsafe { libc::geteuid() } != 0
            || PENDING.swap(true, Ordering::AcqRel)
        {
            return;
        }
        let home = home.to_path_buf();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            let _ = tokio::task::spawn_blocking(move || reclaim(&home)).await;
            PENDING.store(false, Ordering::Release);
        });
    }
    #[cfg(not(all(unix, not(any(target_os = "android", target_env = "ohos")))))]
    let _ = home;
}

#[cfg(all(unix, not(any(target_os = "android", target_env = "ohos"))))]
pub fn reclaim(home: &Path) {
    use std::os::unix::fs::MetadataExt;
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };
    if uid == 0 || unsafe { libc::geteuid() } != 0 {
        return;
    }
    let Ok(root) = home.symlink_metadata() else {
        return;
    };
    if !root.is_dir() || root.uid() != uid {
        return;
    }
    let mut directories = vec![home.to_path_buf()];
    while let Some(directory) = directories.pop() {
        let Ok(entries) = std::fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(metadata) = path.symlink_metadata() else {
                continue;
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                directories.push(path.clone());
            }
            let _ = reclaim_entry(&path, &metadata, uid, gid);
        }
    }
}

#[cfg(not(all(unix, not(any(target_os = "android", target_env = "ohos")))))]
pub fn reclaim(_home: &Path) {}

#[cfg(all(unix, not(any(target_os = "android", target_env = "ohos"))))]
pub fn reclaim_path(home: &Path, path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let uid = unsafe { libc::getuid() };
    if uid == 0 || unsafe { libc::geteuid() } != 0 {
        return Ok(());
    }
    let root = home.symlink_metadata()?;
    if !root.is_dir() || root.uid() != uid || !path.starts_with(home) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Ownership path is outside the app-owned home",
        ));
    }
    reclaim_entry(path, &path.symlink_metadata()?, uid, unsafe {
        libc::getgid()
    })
}

#[cfg(not(all(unix, not(any(target_os = "android", target_env = "ohos")))))]
pub fn reclaim_path(_home: &Path, _path: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(all(unix, not(any(target_os = "android", target_env = "ohos"))))]
fn reclaim_entry(
    path: &Path,
    metadata: &std::fs::Metadata,
    uid: libc::uid_t,
    gid: libc::gid_t,
) -> std::io::Result<()> {
    use std::{
        ffi::CString,
        os::unix::{ffi::OsStrExt, fs::MetadataExt},
    };
    if metadata.uid() == uid || !(metadata.is_dir() || metadata.is_file() && metadata.nlink() == 1)
    {
        return Ok(());
    }
    let name = CString::new(path.as_os_str().as_bytes())?;
    let fd = unsafe {
        libc::open(
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let result = (|| {
        let mut actual = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe { libc::fstat(fd, actual.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        let actual = unsafe { actual.assume_init() };
        if actual.st_dev as u64 == metadata.dev()
            && actual.st_ino as u64 == metadata.ino()
            && (actual.st_mode & libc::S_IFMT == libc::S_IFDIR
                || actual.st_mode & libc::S_IFMT == libc::S_IFREG && actual.st_nlink == 1)
            && unsafe { libc::fchown(fd, uid, gid) } != 0
        {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    })();
    unsafe {
        libc::close(fd);
    }
    result
}
