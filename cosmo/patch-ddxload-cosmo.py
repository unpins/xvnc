#!/usr/bin/env python3
# Cosmo variant of patch-ddxload.py. Same goal -- rewrite RunXkbComp() to compile
# the keymap IN-PROCESS via fork()+unpin_xkbcomp_main() instead of Popen()ing an
# external xkbcomp -- but adapted to cosmo/Windows constraints:
#   * No memfd_create on Windows (syscall returns -1) -> use mkstemp temp files
#     in TMPDIR (cosmo maps to %TEMP%).
#   * Windows forbids unlinking a file that still has an open handle, so we do
#     NOT unlink-while-open. The parent unlinks the spec right after fork, and
#     for the compiled .xkm it reads the whole file into memory, closes+unlinks,
#     then hands XkbDDXOpenConfigFile() an fmemopen() of that buffer -- no
#     lingering handle, nothing left on disk.
# fork() + the embedded /zip zipos survive across fork on cosmo (the child
# re-execs and restores its image; the zip is read from the on-disk binary),
# proven by the zsh cosmo port.
import sys

p = 'xkb/ddxLoad.c'
s = open(p).read()

anchor = '#define\tXKBSRV_NEED_FILE_FUNCS\n'
assert anchor in s, "ddxLoad.c: XKBSRV_NEED_FILE_FUNCS anchor moved"
s = s.replace(anchor, anchor +
    '#include <sys/wait.h>\n'
    '#include <errno.h>\n'
    '#include <string.h>\n'
    '#include <stdlib.h>\n'
    '#include <unistd.h>\n'
    '#include <stdio.h>\n'
    'extern int unpin_xkbcomp_main(int, char **);\n'
    '/* mkstemp into TMPDIR; returns an open fd and writes the path to pathOut.\n'
    '   Not unlinked here -- Windows cannot unlink an open file; the caller\n'
    '   unlinks once no handle remains. */\n'
    'static int unpin_mkstemp(char *pathOut, size_t cap) {\n'
    '    const char *t = getenv("TMPDIR");\n'
    '    if (!t || !*t) t = getenv("TEMP");\n'
    '    if (!t || !*t) t = "/tmp";\n'
    '    snprintf(pathOut, cap, "%s/unpinxkbXXXXXX", t);\n'
    '    return mkstemp(pathOut);\n'
    '}\n'
    '/* The in-process-compiled .xkm, served from memory to the\n'
    '   XkbDDXOpenConfigFile() call that immediately follows RunXkbComp(). */\n'
    'static FILE *unpin_xkm_file = NULL;\n', 1)

# Replace the whole RunXkbComp body.
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

new_body = r'''{
    char keymap[PATH_MAX];
    char specpath[PATH_MAX], xkmpath[PATH_MAX];
    int specfd, xkmfd;
    FILE *spec;
    pid_t pid;
    int st;

    snprintf(keymap, sizeof(keymap), "server-%s", display);

    /* Temp files in TMPDIR (no memfd on Windows). The fds are plain (not
       CLOEXEC) so the fork inherits them; there is no execve, so nothing
       leaks. */
    specfd = unpin_mkstemp(specpath, sizeof specpath);
    xkmfd = unpin_mkstemp(xkmpath, sizeof xkmpath);
    if (specfd < 0 || xkmfd < 0) {
        LogMessage(X_ERROR, "XKB: unpin_mkstemp failed: %s\n", strerror(errno));
        if (specfd >= 0) { close(specfd); unlink(specpath); }
        if (xkmfd >= 0) { close(xkmfd); unlink(xkmpath); }
        return NULL;
    }

    /* fdopen a dup so fclose() doesn't close specfd (the child inherits it). */
    spec = fdopen(dup(specfd), "w");
    if (!spec) {
        LogMessage(X_ERROR, "XKB: fdopen(spec) failed\n");
        close(specfd); unlink(specpath);
        close(xkmfd); unlink(xkmpath);
        return NULL;
    }
    (*callback)(spec, userdata);
    if (fclose(spec) != 0) {
        LogMessage(X_ERROR, "XKB: error writing keymap spec\n");
        close(specfd); unlink(specpath);
        close(xkmfd); unlink(xkmpath);
        return NULL;
    }
    lseek(specfd, 0, SEEK_SET);

    pid = fork();
    if (pid == 0) {
        char wlvl[8];
        char *av[8];
        int n = 0;
        if (dup2(specfd, 0) < 0 || dup2(xkmfd, 1) < 0)
            _exit(127);
        snprintf(wlvl, sizeof(wlvl), "%d",
                 ((xkbDebugFlags < 2) ? 1 :
                  ((xkbDebugFlags > 10) ? 10 : (int) xkbDebugFlags)));
        av[n++] = (char *) "xkbcomp";
        av[n++] = (char *) "-w";
        av[n++] = wlvl;
        av[n++] = (char *) "-xkm";
        av[n++] = (char *) "-";        /* input  = stdin  (spec) */
        av[n++] = (char *) "-";        /* output = stdout (xkm)  */
        av[n] = NULL;
        _exit(unpin_xkbcomp_main(n, av) == 0 ? 0 : 1);
    }
    close(specfd);
    unlink(specpath);               /* parent is done with the spec */
    if (pid < 0) {
        LogMessage(X_ERROR, "XKB: fork for in-process xkbcomp failed\n");
        close(xkmfd); unlink(xkmpath);
        return NULL;
    }
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
        ;
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
        /* Read the compiled .xkm fully, then close+unlink so no handle lingers
           (Windows can't delete an open file), and serve it from memory. */
        long sz;
        char *buf;
        lseek(xkmfd, 0, SEEK_END);
        sz = (long) lseek(xkmfd, 0, SEEK_CUR);
        lseek(xkmfd, 0, SEEK_SET);
        if (sz <= 0 || (buf = malloc((size_t) sz)) == NULL) {
            close(xkmfd); unlink(xkmpath);
            LogMessage(X_ERROR, "XKB: empty/oom .xkm (%s)\n", keymap);
            return NULL;
        }
        {
            long got = 0;
            while (got < sz) {
                ssize_t r = read(xkmfd, buf + got, (size_t) (sz - got));
                if (r <= 0) break;
                got += r;
            }
            sz = got;
        }
        close(xkmfd);
        unlink(xkmpath);
        if (unpin_xkm_file)
            fclose(unpin_xkm_file);
        unpin_xkm_file = fmemopen(buf, (size_t) sz, "rb");
        if (!unpin_xkm_file) { free(buf); return NULL; }
        if (xkbDebugFlags)
            DebugF("[xkb] in-process xkbcomp compiled %s\n", keymap);
        return xnfstrdup(keymap);
    }
    close(xkmfd);
    unlink(xkmpath);
    LogMessage(X_ERROR, "Error compiling keymap (%s) in-process\n", keymap);
    return NULL;
}'''

s = s[:brace] + new_body + s[j + 1:]

# XkbDDXOpenConfigFile: consume the in-memory .xkm RunXkbComp just produced.
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
    "    /* In-process compile just produced the .xkm in memory. */\n"
    "    if (unpin_xkm_file != NULL) {\n"
    "        FILE *f = unpin_xkm_file;\n"
    "        unpin_xkm_file = NULL;\n"
    "        if (fileNameRtrn != NULL && fileNameRtrnLen > 0)\n"
    "            fileNameRtrn[0] = '\\0';\n"
    "        return f;\n"
    "    }\n"
    "\n"
    "    buf[0] = '\\0';\n", 1)

open(p, 'w').write(s)
print('unpins(cosmo): RunXkbComp compiles in-process via mkstemp+fork+fmemopen')
