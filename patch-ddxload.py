#!/usr/bin/env python3
# Rewrite the X server's RunXkbComp() so that, instead of Popen()ing the
# external `xkbcomp` binary, it compiles the keymap IN-PROCESS by forking and
# calling the vendored `unpin_xkbcomp_main()`. The fork keeps our binary image
# (and the embedded /zip VFS), so xkbcomp's include reads resolve from the
# baked-in xkeyboard-config tree -- no external program, no on-disk data tree.
# Globals in xkbcomp accumulate across compiles; the fork gives each compile a
# fresh address space, sidestepping its non-reentrancy for free.
#
# Beyond dropping the subprocess, this version also removes the on-disk handoff
# entirely: stock RunXkbComp writes the keymap spec and the compiled .xkm to
# files under xkb_output_dir (/tmp), and the immediately-following
# XkbDDXOpenConfigFile() reads the .xkm back from there. We replace BOTH files
# with anonymous fds from unpin_anon_fd() (memfd on Linux, mkstemp+unlink on
# macOS -- portable, mirrors unpin-vfs):
#   * spec  -> anon fd, materialized fully before the fork (no pipe => no
#              deadlock); the forked xkbcomp reads it on stdin (dup2 + "-").
#   * .xkm  -> anon fd, written by the forked xkbcomp on stdout (dup2 + "-")
#              and handed (as an open fd) straight to XkbDDXOpenConfigFile.
# fmemopen() can't be used here: its buffer lives in the process heap and is
# NOT shared across fork(). An anon fd is a real (kernel- or inode-backed)
# descriptor, inherited by the child, so its writes are visible to the parent.
# Net effect on Linux: keyboard compilation never touches disk; on macOS it
# uses one unlinked temp inode (no name, gone on close).
import sys

p = 'xkb/ddxLoad.c'
s = open(p).read()

# 1. Pull in waitpid/errno/memfd + declare the vendored entry point, plus the
#    single static fd that hands the compiled .xkm from RunXkbComp to the
#    immediately-following XkbDDXOpenConfigFile (XKB compile is single-threaded
#    in dix, so one static is safe). Anchor after the existing
#    XKBSRV_NEED_FILE_FUNCS define so we land past the include block.
anchor = '#define\tXKBSRV_NEED_FILE_FUNCS\n'
assert anchor in s, "ddxLoad.c: XKBSRV_NEED_FILE_FUNCS anchor moved"
s = s.replace(anchor, anchor +
    '#include <sys/wait.h>\n'
    '#include <errno.h>\n'
    '#include <string.h>\n'
    '#include <stdlib.h>\n'
    '#include <unistd.h>\n'
    '#include <sys/syscall.h>\n'
    'extern int unpin_xkbcomp_main(int, char **);\n'
    '/* Anonymous, seekable, fork-inheritable fd -- mirrors the unpin-vfs\n'
    '   anon_fd(): a real kernel memfd on Linux, mkstemp + immediate unlink on\n'
    '   macOS (no memfd_create there). The unlinked temp inode has link count 0\n'
    '   (no on-disk name, gone on close) and survives fork() as a shared fd to a\n'
    '   real inode. Plain flags (not CLOEXEC) so the fork inherits it; no execve,\n'
    '   so nothing leaks. */\n'
    'static int unpin_anon_fd(const char *tag) {\n'
    '#if defined(__APPLE__)\n'
    '    const char *t = getenv("TMPDIR");\n'
    '    if (!t || !*t) t = "/tmp";\n'
    '    char tmpl[1024];\n'
    '    snprintf(tmpl, sizeof tmpl, "%s/unpinxkbXXXXXX", t);\n'
    '    int fd = mkstemp(tmpl);\n'
    '    if (fd >= 0) unlink(tmpl);\n'
    '    (void) tag;\n'
    '    return fd;\n'
    '#else\n'
    '    return (int) syscall(SYS_memfd_create, tag, 0u);\n'
    '#endif\n'
    '}\n'
    '/* fd of the in-process-compiled .xkm (an anonymous fd from unpin_anon_fd),\n'
    '   passed from RunXkbComp() to the XkbDDXOpenConfigFile() call that\n'
    '   immediately follows it in both load paths. -1 when none is pending. */\n'
    'static int unpin_xkm_memfd = -1;\n', 1)

# 2. Replace the whole RunXkbComp function body. Find the function, then
#    brace-match from its opening { to the matching }.
sig = 'RunXkbComp(xkbcomp_buffer_callback callback, void *userdata)'
i = s.index(sig)
brace = s.index('{', i)
depth = 0
j = brace
while True:
    c = s[j]
    if c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            break
    j += 1
# s[brace:j+1] is the full { ... } body of RunXkbComp.

new_body = r'''{
    char keymap[PATH_MAX];
    int specfd, xkmfd;
    FILE *spec;
    pid_t pid;
    int st;

    snprintf(keymap, sizeof(keymap), "server-%s", display);

    /* Keymap I/O goes through anonymous fds (unpin_anon_fd): a kernel memfd on
       Linux -- never touches disk -- or an unlinked temp inode on macOS. The
       fds are plain (not CLOEXEC) so the fork below inherits them; there is no
       execve, so nothing leaks. */
    specfd = unpin_anon_fd("xkb-spec");
    xkmfd = unpin_anon_fd("xkb-xkm");
    if (specfd < 0 || xkmfd < 0) {
        LogMessage(X_ERROR, "XKB: unpin_anon_fd failed: %s\n", strerror(errno));
        if (specfd >= 0) close(specfd);
        if (xkmfd >= 0) close(xkmfd);
        return NULL;
    }

    /* Write the keymap spec (xkb text + component includes) fully into the
       memfd before forking -- no pipe, so no writer/reader deadlock. fdopen a
       dup so fclose() doesn't close specfd (the child must still inherit it). */
    spec = fdopen(dup(specfd), "w");
    if (!spec) {
        LogMessage(X_ERROR, "XKB: fdopen(spec memfd) failed\n");
        close(specfd);
        close(xkmfd);
        return NULL;
    }
    (*callback)(spec, userdata);
    if (fclose(spec) != 0) {
        LogMessage(X_ERROR, "XKB: error writing keymap spec\n");
        close(specfd);
        close(xkmfd);
        return NULL;
    }
    lseek(specfd, 0, SEEK_SET);

    pid = fork();
    if (pid == 0) {
        char wlvl[8];
        char *av[8];
        int n = 0;
        /* Feed the spec on stdin and collect the .xkm on stdout, both wired to
           the inherited memfds via dup2. xkbcomp's "-" OUTPUT writes straight
           to stdout and skips the symlink-guard open(O_WRONLY|O_CREAT|O_EXCL)
           it does for NAMED outputs -- that O_EXCL would EEXIST against an
           already-open memfd path. "-" INPUT reads stdin. Net: no /proc, no
           named path, nothing on disk; xkbcomp's own fclose(stdout) flushes
           the binary keymap into the memfd. */
        if (dup2(specfd, 0) < 0 || dup2(xkmfd, 1) < 0)
            _exit(127);
        snprintf(wlvl, sizeof(wlvl), "%d",
                 ((xkbDebugFlags < 2) ? 1 :
                  ((xkbDebugFlags > 10) ? 10 : (int) xkbDebugFlags)));
        av[n++] = (char *) "xkbcomp";
        av[n++] = (char *) "-w";
        av[n++] = wlvl;
        av[n++] = (char *) "-xkm";
        av[n++] = (char *) "-";        /* input  = stdin  (spec memfd) */
        av[n++] = (char *) "-";        /* output = stdout (xkm memfd)  */
        av[n] = NULL;
        _exit(unpin_xkbcomp_main(n, av) == 0 ? 0 : 1);
    }
    close(specfd);              /* parent is done with the spec */
    if (pid < 0) {
        LogMessage(X_ERROR, "XKB: fork for in-process xkbcomp failed\n");
        close(xkmfd);
        return NULL;
    }
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
        ;
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
        lseek(xkmfd, 0, SEEK_SET);
        if (unpin_xkm_memfd >= 0)  /* defensive: no stale fd should survive */
            close(unpin_xkm_memfd);
        unpin_xkm_memfd = xkmfd;    /* handed to XkbDDXOpenConfigFile() next */
        if (xkbDebugFlags)
            DebugF("[xkb] in-process xkbcomp compiled %s (anon fd)\n", keymap);
        return xnfstrdup(keymap);
    }
    close(xkmfd);
    LogMessage(X_ERROR, "Error compiling keymap (%s) in-process\n", keymap);
    return NULL;
}'''

s = s[:brace] + new_body + s[j + 1:]

# 3. Teach XkbDDXOpenConfigFile to consume the memfd RunXkbComp just handed it,
#    instead of fopen()ing an on-disk .xkm. fdopen takes ownership of the fd, so
#    the caller's later fclose() frees the memfd; fileNameRtrn is cleared so its
#    unlink() is a harmless no-op. The on-disk branch stays as a fallback for
#    explicit precompiled-keymap loads (unpin_xkm_memfd < 0).
ocf_anchor = (
    "    char buf[PATH_MAX], xkm_output_dir[PATH_MAX];\n"
    "    FILE *file;\n"
    "\n"
    "    buf[0] = '\\0';\n"
)
assert ocf_anchor in s, "ddxLoad.c: XkbDDXOpenConfigFile preamble moved"
s = s.replace(ocf_anchor,
    "    char buf[PATH_MAX], xkm_output_dir[PATH_MAX];\n"
    "    FILE *file;\n"
    "\n"
    "    /* In-process compile just handed us the .xkm as an anonymous memfd. */\n"
    "    if (unpin_xkm_memfd >= 0) {\n"
    "        int fd = unpin_xkm_memfd;\n"
    "        unpin_xkm_memfd = -1;\n"
    "        if (fileNameRtrn != NULL && fileNameRtrnLen > 0)\n"
    "            fileNameRtrn[0] = '\\0';\n"
    "        lseek(fd, 0, SEEK_SET);\n"
    "        return fdopen(fd, "
    "\"rb\");\n"
    "    }\n"
    "\n"
    "    buf[0] = '\\0';\n", 1)

open(p, 'w').write(s)
print('unpins: RunXkbComp compiles in-process via memfd (fork, no /tmp)')
