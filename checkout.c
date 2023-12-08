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
#include "fastcgi.h"

#define PADDING(offset, align)  (-(offset) & ((align) - 1))
const char* fcgi_types[] = {
  nullptr,
  "FCGI_BEGIN_REQUEST",
  "FCGI_ABORT_REQUEST",
  "FCGI_END_REQUEST",
  "FCGI_PARAMS",
  "FCGI_STDIN",
  "FCGI_STDOUT",
  "FCGI_STDERR",
  "FCGI_DATA",
  "FCGI_GET_VALUES",
  "FCGI_GET_VALUES_RESULT",
  "FCGI_UNKNOWN_TYPE"
};

enum _State : uint8_t {
  RECV_HEADER  = 1 << 0,
  RECV_CONTENT = 1 << 1,
  SEND_STDOUT  = 1 << 2,
  SEND_END_REQ = 1 << 3
};
typedef enum _State State;

typedef struct _Conn Conn;
struct _Conn {
  uint8_t* buf;
  size_t   pos;
  size_t   buf_capa;
  size_t   packet_len;
  // header
  uint8_t  version;
  uint8_t  type;
  uint16_t req_id;
  uint16_t content_len;
  uint16_t padding_len;
  // begin req body
  uint16_t role;
  uint8_t  flags;

  State    state; /* uint8_t */
};

Conn* conn_new ()
{
  #define CONN_BUF_DEFAULT_CAPA 16
  Conn* conn = c_calloc (1, sizeof (Conn));
  conn->buf_capa = CONN_BUF_DEFAULT_CAPA;
  conn->buf   = c_malloc (CONN_BUF_DEFAULT_CAPA);
  conn->state = RECV_HEADER;
  return conn;
}

void conn_free (Conn* conn)
{
  c_log_info ("conn_free");
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

static void cb_incoming (int sockfd, short revents, void* user_data);

static void cb_send (int sockfd, short revents, void* user_data)
{
  c_log_info ("%ld cb_send", time (NULL));
  Conn* conn = user_data;

  ssize_t n_bytes;
  n_bytes = send (sockfd, conn->buf + conn->pos,
                  conn->packet_len - conn->pos, 0);

  if (n_bytes >= 0)
  {
    conn->pos += n_bytes;

    if (conn->pos == conn->packet_len)
    {
      if (conn->state == SEND_STDOUT)
      {
        conn_resize_capa (conn, sizeof (FCGI_EndRequestRecord));
        FCGI_EndRequestRecord* rec = (FCGI_EndRequestRecord*) conn->buf;
        rec->header.version = FCGI_VERSION_1;
        rec->header.type = FCGI_END_REQUEST;

        rec->header.requestIdB1 = (uint8_t) ((conn->req_id >> 8) & 0xff);
        rec->header.requestIdB0 = (uint8_t) (conn->req_id & 0xff);

        c_log_info ("rec->body len: %d", (int) sizeof (rec->body));

        rec->header.contentLengthB1 = (uint8_t) ((sizeof (rec->body) >> 8) & 0xff);
        rec->header.contentLengthB0 = (uint8_t) (sizeof (rec->body) & 0xff);

        rec->header.paddingLength = 0;
        rec->header.reserved = 0;

        // The appStatus component is an application-level status code.
        // Each role documents its usage of appStatus.
        uint32_t appStatus = 0;
        // The protocolStatus component is a protocol-level status code.
        uint8_t  protocolStatus = FCGI_CANT_MPX_CONN;

        rec->body.appStatusB3    = (uint8_t) ((appStatus >> 24) & 0xff);
        rec->body.appStatusB2    = (uint8_t) ((appStatus >> 16) & 0xff);
        rec->body.appStatusB1    = (uint8_t) ((appStatus >>  8) & 0xff);
        rec->body.appStatusB0    = (uint8_t) ((appStatus      ) & 0xff);
        rec->body.protocolStatus = (uint8_t) protocolStatus;
        memset (rec->body.reserved, 0, sizeof (rec->body.reserved));
        conn->state = SEND_END_REQ;
        conn->pos = 0;
        conn->packet_len = (sizeof (rec->body));

        if ((conn->flags & FCGI_KEEP_CONN) == 0)
        {
          c_log_info ("(conn->flags & FCGI_KEEP_CONN) == 0");
          c_loop_remove_fd (loop, sockfd);
          conn_free (conn);
          close (sockfd);
        }

        return;
      }
    }
  }
  else if (n_bytes < 0)
  {
    if (errno == EWOULDBLOCK || errno == EAGAIN)
    {
      c_log_info ("%s", strerror (errno));
    }
    else
    {
      c_log_critical ("send() failed: %s", strerror (errno));
      c_loop_remove_fd (loop, sockfd);
      conn_free (conn);
      close (sockfd);
    }
  }
}

static void cb_incoming (int sockfd, short revents, void* user_data)
{
  c_log_info ("cb_incoming from %d", sockfd);
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

  if (conn->state == RECV_HEADER)
    len = FCGI_HEADER_LEN;
  else
    len = conn->content_len + conn->padding_len;

  conn_resize_capa (conn, len);
  n_bytes = recv (sockfd, conn->buf + conn->pos, len - conn->pos, 0);

  // 클라이언트가 보낸 데이터를 어떠한 이유로 받을 수 없는 경우가 있습니다.
  // timer 를 설정하여 클라이언트와의 접속을 끊는 기능을 추가해야 하지만
  // 시간 관계상 생략합니다.

  if (n_bytes > 0)
  {
    conn->pos += n_bytes;

    // recv complete
    if (conn->pos == len)
    {
      if (conn->state == RECV_HEADER)
      {
        c_log_info ("----------");
        c_log_info ("Receiving the header has been completed.");
        FCGI_Header* header = (FCGI_Header*) conn->buf;
        c_log_info ("version: %hhu", header->version);
        c_log_info ("type: %s", fcgi_types[header->type]);
        c_log_info ("requestIdB1: %hhu", header->requestIdB1);
        c_log_info ("requestIdB0: %hhu", header->requestIdB0);
        c_log_info ("contentLengthB1: %hhu", header->contentLengthB1);
        c_log_info ("contentLengthB0: %hhu", header->contentLengthB0);
        c_log_info ("paddingLength: %hhu", header->paddingLength);
        c_log_info ("reserved: %hhu", header->reserved);
        conn->version = header->version;
        conn->type    = header->type;
        conn->req_id  = (header->requestIdB1 << 8) + header->requestIdB0;
        conn->content_len = (header->contentLengthB1 << 8) + header->contentLengthB0;
        conn->padding_len = header->paddingLength;

        c_log_info ("req_id: %hu", conn->req_id);
        c_log_info ("content_len: %hu", conn->content_len);

        conn->pos = 0;

        if (conn->content_len > 0)
        {
          conn->state = RECV_CONTENT;
        }
        else if (conn->content_len == 0 && conn->type == FCGI_STDIN)
        {
          char content[] =
            "Status: 200 OK\r\n"
            "Content-type: text/plain\r\n"
            "\r\n"
            "Testing";
          int content_len = sizeof (content) - 1;
          int padding_len = PADDING (content_len, 8);
          conn_resize_capa (conn, FCGI_HEADER_LEN + content_len + padding_len);
          memcpy (conn->buf + FCGI_HEADER_LEN, content, content_len);
          memset (conn->buf + FCGI_HEADER_LEN + content_len, 0, padding_len);

          FCGI_Header* header = (FCGI_Header*) conn->buf;
          header->version = FCGI_VERSION_1;
          header->type = FCGI_STDOUT;
          header->requestIdB1 = (uint8_t) ((conn->req_id >> 8) & 0xff);
          header->requestIdB0 = (uint8_t) (conn->req_id & 0xff);
          header->contentLengthB1 = (uint8_t) ((content_len >> 8) & 0xff);
          header->contentLengthB0 = (uint8_t) (content_len & 0xff);
          header->paddingLength = padding_len;
          header->reserved = 0;
          conn->state = SEND_STDOUT;
          conn->pos = 0;
          conn->packet_len = FCGI_HEADER_LEN + content_len;

          c_loop_remove_fd (loop, sockfd);
          c_loop_add_fd (loop, sockfd, POLLOUT, cb_send, conn);
        }
      }
      else // RECV_CONTENT
      {
        c_log_info ("-------------------");
        c_log_info ("Receiving the content has been completed.");
        switch (conn->type)
        {
          case FCGI_BEGIN_REQUEST: // 1
            {
              FCGI_BeginRequestBody* body = (FCGI_BeginRequestBody*) conn->buf;
              conn->role  = (body->roleB1 << 8) + body->roleB0;
              c_log_info ("role:  %hu",  conn->role);
              c_log_info ("flags: %hhu", conn->flags);
              conn->flags = body->flags & FCGI_KEEP_CONN;
              conn->state = RECV_HEADER;
              conn->pos = 0;
            }

            break;
          case FCGI_PARAMS: // 4
            {
              c_log_info ("FCGI_PARAMS");
              uint8_t name_len;
              uint8_t value_len;
              uint8_t* p = conn->buf;

              while (p < conn->buf + conn->content_len)
              {
                name_len  = *p; p++;
                value_len = *p; p++;
                printf ("%.*s: %.*s\n",
                        name_len, p,
                        value_len, p + name_len);
                p = p + name_len + value_len;
              }

              conn->state = RECV_HEADER;
              conn->pos = 0;
            }

            break;

          case FCGI_ABORT_REQUEST: // 2
          case FCGI_END_REQUEST: // 3
          case FCGI_STDIN: // 5
          case FCGI_STDOUT: // 6
          case FCGI_STDERR: // 7
          case FCGI_DATA: // 8
          case FCGI_GET_VALUES: // 9
          case FCGI_GET_VALUES_RESULT: // 10
          case FCGI_UNKNOWN_TYPE: // 11
          default:
            c_log_warning ("programming error: type id: %hu", conn->type);
            abort ();
        }
      }
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
      // retry
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
  c_loop_add_fd (loop, client_fd, POLLIN, cb_incoming, conn);
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
