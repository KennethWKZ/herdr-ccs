//! herdr-ccs-marker: the Claude Code SessionStart hook that tags ccs-started sessions, as a binary.
//!
//! Usage (the generated hook script execs it): `herdr-ccs-marker <markers dir>` with the hook input on stdin.
//!
//! Same result as the shell version of the hook, which stays as the fallback:
//! - only for sessions ccs started (ANTHROPIC_AUTH_TOKEN=ccs-internal-managed); others are left alone;
//! - the session id is the last top-level `"session_id":"<id>"` in the input, an id of 1 to 128 of
//!   [A-Za-z0-9-] (it names a file in the markers dir, so nothing else is accepted);
//! - the ccs profile is read off the launching `ccs <profile> ...` process: up to 8 parents, where argv[0] or
//!   argv[1] is `ccs` or ends in `/ccs`, then the first argument not starting with `-`; a profile with other
//!   characters than [A-Za-z0-9._-] is dropped;
//! - the marker file gets `profile=<p>` and, when ccs exposed its browser tools, `browser=1`.
//!
//! The shell version called `ps` twice per parent, and each call cost 0.1 to 0.5 s inside the hook on a busy
//! Mac; this reads the parent chain from the kernel (macOS: proc_pidinfo and KERN_PROCARGS2; Linux: /proc).
//! It never fails the session: every error just leaves the session untagged, and it always exits 0.

use std::io::Read;

fn main() {
    let Some(dir) = std::env::args().nth(1) else {
        return;
    };
    let mut input = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut input);
    if std::env::var("ANTHROPIC_AUTH_TOKEN").ok().as_deref() != Some("ccs-internal-managed") {
        return;
    }
    let Some(sid) = session_id(&input) else {
        return;
    };
    let profile = ccs_profile(parent_pid()).filter(|p| {
        p.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
    });
    let mut body = String::new();
    if let Some(p) = profile.filter(|p| !p.is_empty()) {
        body.push_str(&format!("profile={p}\n"));
    }
    if std::env::var_os("CCS_BROWSER_DEVTOOLS_HTTP_URL").is_some_and(|v| !v.is_empty()) {
        body.push_str("browser=1\n");
    }
    if std::fs::create_dir_all(&dir).is_ok() {
        let _ = std::fs::write(std::path::Path::new(&dir).join(&sid), body);
    }
}

/// `[[:space:]]` in the shell version's sed (after its `tr '\n\r' '  '`).
fn space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r')
}

/// The id the shell version's sed picks: `.*[{,][[:space:]]*"session_id"[[:space:]]*:[[:space:]]*"(ID)".*`,
/// greedy, so the last place where the whole pattern fits.
pub fn session_id(input: &[u8]) -> Option<String> {
    let mut found = None;
    for (i, &b) in input.iter().enumerate() {
        if b != b'{' && b != b',' {
            continue;
        }
        let mut j = i + 1;
        while j < input.len() && space(input[j]) {
            j += 1;
        }
        let Some(rest) = input
            .get(j..)
            .and_then(|r| r.strip_prefix(b"\"session_id\""))
        else {
            continue;
        };
        let mut k = input.len() - rest.len();
        while k < input.len() && space(input[k]) {
            k += 1;
        }
        if input.get(k) != Some(&b':') {
            continue;
        }
        k += 1;
        while k < input.len() && space(input[k]) {
            k += 1;
        }
        if input.get(k) != Some(&b'"') {
            continue;
        }
        let start = k + 1;
        let mut end = start;
        while end < input.len() && (input[end].is_ascii_alphanumeric() || input[end] == b'-') {
            end += 1;
        }
        if end > start && end - start <= 128 && input.get(end) == Some(&b'"') {
            found = Some(String::from_utf8_lossy(&input[start..end]).into_owned());
        }
    }
    found
}

/// The ccs profile from the parent chain starting at `pid`, as the shell version's ccs_profile().
fn ccs_profile(mut pid: i32) -> Option<String> {
    let is_ccs = |w: &str| w == "ccs" || w.ends_with("/ccs");
    for _ in 0..8 {
        if pid <= 1 {
            return None;
        }
        // `set -- $(ps -o args= -p PID)`: the arguments as ps prints them, split on whitespace.
        let words: Vec<String> = proc_args(pid)?
            .split_whitespace()
            .map(str::to_string)
            .collect();
        let skip = if words.first().is_some_and(|w| is_ccs(w)) {
            1
        } else if words.get(1).is_some_and(|w| is_ccs(w)) {
            2
        } else {
            pid = parent_of(pid)?;
            continue;
        };
        return Some(
            words
                .iter()
                .skip(skip)
                .find(|a| !a.starts_with('-'))
                .cloned()
                .unwrap_or_default(),
        );
    }
    None
}

#[cfg(target_os = "macos")]
mod sys {
    use std::ffi::c_void;

    extern "C" {
        fn getppid() -> i32;
        fn proc_pidinfo(pid: i32, flavor: i32, arg: u64, buffer: *mut c_void, size: i32) -> i32;
        fn sysctl(
            name: *mut i32,
            namelen: u32,
            old: *mut c_void,
            oldlen: *mut usize,
            new: *mut c_void,
            newlen: usize,
        ) -> i32;
    }

    const PROC_PIDTBSDINFO: i32 = 3;
    const PROC_BSDINFO_SIZE: usize = 136; // struct proc_bsdinfo; pbi_ppid is the fifth u32
    const CTL_KERN: i32 = 1;
    const KERN_PROCARGS2: i32 = 49;
    const KERN_ARGMAX: i32 = 8;

    pub fn parent_pid() -> i32 {
        // SAFETY: no arguments, no memory.
        unsafe { getppid() }
    }

    pub fn parent_of(pid: i32) -> Option<i32> {
        let mut buf = [0u8; PROC_BSDINFO_SIZE];
        // SAFETY: the buffer is the size we pass.
        let n = unsafe {
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                buf.as_mut_ptr().cast(),
                buf.len() as i32,
            )
        };
        if n as usize != PROC_BSDINFO_SIZE {
            return None;
        }
        Some(u32::from_ne_bytes(buf[16..20].try_into().ok()?) as i32)
    }

    /// argv joined by spaces, as `ps -o args=` prints it.
    pub fn proc_args(pid: i32) -> Option<String> {
        let mut argmax: i32 = 0;
        let mut len = std::mem::size_of::<i32>();
        let mut mib = [CTL_KERN, KERN_ARGMAX];
        // SAFETY: argmax is an i32 and len says so.
        if unsafe {
            sysctl(
                mib.as_mut_ptr(),
                2,
                (&mut argmax as *mut i32).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return None;
        }
        let mut buf = vec![0u8; argmax.max(4096) as usize];
        let mut size = buf.len();
        let mut mib = [CTL_KERN, KERN_PROCARGS2, pid];
        // SAFETY: the buffer is `size` bytes long.
        if unsafe {
            sysctl(
                mib.as_mut_ptr(),
                3,
                buf.as_mut_ptr().cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return None;
        }
        let buf = &buf[..size];
        let argc = i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?) as usize;
        // After argc: the exec path, NUL padding, then argc NUL-terminated arguments.
        let mut i = 4 + buf[4..].iter().position(|&b| b == 0)?;
        while i < buf.len() && buf[i] == 0 {
            i += 1;
        }
        let args: Vec<String> = buf[i..]
            .split(|&b| b == 0)
            .take(argc)
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        Some(args.join(" "))
    }
}

#[cfg(target_os = "linux")]
mod sys {
    pub fn parent_pid() -> i32 {
        std::os::unix::process::parent_id() as i32
    }

    pub fn parent_of(pid: i32) -> Option<i32> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        // pid (comm) state ppid ...: comm can hold spaces and parentheses, so read after the last ')'.
        stat.rsplit_once(')')?
            .1
            .split_whitespace()
            .nth(1)?
            .parse()
            .ok()
    }

    pub fn proc_args(pid: i32) -> Option<String> {
        let raw = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
        let args: Vec<String> = raw
            .split(|&b| b == 0)
            .filter(|a| !a.is_empty())
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        Some(args.join(" "))
    }
}

use sys::{parent_of, parent_pid, proc_args};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_id_like_the_sed() {
        let id = "1a2b3c4d-0000-4000-8000-00000000abcd";
        assert_eq!(
            session_id(format!("{{\"session_id\":\"{id}\"}}").as_bytes()).as_deref(),
            Some(id)
        );
        assert_eq!(
            session_id(format!("{{\n  \"a\": 1,\n  \"session_id\" :\t\"{id}\"\n}}").as_bytes())
                .as_deref(),
            Some(id)
        );
        let escaped =
            format!("{{\"cwd\":\"/a\\\",\\\"session_id\\\":\\\"fake\",\"session_id\":\"{id}\"}}");
        assert_eq!(session_id(escaped.as_bytes()).as_deref(), Some(id));
        for bad in ["../../x", "a/b", ".h", "x y", ""] {
            assert_eq!(
                session_id(format!("{{\"session_id\":\"{bad}\"}}").as_bytes()),
                None,
                "{bad}"
            );
        }
        assert_eq!(
            session_id(format!("{{\"session_id\":\"{}\"}}", "a".repeat(129)).as_bytes()),
            None
        );
        assert_eq!(session_id(b"not json"), None);
        // Greedy: the last one that fits.
        assert_eq!(
            session_id(b"{\"session_id\":\"first\",\"session_id\":\"second\"}").as_deref(),
            Some("second")
        );
    }

    #[test]
    fn reads_own_process() {
        let me = std::process::id() as i32;
        assert!(proc_args(me).is_some());
        assert_eq!(parent_of(me), Some(parent_pid()));
    }
}
