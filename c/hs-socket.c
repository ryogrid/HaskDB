/* HaskDB POSIX socket shim (internal-design/11 §11.3).
 *
 *   Decision D-06 chose the `network` package for the Listener socket.
 *   That package is not a GHC boot library and cannot be built on this
 *   toolchain (its Setup needs a statically linked hsc2hs, and no static
 *   gmp exists), so the socket layer is a thin libc shim reached through
 *   GHC's FFI instead — still only libc, i.e. the boot-library-only
 *   constraint of design/00 §0.1 holds again.  Amended as D-24.
 *
 *   Conventions: every failing call returns -errno (never -1), so the
 *   Haskell layer can report the real cause; EINTR is retried in C so the
 *   Haskell layer never sees an interrupted-read as a spurious error.
 */

#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

/* listen: create a INET stream socket bound to INADDR_ANY:port.
   returns the listening descriptor, or -errno. */
int hs_listen(int port)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0)
    return -errno;
  {
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = htons((unsigned short) port);
    if (bind(fd, (struct sockaddr *) &sa, sizeof sa) != 0) {
      int e = errno;
      close(fd);
      return -e;
    }
    /* the socket must be put on the accept queue before accept() can be
       used; PostgreSQL's ListenServerPort does the same (bind then listen).
       Where listen() is unavailable/already applied the socket still accepts,
       so its error is deliberately not fatal. */
    (void) listen(fd, 128);
  }
  return fd;
}

/* accept one stream peer; blocks.  Call it only after hs_conn_pending says a
   connection is ready, so it returns straight away.  Returns the peer
   descriptor or -errno. */
int hs_accept(int fd)
{
  for (;;) {
    int peer = accept(fd, NULL, NULL);
    if (peer >= 0)
      return peer;
    if (errno == EINTR)
      continue;
    return -errno;
  }
}

/* is a connection pending on the listening socket?  1 = yes (accept will not
   block), 0 = not yet, <0 = -errno.

   The listener asks instead of sitting in a blocking accept(): GHC blocks
   SIGINT/SIGTERM for the whole extent of a 'safe' foreign call, so a thread
   parked in accept() never runs §11.5's signal handler and the server cannot
   be shut down (the process just accumulates as an un-killable stale
   postmaster).  Polling from Haskell, with a threadDelay between rounds,
   keeps the thread at an interruptible point. */
int hs_conn_pending(int fd)
{
  struct pollfd p;
  p.fd = fd;
  p.events = POLLIN;
  for (;;) {
    int r = poll(&p, 1, 0);
    if (r >= 0)
      return r;               /* 1 = connection ready, 0 = none yet */
    if (errno == EINTR)
      return 0;               /* a signal: the Haskell loop re-checks it */
    return -errno;
  }
}
/* read at most cap bytes (blocking, retries EINTR).
   returns the count read, 0 = clean EOF, or -errno. */
long hs_read_some(int fd, unsigned char *buf, long cap)
{
  for (;;) {
    ssize_t r = read(fd, buf, (size_t) cap);
    if (r >= 0)
      return (long) r;
    if (errno == EINTR)
      continue;
    return -errno;
  }
}

/* write some of n bytes (blocking, retries EINTR).
   returns the count written, or -errno.  The caller advances and loops. */
long hs_write_some(int fd, const unsigned char *buf, long n)
{
  for (;;) {
    ssize_t w = write(fd, buf, (size_t) n);
    if (w >= 0)
      return (long) w;
    if (errno == EINTR)
      continue;
    return -errno;
  }
}

void hs_close_fd(int fd)
{
  if (fd >= 0)
    close(fd);
}

/* message for a -errno code, into a caller-provided buffer. */
void hs_strerror_into(int code, char *buf, int len)
{
  int e = code < 0 ? -code : code;
  const char *m = strerror(e);
  int i = 0;
  while (m[i] != '\0' && i < len - 1) {
    buf[i] = m[i];
    i = i + 1;
  }
  buf[i] = '\0';
}
