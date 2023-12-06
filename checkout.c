/* -*- Mode: C; indent-tabs-mode: nil; c-basic-offset: 2; tab-width: 2 -*-  */
/*
 * checkout.c
 * Copyright (C) 2023 Hodong Kim, All rights reserved.
 * Unauthorized copying of this software, via any medium is strictly prohibited.
 * Proprietary and confidential.
 * Written by Hodong Kim <hodong@nimfsoft.com>
 */
#include <stdio.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <c-loop.h>
#include <c-log.h>
#include <c-mem.h>
#include <time.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

#define FCGI_HEADER_LEN  8
#define LEN 4098

typedef struct _FcgiHeader FcgiHeader;
struct __attribute__((packed)) _FcgiHeader {
    uint8_t version;
    uint8_t type;
    uint8_t req_id_b1;
    uint8_t req_id_b0;
    uint8_t content_len_b1;
    uint8_t content_len_b0;
    uint8_t padding_len;
    uint8_t reserved;
};

enum _State : uint8_t {
  RECV_HEADER,
  RECV_CONTENT
};
typedef enum _State State;

typedef struct _Conn Conn;
struct _Conn {
  FcgiHeader header;
  uint8_t* buf;
  size_t   pos;
  size_t   buf_capa;
  size_t   res_len;
  State    state; /* uint8_t */
};

Conn* conn_new ()
{
  #define CONN_BUF_DEFAULT_CAPA 16
  Conn* conn = c_malloc (sizeof (Conn));
  conn->buf_capa = CONN_BUF_DEFAULT_CAPA;
  conn->buf      = c_malloc (CONN_BUF_DEFAULT_CAPA);
  conn->pos      = 0;
  conn->res_len  = 0;
  conn->state    = RECV_HEADER;
  return conn;
}

void conn_free (Conn* conn)
{
  free (conn->buf);
  free (conn);
}

void conn_resize_capa (Conn* conn, size_t req_len)
{
  size_t old_capa = conn->buf_capa;

  while (req_len > conn->buf_capa)
    conn->buf_capa *= 2;

  while (req_len + CONN_BUF_DEFAULT_CAPA < conn->buf_capa / 4)
    conn->buf_capa = conn->buf_capa / 2;

  if (conn->buf_capa != old_capa)
    conn->buf = c_realloc (conn->buf, conn->buf_capa);
}

CLoop* loop;
#if 0
static void cb_write (int sockfd, short revents, void* user_data)
{
  printf ("%ld >> cb_write\n", time (NULL));
  FCGX_Request* req = user_data;
  FCGX_FPrintF (req->out,
         "Status: 200 OK\r\n"
         "Content-type: text/html\r\n"
         "\r\n"
         "<h1>Example: FastCGI Multiplex</h1>");
  FCGX_Finish_r (req);
  free (req);
  printf ("%ld << cb_write\n", time (NULL));
  c_loop_remove_fd (loop, sockfd);
}
#endif

static void cb_read_header (int sockfd, short revents, void* user_data);

static void cb_read_content (int sockfd, short revents, void* user_data)
{
  c_log_info ("cb_read_content from %d", sockfd);
  Conn* conn = user_data;

  if (revents & (POLLHUP | POLLERR))
  {
    c_log_critical ("POLLHUP | POLLERR");
    c_loop_remove_fd (loop, sockfd);
    conn_free (conn);
    close (sockfd);
    return;
  }

  ssize_t n_bytes;
  int content_len;
  void* buf;
  FcgiHeader* header = &conn->header;

  content_len = (header->content_len_b1 << 8) + header->content_len_b0;

  c_log_info ("content_len: %d", content_len);
  c_log_info ("conn->pos: %lu", conn->pos);
  conn_resize_capa (conn, content_len);
  buf = conn->buf;

  n_bytes = recv (sockfd, buf + conn->pos, content_len - conn->pos, 0);

  // 클라이언트가 보낸 데이터를 어떠한 이유로 받을 수 없는 경우가 있습니다.
  // timer 를 설정하여 클라이언트와의 접속을 끊는 기능을 추가해야 하지만
  // 시간 관계상 생략합니다.

  if (n_bytes > 0)
  {
    conn->pos += n_bytes;

    if (conn->pos == content_len)
    {
      c_log_info ("Receiving the content has been completed.");
      conn->pos = 0;
      // c_loop_mod_fd (loop, sockfd, POLLIN, cb_read_content, conn);
      c_loop_remove_fd (loop, sockfd);
      c_loop_add_fd (loop, sockfd, POLLIN, cb_read_header, conn);
    }
  }
  else if (n_bytes == 0)
  {
    c_log_info ("ZERO BYTES");
    /* linux man page
       When a stream socket peer has performed an orderly shutdown, the
       return value will be 0 (the traditional "end-of-file" return).

       Datagram sockets in various domains (e.g., the UNIX and Internet
       domains) permit zero-length datagrams.  When such a datagram is
       received, the return value is 0.

       The value 0 may also be returned if the requested number of bytes
       to receive from a stream socket was 0.
     */
    c_loop_remove_fd (loop, sockfd);
    conn_free (conn);
    close (sockfd);
  }
  else
  {
    if (errno == EWOULDBLOCK ||
        errno == EAGAIN)
    {
      c_log_info ("%s", strerror (errno));
    }
    else
    {
      c_log_critical ("%s", strerror (errno));
      c_loop_remove_fd (loop, sockfd);
      conn_free (conn);
      close (sockfd);
    }
  }
}

static void cb_read_header (int sockfd, short revents, void* user_data)
{
  c_log_info ("cb_read_header from %d", sockfd);
  Conn* conn = user_data;

  if (revents & (POLLHUP | POLLERR))
  {
    c_log_critical ("POLLHUP | POLLERR");
    c_loop_remove_fd (loop, sockfd);
    conn_free (conn);
    close (sockfd);
    return;
  }

  ssize_t n_bytes;
  int len;
  void* buf;

  len = FCGI_HEADER_LEN;
  buf = &conn->header;

  n_bytes = recv (sockfd, buf + conn->pos, len - conn->pos, 0);

  // 클라이언트가 보낸 데이터를 어떠한 이유로 받을 수 없는 경우가 있습니다.
  // timer 를 설정하여 클라이언트와의 접속을 끊는 기능을 추가해야 하지만
  // 시간 관계상 생략합니다.

  if (n_bytes > 0)
  {
    conn->pos += n_bytes;

    if (conn->pos == FCGI_HEADER_LEN)
    {
      c_log_info ("Receiving the header has been completed.");
      FcgiHeader* header = &conn->header;
      c_log_info ("\n"
                  "version: %hhu\n"
                  "type: %hhu\n"
                  "req_id_b1: %hhu\n"
                  "req_id_b0: %hhu\n"
                  "content_len_b1: %hhu\n"
                  "content_len_b0: %hhu\n"
                  "padding_len: %hhu\n"
                  "reserved: %hhu\n",header->version, header->type,
                  header->req_id_b1, header->req_id_b0,
                  header->content_len_b1, header->content_len_b0,
                  header->padding_len, header->reserved);
      conn->pos = 0;
      // c_loop_mod_fd (loop, sockfd, POLLIN, cb_read_content, conn);
      c_loop_remove_fd (loop, sockfd);
      c_loop_add_fd (loop, sockfd, POLLIN, cb_read_content, conn);
    }
  }
  else if (n_bytes == 0)
  {
    c_log_info ("ZERO BYTES");
    /* linux man page
       When a stream socket peer has performed an orderly shutdown, the
       return value will be 0 (the traditional "end-of-file" return).

       Datagram sockets in various domains (e.g., the UNIX and Internet
       domains) permit zero-length datagrams.  When such a datagram is
       received, the return value is 0.

       The value 0 may also be returned if the requested number of bytes
       to receive from a stream socket was 0.
     */
    c_loop_remove_fd (loop, sockfd);
    conn_free (conn);
    close (sockfd);
  }
  else
  {
    if (errno == EWOULDBLOCK ||
        errno == EAGAIN)
    {
      c_log_info ("%s", strerror (errno));
    }
    else
    {
      c_log_critical ("%s", strerror (errno));
      c_loop_remove_fd (loop, sockfd);
      conn_free (conn);
      close (sockfd);
    }
  }
}

static void cb_new_req (int sockfd, short revents, void* user_data)
{
  printf ("%ld cb_new_req\n", time (NULL));
  struct sockaddr_un* addr = user_data;

  if (revents & (POLLHUP | POLLERR))
  {
    c_log_critical ("A connection could not be established.");
    c_loop_remove_fd (loop, sockfd);
    return;
  }

  int client_fd;
  socklen_t addr_len = sizeof (*addr);

  if ((client_fd = accept4 (sockfd, (struct sockaddr*) addr,
                            &addr_len, SOCK_NONBLOCK)) < 0)
  {
    c_log_critical ("accept4() failed");
    c_loop_remove_fd (loop, sockfd);
    return;
  }

  Conn* conn = conn_new ();
  c_loop_add_fd (loop, client_fd, POLLIN, cb_read_header, conn);
}

static void cb_quit (int signo)
{
  c_loop_quit (loop);
}

int main ()
{
  loop = c_loop_new ();

  // FCGX_Init ();
  int sockfd;
  if ((sockfd = socket (AF_UNIX, SOCK_STREAM, 0)) < 0)
  {
    c_log_critical ("socket() failed");
    return 1;
  }

  int opt = 1;
  if (setsockopt (sockfd, SOL_SOCKET, SO_REUSEADDR, (char*) &opt, sizeof (opt)) < 0)
  {
    c_log_critical ("setsockopt() failed: %s", strerror (errno));
    return 1;
  }

  struct sockaddr_un addr = { 0 };
  addr.sun_family = AF_UNIX;
  snprintf (addr.sun_path, sizeof (addr.sun_path), "%s", "/home/hodong/checkout/checkout.sock");

  unlink ("/home/hodong/checkout/checkout.sock");

  if (bind (sockfd, (struct sockaddr*) &addr, sizeof (addr)) < 0)
  {
    c_log_critical ("bind() failed: %s", strerror (errno));
    return 1;
  }

  if (listen (sockfd, SOMAXCONN) < 0)
  {
    c_log_critical ("listen() failed");
    return 1;
  }

  c_loop_add_fd (loop, sockfd, POLLIN, cb_new_req, &addr);

  struct sigaction quit      = { .sa_handler = cb_quit,
                                 .sa_flags   = SA_SIGINFO };
  struct sigaction ignore    = { .sa_handler = SIG_IGN,
                                 .sa_flags   = 0 };
  struct sigaction no_zombie = { .sa_handler = SIG_DFL,
                                 .sa_flags   = SA_NOCLDWAIT };

  sigaction (SIGINT,  &quit,      nullptr);
  sigaction (SIGTERM, &quit,      nullptr);
  sigaction (SIGTSTP, &ignore,    nullptr);
  sigaction (SIGCHLD, &no_zombie, nullptr);

  c_loop_run (loop);

  c_loop_remove_fd (loop, sockfd);
  c_loop_free (loop);

  return 0;
}
