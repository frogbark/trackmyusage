/*
 * TrackMyUsage in-bundle launcher.
 *
 * Claude Desktop hardcodes app.setName("Claude"), so CFBundleName cannot steer
 * Electron's userData path -- every clone would otherwise open the primary's
 * profile. This shim is installed as CFBundleExecutable and re-execs the real
 * Electron binary (a sibling in the same Contents/MacOS) with --user-data-dir
 * injected.
 *
 * Why exec a sibling rather than an external binary: after execv the process
 * image changes but the enclosing bundle does not, so LaunchServices, TCC, and
 * the Dock all continue to see this clone's own CFBundleIdentifier. Exec'ing
 * another app's binary -- what Parall does -- is precisely what collapses two
 * instances onto one identity.
 *
 * Compile with -DREAL_BINARY=... -DUSER_DATA_DIR=...
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <mach-o/dyld.h>

#ifndef REAL_BINARY
#error "REAL_BINARY must be defined"
#endif
#ifndef USER_DATA_DIR
#error "USER_DATA_DIR must be defined"
#endif

#define FLAG "--user-data-dir="

int main(int argc, char *argv[]) {
    char self[PATH_MAX];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) {
        fprintf(stderr, "tmu: executable path too long\n");
        return 127;
    }

    /* Trim to the containing directory without mutating via dirname(). */
    char *slash = strrchr(self, '/');
    if (!slash) {
        fprintf(stderr, "tmu: unexpected executable path\n");
        return 127;
    }
    *slash = '\0';

    char real[PATH_MAX];
    if (snprintf(real, sizeof(real), "%s/%s", self, REAL_BINARY) >= (int)sizeof(real)) {
        fprintf(stderr, "tmu: target path too long\n");
        return 127;
    }

    /* Respect an explicit --user-data-dir from the caller (e.g. the GUI). */
    int already = 0;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], FLAG, strlen(FLAG)) == 0) { already = 1; break; }
    }

    char **out = calloc((size_t)argc + 2, sizeof(char *));
    if (!out) { fprintf(stderr, "tmu: out of memory\n"); return 127; }

    int n = 0;
    out[n++] = real;
    if (!already) out[n++] = (char *)(FLAG USER_DATA_DIR);
    for (int i = 1; i < argc; i++) out[n++] = argv[i];
    out[n] = NULL;

    execv(real, out);

    /* execv only returns on failure. */
    perror("tmu: execv");
    return 127;
}
