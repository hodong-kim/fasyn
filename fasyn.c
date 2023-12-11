/* -*- Mode: C; indent-tabs-mode: nil; c-basic-offset: 2; tab-width: 2 -*- */
/*
 * fasyn.c
 * This file is part of Fasyn.
 *
 * Copyright (C) 2023 Hodong Kim <hodong@nimfsoft.com>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
#include "fasyn.h"

#include <stdio.h>
#include <sys/socket.h>
#include <c-loop.h>
#include <c-log.h>
#include <c-mem.h>
#include <time.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>
#include "fastcgi.h"
#include <curl/curl.h>

#define SOCK_PATH  "/home/hodong/fasyn/fasyn.sock"
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

struct _Fasyn {
  CLoop* loop;
  int    sockfd;
  struct sockaddr_un addr;
  CURLM* multi;
  int    n_runnings;
  int    timer_fd;
  FasynCallback cb_outgoing;
  void* cb_outgoing_user_data;
};

typedef struct _FasynConn FasynConn;
struct _FasynConn {
  Fasyn*   fasyn;
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
  //
  CURL* easy;

  State    state; /* uint8_t */
};

FasynConn* conn_new (Fasyn* fasyn)
{
  #define CONN_BUF_DEFAULT_CAPA 16
  FasynConn* conn = c_calloc (1, sizeof (FasynConn));
  conn->buf_capa = CONN_BUF_DEFAULT_CAPA;
  conn->buf   = c_malloc (CONN_BUF_DEFAULT_CAPA);
  conn->state = RECV_HEADER;
  conn->fasyn = fasyn;
  return conn;
}

void conn_free (FasynConn* conn)
{
  c_log_info ("conn_free");
  free (conn->buf);
  free (conn);
}

void conn_resize_capa (FasynConn* conn, size_t req_len)
{
  size_t old_capa = conn->buf_capa;

  while (req_len > conn->buf_capa)
    conn->buf_capa *= 2;

  while (req_len + CONN_BUF_DEFAULT_CAPA < conn->buf_capa / 4)
    conn->buf_capa = conn->buf_capa / 2;

  if (conn->buf_capa != old_capa)
    conn->buf = c_realloc (conn->buf, conn->buf_capa);
}

static size_t cb_curl_write (char *ptr, size_t size, size_t nmemb,
                             void *user_data)
{
  c_log_info ("cb_curl_write");
  //FasynConn* conn = user_data;
  fwrite (ptr, size, nmemb, stdout);

  return size * nmemb;
}

static void cb_send (int sockfd, short revents, void* user_data)
{
  c_log_info ("%ld cb_send", time (nullptr));
  FasynConn* conn = user_data;

  if (conn->state == SEND_STDOUT)
  {
    conn->easy = curl_easy_init ();
    if (!conn->easy)
      c_log_warning ("curl_easy_init failed");

    CURLcode code = -1;

    if (((code = curl_easy_setopt (conn->easy, CURLOPT_URL, "https://example.com/")) != CURLE_OK) ||
        ((code = curl_easy_setopt (conn->easy, CURLOPT_PRIVATE, conn)) != CURLE_OK) ||
        ((code = curl_easy_setopt (conn->easy, CURLOPT_WRITEFUNCTION, cb_curl_write)) != CURLE_OK) ||
        ((code = curl_easy_setopt (conn->easy, CURLOPT_WRITEDATA, conn)) != CURLE_OK))
    {
      c_log_critical ("curl_easy_setopt failed: %s", curl_easy_strerror (code));
    }

    curl_multi_add_handle (conn->fasyn->multi, conn->easy);

    // Needed: state

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
    conn->packet_len = FCGI_HEADER_LEN + content_len;
  }

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
          c_loop_remove_fd (conn->fasyn->loop, sockfd);
          //curl_multi_remove_handle (conn->fasyn->multi, conn->easy);
          //curl_easy_cleanup (conn->easy);
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
      c_loop_remove_fd (conn->fasyn->loop, sockfd);
      conn_free (conn);
      close (sockfd);
    }
  }
}

static void cb_incoming (int sockfd, short revents, void* user_data)
{
  c_log_info ("cb_incoming from %d", sockfd);
  FasynConn* conn = user_data;

  if (revents & (POLLHUP | POLLERR))
  {
    c_log_critical ("POLLHUP | POLLERR");
    c_loop_remove_fd (conn->fasyn->loop, sockfd);
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
          conn->state = SEND_STDOUT;
          conn->pos = 0;
          c_loop_remove_fd (conn->fasyn->loop, sockfd);
          c_loop_add_fd (conn->fasyn->loop, sockfd, POLLOUT, cb_send, conn);
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
    c_loop_remove_fd (conn->fasyn->loop, sockfd);
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
      c_loop_remove_fd (conn->fasyn->loop, sockfd);
      conn_free (conn);
      close (sockfd);
    }
  }
}

static void cb_new_req (int sockfd, short revents, void* user_data)
{
  printf ("%ld cb_new_req\n", time (nullptr));
  Fasyn* fasyn = user_data;

  if (revents & (POLLHUP | POLLERR))
  {
    c_log_critical ("A connection could not be established.");
    c_loop_remove_fd (fasyn->loop, sockfd);
    return;
  }

  int client_fd;
  socklen_t addr_len = sizeof (fasyn->addr);

  if ((client_fd = accept4 (sockfd, (struct sockaddr*) &fasyn->addr,
                            &addr_len, SOCK_NONBLOCK)) < 0)
  {
    c_log_critical ("accept4() failed");
    c_loop_remove_fd (fasyn->loop, sockfd);
    return;
  }

  FasynConn* conn = conn_new (fasyn);
  c_loop_add_fd (fasyn->loop, client_fd, POLLIN, cb_incoming, conn);
}

static void cb_socket_event (int fd, short cond, void* user_data)
{
  c_log_info ("cb_socket_event");
  Fasyn* fasyn = user_data;

  if (cond & (POLLERR | POLLHUP | POLLNVAL))
  {
    c_log_info ("cond & (POLLERR | POLLHUP | POLLNVAL)");
    c_loop_remove_fd (fasyn->loop, fd);
    close (fd);
    return;
  }

  int curl_cond = 0;

  if (cond & (POLLIN | POLLPRI))
    curl_cond |= CURL_CSELECT_IN;
  if (cond & POLLOUT)
    curl_cond |= CURL_CSELECT_OUT;

  CURLMcode code1;
  code1 = curl_multi_socket_action (fasyn->multi, fd, curl_cond,
                                    &fasyn->n_runnings);

  if (code1 != CURLM_OK)
  {
    c_log_info ("code1 != CURLM_OK");
    c_loop_remove_fd (fasyn->loop, fd);
    close (fd);
    return;
  }

  CURLMsg* msg;
  int      msgs_left;

  while ((msg = curl_multi_info_read (fasyn->multi, &msgs_left)))
  {
    if (msg->msg == CURLMSG_DONE)
    {
      FasynConn* conn;
      CURLcode code2;
      CURL *easy = msg->easy_handle;
      code2 = curl_easy_getinfo (easy, CURLINFO_PRIVATE, &conn);
      if (code2 != CURLE_OK)
      {
        c_log_critical ("%s", curl_easy_strerror (code2));
        break;
      }

      code2 = msg->data.result;
      if (code2 != CURLE_OK && easy != conn->easy)
      {
        c_log_info ("%s", curl_easy_strerror (code2));
        break;
      }

      // 100% OK
      if (conn->easy == easy)
      {
        curl_multi_remove_handle (fasyn->multi, conn->easy);
        curl_easy_cleanup (conn->easy);
        conn->easy = nullptr;
      }
    }
  }

  if (fasyn->n_runnings)
    return;

  c_loop_remove_timer (fasyn->loop, fasyn->timer_fd);
  fasyn->timer_fd = -1;
  c_loop_remove_fd (fasyn->loop, fd);
  close (fd);
}

static int cb_update_socket (CURL          *easy,
                             curl_socket_t  s,
                             int            action,
                             Fasyn*         fasyn,
                             void*          added)
{
  if (action == CURL_POLL_REMOVE)
  {
    c_loop_remove_fd (fasyn->loop, s);
    curl_multi_assign (fasyn->multi, s, nullptr);
  }
  else
  {
    if ((action & CURL_POLL_IN || action & CURL_POLL_OUT) && !added)
    {
      c_loop_add_fd (fasyn->loop, s, POLLIN, cb_socket_event, fasyn);
      curl_multi_assign (fasyn->multi, s, &s);
    }

    short cond = ((action & CURL_POLL_IN) ?  POLLIN  : 0) |
                 ((action & CURL_POLL_OUT) ? POLLOUT : 0);
    c_loop_remove_fd (fasyn->loop, s);
    //c_loop_mod_fd (fasyn->loop, s, cond, cb_socket_event, fasyn);
    c_loop_add_fd (fasyn->loop, s, cond, cb_socket_event, fasyn);
  }

  return 0;
}

static void cb_timeout (void* user_data)
{
  c_log_info ("cb_timeout");
  Fasyn* fasyn = user_data;
  CURLMcode code = curl_multi_socket_action (fasyn->multi, CURL_SOCKET_TIMEOUT,
                                             0, &fasyn->n_runnings);
  if (code == CURLM_OK)
  {
    c_log_info ("code == CURLM_OK");
    return;
  }

  c_log_warning ("%s", curl_multi_strerror (code));
  c_loop_remove_timer (fasyn->loop, fasyn->timer_fd);
  fasyn->timer_fd = -1;
}

static int cb_update_timeout (CURLM *multi, long timeout_ms, Fasyn* fasyn)
{
  c_log_info ("cb_update_timeout");
  if (timeout_ms == -1)
  {
    c_log_info ("c_loop_remove_timer");
    c_loop_remove_timer (fasyn->loop, fasyn->timer_fd);
    fasyn->timer_fd = -1;
    return 0;
  }

  c_log_info ("c_loop_remove_timer: fd %d", fasyn->timer_fd);
  c_log_info ("c_loop_add_timer: %ld ms", timeout_ms);
  c_loop_remove_timer (fasyn->loop, fasyn->timer_fd);
  fasyn->timer_fd = c_loop_add_timer (fasyn->loop, timeout_ms, cb_timeout,
                                      fasyn);

  return 0;
}

Fasyn* fasyn_new (int argc, char** argv)
{
  Fasyn* fasyn = c_calloc (1, sizeof (Fasyn));

  if ((fasyn->sockfd = socket (AF_UNIX, SOCK_STREAM, 0)) < 0)
  {
    c_log_critical ("socket() failed: %s", strerror (errno));
    goto FAIL;
  }

  int opt = 1;
  if (setsockopt (fasyn->sockfd, SOL_SOCKET, SO_REUSEADDR, (char*) &opt,
      sizeof (opt)) < 0)
  {
    c_log_critical ("setsockopt() failed: %s", strerror (errno));
    goto FAIL;
  }

  fasyn->addr.sun_family = AF_UNIX;
  snprintf (fasyn->addr.sun_path, sizeof (fasyn->addr.sun_path), "%s",
            SOCK_PATH);
  unlink (SOCK_PATH);

  if (bind (fasyn->sockfd, (struct sockaddr*) &fasyn->addr,
      sizeof (fasyn->addr)) < 0)
  {
    c_log_critical ("bind() failed: %s", strerror (errno));
    goto FAIL;
  }

  if (listen (fasyn->sockfd, SOMAXCONN) < 0)
  {
    c_log_critical ("listen() failed: %s", strerror (errno));
    goto FAIL;
  }

  if (curl_global_init (CURL_GLOBAL_DEFAULT) != CURLE_OK)
    c_log_critical ("curl_global_init failed");

  if (!(fasyn->multi = curl_multi_init ()))
    c_log_critical ("curl_multi_init failed");

  curl_multi_setopt (fasyn->multi, CURLMOPT_SOCKETFUNCTION, cb_update_socket);
  curl_multi_setopt (fasyn->multi, CURLMOPT_SOCKETDATA,     fasyn);
  curl_multi_setopt (fasyn->multi, CURLMOPT_TIMERFUNCTION,  cb_update_timeout);
  curl_multi_setopt (fasyn->multi, CURLMOPT_TIMERDATA,      fasyn);

  fasyn->loop = c_loop_new ();
  fasyn->timer_fd = -1;
  c_loop_add_fd (fasyn->loop, fasyn->sockfd, POLLIN, cb_new_req, fasyn);

  return fasyn;

  FAIL:
  c_log_info ("FAIL: %p, fasyn: %p", nullptr, fasyn);
  fasyn_free (fasyn);
  return nullptr;
}

void fasyn_free (Fasyn* fasyn)
{
  c_log_info ("fasyn_free: %p", fasyn);
  if (!fasyn)
    return;

  if (fasyn->loop)
    c_loop_remove_fd (fasyn->loop, fasyn->sockfd);

  if (fasyn->sockfd > -1)
    close (fasyn->sockfd);

  c_loop_free (fasyn->loop);

  if (fasyn->multi)
    curl_multi_cleanup (fasyn->multi);

  curl_global_cleanup ();

  free (fasyn);
}

int fasyn_run (Fasyn* fasyn)
{
  if (fasyn)
    return c_loop_run (fasyn->loop);
  else
    return 1;
}

void fasyn_quit (Fasyn* fasyn)
{
  c_loop_quit (fasyn->loop);
}

void fasyn_set_cb_outgoing (Fasyn* fasyn,
                            FasynCallback cb_outgoing,
                            void* cb_outgoing_user_data)
{
  fasyn->cb_outgoing = cb_outgoing;
  fasyn->cb_outgoing_user_data = cb_outgoing_user_data;
}
