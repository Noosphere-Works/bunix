/*
 * bunix-unpack <tarball> <directory>: extracts an npm tarball the way bun
 * 1.4.2's installer does, through the same library (libarchive) and the
 * same loop: `Archiver::extract_to_dir` in bun's src/libarchive/lib.rs,
 * called with `npm: true` and `depth_to_skip: 1` from
 * src/install/extract_tarball.rs (src/install/TarballStream.rs applies the
 * same rules to streamed tarballs).
 *
 * - The reader takes tar and GNU tar formats with gzip, and reads past
 *   zero blocks (`read_concatenated_archives`), as `BufferReadStream`
 *   opens it.
 * - Only entries libarchive classifies as regular files are written.
 *   Directories, symlinks, hard links without a body, devices and FIFOs
 *   are skipped, as npm's pacote does; a directory exists only as the
 *   parent of a file.
 * - The first path component is dropped and the rest normalised: `.`
 *   and repeated `/` go, `..` takes the previous component off, and a
 *   `..` at the package root is dropped. An entry that leaves nothing is
 *   skipped, as is one whose path does not fit in PATH_MAX.
 * - A file is created with mode (entry permissions & 0777) | 0666, under
 *   the process umask, and truncated if it exists, so a later entry for
 *   the same path replaces an earlier one's contents.
 */
#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fail(const char *what, const char *detail) {
  fprintf(stderr, "bunix-unpack: %s: %s\n", what, detail);
  return 1;
}

/* Resolves `.`, `..` and empty components of a relative path in place.
 * A `..` at the root is dropped, as bun's `normalize_buf_t` does, so the
 * result never leaves the package directory. */
static void normalise(char *path) {
  char *out = path;
  char *in = path;
  size_t depth = 0;
  while (*in != '\0') {
    char *end = strchr(in, '/');
    size_t len = end ? (size_t)(end - in) : strlen(in);
    if (len == 0 || (len == 1 && in[0] == '.')) {
      /* skip */
    } else if (len == 2 && in[0] == '.' && in[1] == '.') {
      if (depth > 0) {
        depth--;
        while (out > path && out[-1] != '/')
          out--;
        if (out > path)
          out--;
      }
    } else {
      if (out > path)
        *out++ = '/';
      memmove(out, in, len);
      out += len;
      depth++;
    }
    in += len;
    if (*in == '/')
      in++;
  }
  *out = '\0';
}

/* mkdir -p of `path` under `dir`. */
static void make_path(int dir, char *path) {
  for (char *p = path;; p++) {
    if (*p == '/' || *p == '\0') {
      char saved = *p;
      *p = '\0';
      mkdirat(dir, path, 0777);
      *p = saved;
      if (saved == '\0')
        return;
    }
  }
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: bunix-unpack <tarball> <directory>\n");
    return 2;
  }
  int dir = open(argv[2], O_RDONLY | O_DIRECTORY);
  if (dir < 0)
    return fail(argv[2], strerror(errno));

  struct archive *a = archive_read_new();
  archive_read_support_format_tar(a);
  archive_read_support_format_gnutar(a);
  archive_read_support_filter_gzip(a);
  archive_read_set_options(a, "read_concatenated_archives");
  if (archive_read_open_filename(a, argv[1], 65536) != ARCHIVE_OK)
    return fail(argv[1], archive_error_string(a));

  char path[PATH_MAX];
  for (;;) {
    struct archive_entry *entry;
    int r = archive_read_next_header(a, &entry);
    if (r == ARCHIVE_EOF)
      break;
    if (r == ARCHIVE_RETRY)
      continue;
    if (r < ARCHIVE_WARN)
      return fail(argv[1], archive_error_string(a));

    if (archive_entry_filetype(entry) != AE_IFREG)
      continue;

    /* Drop the first component (`package/`, or a scope's name). */
    const char *name = archive_entry_pathname(entry);
    if (name == NULL)
      continue;
    while (*name == '/')
      name++;
    if (*name == '\0')
      continue;
    while (*name != '\0' && *name != '/')
      name++;
    while (*name == '/')
      name++;
    if (strlen(name) >= sizeof(path))
      continue;
    strcpy(path, name);
    normalise(path);
    if (path[0] == '\0')
      continue;

    mode_t mode = (archive_entry_perm(entry) & 0777) | 0666;
    int fd = openat(dir, path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0 && (errno == EACCES || errno == EPERM || errno == ENOENT)) {
      char *slash = strrchr(path, '/');
      if (slash == NULL)
        return fail(path, strerror(errno));
      *slash = '\0';
      make_path(dir, path);
      *slash = '/';
      fd = openat(dir, path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    }
    if (fd < 0)
      return fail(path, strerror(errno));

    if (archive_entry_size(entry) > 0) {
      const void *block;
      size_t size;
      la_int64_t offset;
      while ((r = archive_read_data_block(a, &block, &size, &offset)) == ARCHIVE_OK) {
        const char *bytes = block;
        while (size > 0) {
          ssize_t written = pwrite(fd, bytes, size, offset);
          if (written < 0)
            return fail(path, strerror(errno));
          bytes += written;
          size -= (size_t)written;
          offset += written;
        }
      }
      if (r != ARCHIVE_EOF)
        return fail(path, archive_error_string(a));
    }
    close(fd);
  }
  archive_read_free(a);
  return 0;
}
