/*
 * fasyn-runtime-test.c
 * Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
 */

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int
set_nonblocking (int fd)
{
  int flags = fcntl (fd, F_GETFL, 0);
  if (flags == -1)
    return errno;

  if (fcntl (fd, F_SETFL, flags | O_NONBLOCK) == -1)
    return errno;

  return 0;
}

static int
fill_send_buffer (int fd)
{
  unsigned char buffer[4096];

  memset (buffer, 0xa5, sizeof buffer);

  for (;;)
    {
      ssize_t count = write (fd, buffer, sizeof buffer);

      if (count > 0)
        continue;

      if (count == -1 && errno == EINTR)
        continue;

      if (count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
        return 0;

      return count == 0 ? EIO : errno;
    }
}

int
fasyn_test_is_nonblocking (int fd)
{
  int flags = fcntl (fd, F_GETFL, 0);
  if (flags == -1)
    return -errno;

  return (flags & O_NONBLOCK) != 0;
}

int
fasyn_test_socketpair (int *runtime_fd, int *peer_fd)
{
  int fds[2] = {-1, -1};
  int send_buffer = 1024;
  int error;

  if (runtime_fd == NULL || peer_fd == NULL)
    return EINVAL;

  *runtime_fd = -1;
  *peer_fd = -1;

  if (socketpair (AF_UNIX, SOCK_STREAM, 0, fds) == -1)
    return errno;

  error = set_nonblocking (fds[0]);
  if (error == 0)
    error = set_nonblocking (fds[1]);

  if (error == 0 &&
      setsockopt (fds[0], SOL_SOCKET, SO_SNDBUF,
                  &send_buffer, sizeof send_buffer) == -1)
    error = errno;

  if (error == 0)
    error = fill_send_buffer (fds[0]);

  if (error != 0)
    {
      close (fds[0]);
      close (fds[1]);
      return error;
    }

  *runtime_fd = fds[0];
  *peer_fd = fds[1];
  return 0;
}

int
fasyn_test_listener_pair (int *listener_fd, int *client_fd)
{
  struct sockaddr_un address;
  char path[] = "/tmp/fasyn-runtime-XXXXXX";
  int path_fd = -1;
  int listener = -1;
  int client = -1;
  int error = 0;

  if (listener_fd == NULL || client_fd == NULL)
    return EINVAL;

  *listener_fd = -1;
  *client_fd = -1;

  path_fd = mkstemp (path);
  if (path_fd == -1)
    return errno;
  close (path_fd);
  unlink (path);

  listener = socket (AF_UNIX, SOCK_STREAM, 0);
  if (listener == -1)
    {
      error = errno;
      goto cleanup;
    }

  memset (&address, 0, sizeof address);
  address.sun_family = AF_UNIX;
  if (snprintf (address.sun_path, sizeof address.sun_path, "%s", path) >=
      (int) sizeof address.sun_path)
    {
      error = ENAMETOOLONG;
      goto cleanup;
    }

  if (bind (listener, (struct sockaddr *) &address, sizeof address) == -1 ||
      listen (listener, 4) == -1)
    {
      error = errno;
      goto cleanup;
    }

  client = socket (AF_UNIX, SOCK_STREAM, 0);
  if (client == -1 ||
      connect (client, (struct sockaddr *) &address, sizeof address) == -1)
    {
      error = errno;
      goto cleanup;
    }

  unlink (path);
  *listener_fd = listener;
  *client_fd = client;
  return 0;

cleanup:
  unlink (path);
  if (client != -1)
    close (client);
  if (listener != -1)
    close (listener);
  return error;
}


int
fasyn_test_tcp_listener_pair (int *listener_fd, int *client_fd)
{
  struct sockaddr_in address;
  socklen_t address_length = sizeof address;
  int listener = -1;
  int client = -1;
  int error = 0;

  if (listener_fd == NULL || client_fd == NULL)
    return EINVAL;

  *listener_fd = -1;
  *client_fd = -1;

  listener = socket (AF_INET, SOCK_STREAM, 0);
  if (listener == -1)
    return errno;

  memset (&address, 0, sizeof address);
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl (INADDR_LOOPBACK);
  address.sin_port = 0;

  if (bind (listener, (struct sockaddr *) &address, sizeof address) == -1 ||
      listen (listener, 4) == -1 ||
      getsockname (listener, (struct sockaddr *) &address,
                   &address_length) == -1)
    {
      error = errno;
      goto cleanup;
    }

  client = socket (AF_INET, SOCK_STREAM, 0);
  if (client == -1 ||
      connect (client, (struct sockaddr *) &address, sizeof address) == -1)
    {
      error = errno;
      goto cleanup;
    }

  *listener_fd = listener;
  *client_fd = client;
  return 0;

cleanup:
  if (client != -1)
    close (client);
  if (listener != -1)
    close (listener);
  return error;
}


int
fasyn_test_run_sigterm_fixture (int listener_fd)
{
  const char *path = getenv ("FASYN_CLASSIC_FIXTURE");
  struct pollfd ready_poll;
  struct timespec pause_time = {0, 10000000};
  unsigned char ready_byte;
  int ready_pipe[2] = {-1, -1};
  int status = 0;
  pid_t child;

  if (path == NULL || path[0] == '\0' || listener_fd < 0)
    return EINVAL;

  if (pipe (ready_pipe) == -1)
    return errno;

  child = fork ();
  if (child == -1)
    {
      int error = errno;
      close (ready_pipe[0]);
      close (ready_pipe[1]);
      return error;
    }

  if (child == 0)
    {
      char ready_fd_text[32];

      if (dup2 (listener_fd, STDIN_FILENO) == -1)
        _exit (120);

      if (listener_fd != STDIN_FILENO && listener_fd != ready_pipe[1])
        close (listener_fd);
      close (ready_pipe[0]);

      int written = snprintf (ready_fd_text, sizeof ready_fd_text, "%d",
                              ready_pipe[1]);
      if (written < 0 || written >= (int) sizeof ready_fd_text)
        _exit (120);

      if (ready_pipe[1] != STDOUT_FILENO)
        close (STDOUT_FILENO);
      if (ready_pipe[1] != STDERR_FILENO)
        close (STDERR_FILENO);
      execl (path, path, "wait-term", ready_fd_text, (char *) NULL);
      _exit (121);
    }

  close (ready_pipe[1]);
  ready_poll.fd = ready_pipe[0];
  ready_poll.events = POLLIN;
  ready_poll.revents = 0;

  if (poll (&ready_poll, 1, 5000) != 1 ||
      read (ready_pipe[0], &ready_byte, 1) != 1)
    {
      kill (child, SIGKILL);
      waitpid (child, &status, 0);
      close (ready_pipe[0]);
      return ETIMEDOUT;
    }
  close (ready_pipe[0]);

  if (kill (child, SIGTERM) == -1)
    {
      int error = errno;
      kill (child, SIGKILL);
      waitpid (child, &status, 0);
      return error;
    }

  for (int attempt = 0; attempt < 500; ++attempt)
    {
      pid_t waited = waitpid (child, &status, WNOHANG);
      if (waited == child)
        {
          if (WIFEXITED (status) && WEXITSTATUS (status) == 0)
            return 0;
          return EPROTO;
        }
      if (waited == -1)
        return errno;
      nanosleep (&pause_time, NULL);
    }

  kill (child, SIGKILL);
  waitpid (child, &status, 0);
  return ETIMEDOUT;
}
