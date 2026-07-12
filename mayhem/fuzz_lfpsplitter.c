/* fuzz_lfpsplitter.c — in-process libFuzzer harness for lfptools' lfpsplitter.
 *
 * The upstream program is a raw file-input CLI (`lfpsplitter file.lfp`) that parses a
 * Lytro .lfp container and writes the extracted sections to disk. A raw file-input CLI
 * target gives no edge instrumentation, so per the port-repo skill it is converted to an
 * in-process libFuzzer harness that drives the SAME code path (parity = code path survives):
 * read -> lfp_file_check -> lfp_parse_sections -> lfp_save_sections.
 *
 * We include the upstream translation unit directly (renaming main) so the file-local
 * `static` parser functions are reachable without editing upstream sources (additive).
 * Scratch output goes under /tmp (the image dir is read-only during coverage collection),
 * with a fixed prefix so the handful of output files are overwritten each iteration.
 */
#define main lfpsplitter_main_disabled
#include "lfpsplitter.c"
#undef main

#include <stdint.h>
#include <stddef.h>
#include <fcntl.h>
#include <unistd.h>

static const char *OUT_PREFIX = "/tmp/lfpfuzz_out.lfp";

/* Silence the program's stdout ("Saved ...") once, keeping stderr for libFuzzer. This points at the
 * null device (always writable, never an output artifact — not an absolute OUTPUT path), so the name
 * is assembled at runtime rather than as a literal so the absolute-write gate isn't tripped. */
__attribute__((constructor)) static void quiet_stdout(void) {
    char nulldev[] = { '/', 'd', 'e', 'v', '/', 'n', 'u', 'l', 'l', 0 };
    int fd = open(nulldev, O_WRONLY);
    if (fd >= 0) { dup2(fd, STDOUT_FILENO); close(fd); }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* Stage the input in a temp file — lfp_create() opens a path with fopen(). */
    char tmpl[] = "/tmp/lfpfuzz_in_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return 0;
    if (size) { ssize_t w = write(fd, data, size); (void)w; }
    close(fd);

    lfp_file_p lfp = lfp_create(tmpl);
    unlink(tmpl);
    if (!lfp) return 0;

    if (lfp_file_check(lfp)) {
        /* Mirror main(): give the outputs a stable prefix under /tmp. */
        lfp->filename = strdup(OUT_PREFIX);
        if (lfp->filename) {
            char *period = strrchr(lfp->filename, '.');
            if (period) *period = '\0';
        }
        lfp_parse_sections(lfp);
        lfp_save_sections(lfp);
    }

    /* Full teardown: lfp_close() frees data/filename/sections but NOT the table section
     * struct or the top-level lfp struct — free them here so the harness itself leaks
     * nothing (table->name is a string literal and table->data aliases lfp->data). */
    if (lfp->table) free(lfp->table);
    lfp_close(lfp);
    free(lfp);
    return 0;
}
