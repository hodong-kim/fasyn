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
#include <string.h>
#include <errno.h>
#include "fastcgi.h"

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

CBuf* c_buf_new (size_t min)
{
  CBuf* cbuf = c_malloc (sizeof (CBuf));
  cbuf->data = c_malloc (min);
  cbuf->capa = min;
  cbuf->min = min;
  cbuf->pos = 0;
  cbuf->len = 0;
  return cbuf;
}

void c_buf_resize_capa (CBuf* cbuf, size_t req_len)
{
  size_t old_capa = cbuf->capa;

  while (req_len > cbuf->capa)
    cbuf->capa *= 2;

  while (req_len + cbuf->min < cbuf->capa / 4)
    cbuf->capa = cbuf->capa / 2;

  if (cbuf->capa != old_capa)
    cbuf->data = c_realloc (cbuf->data, cbuf->capa);
}

void c_buf_free (CBuf* cbuf)
{
  free (cbuf->data);
  free (cbuf);
}

FasynConn* fasyn_conn_new (Fasyn* fasyn, int conn_fd)
{
  FasynConn* conn = c_calloc (1, sizeof (FasynConn));
  conn->state = FASYN_CONN_STATE_RECV_HEADER;
  conn->fasyn = fasyn;
  conn->fd    = conn_fd;
  conn->reqs  = c_hash_map_new (c_ptr_hash, c_ptr_equal, nullptr, nullptr);
  conn->cbuf  = c_buf_new (16);
  conn->evq   = c_evq_new ();
  return conn;
}

void fasyn_conn_free (FasynConn* conn)
{
  c_log_info ("conn_free");
  c_buf_free (conn->cbuf);
  c_hash_map_free (conn->reqs);
  c_evq_free (conn->evq);
  free (conn);
}

FasynReq* fasyn_req_new (uint16_t id, FasynConn* conn)
{
  FasynReq* req = c_calloc (1, sizeof (FasynReq));
  req->id   = id;
  req->conn = conn;
  return req;
}

static void cb_incoming (int fd, short revents, void* user_data)
{
  c_log_info ("cb_incoming from fd: %d", fd);
  FasynConn* conn = user_data;

  if (revents & (POLLHUP | POLLERR | POLLNVAL))
  {
    c_log_critical ("POLLHUP | POLLERR | POLLNVAL");
    c_loop_remove_fd (conn->fasyn->loop, fd);
    fasyn_conn_free (conn);
    close (fd);
    return;
  }

  ssize_t n_bytes;
  int len;

  if (conn->state == FASYN_CONN_STATE_RECV_HEADER)
    len = FCGI_HEADER_LEN;
  else
    len = conn->header.content_len + conn->header.padding_len;

  c_buf_resize_capa (conn->cbuf, len);
  CBuf* cbuf = conn->cbuf;
  n_bytes = recv (fd, cbuf->data + cbuf->pos,
                  C_MIN (len - cbuf->pos, FASYN_MAX_BUF_SIZE), 0);
  printf ("len: %d, C_MIN (len - cbuf->pos, FASYN_MAX_BUF_SIZE): %d\n",
          len, (int) C_MIN (len - cbuf->pos, FASYN_MAX_BUF_SIZE));

  // FIXME
  // 클라이언트가 보낸 데이터를 어떠한 이유로 받을 수 없는 경우가 있습니다.
  // timer 를 설정하여 클라이언트와의 접속을 끊는 기능을 추가해야 하지만
  // 시간 관계상 생략합니다.

  if (n_bytes > 0)
  {
    cbuf->pos += n_bytes;

    // When receiving headers is complete
    if (cbuf->pos == len)
    {
      if (conn->state == FASYN_CONN_STATE_RECV_HEADER)
      {
        conn->header.version     = cbuf->data[0];
        conn->header.type        = cbuf->data[1];
        conn->header.req_id      = (cbuf->data[2] << 8) + cbuf->data[3];
        conn->header.content_len = (cbuf->data[4] << 8) + cbuf->data[5];
        conn->header.padding_len = cbuf->data[6];
        conn->header.reserved    = cbuf->data[7];
        c_log_info ("----------");
        c_log_info ("Receiving the header has been completed.");
        c_log_info ("version: %hhu", conn->header.version);
        c_log_info ("type: %s", fcgi_types[conn->header.type]);
        c_log_info ("req_id: %hu", conn->header.req_id);
        c_log_info ("content_len: %hu", conn->header.content_len);
        c_log_info ("padding_len: %hhu", conn->header.padding_len);
        c_log_info ("reserved: %hhu", conn->header.reserved);

        if (conn->header.content_len > 0)
        {
          conn->state = FASYN_CONN_STATE_RECV_CONTENT;
        }
        else if (conn->header.type == FCGI_STDIN)
        {
          FasynReq* req;
          req = c_hash_map_lookup (conn->reqs,
                                   C_UINT_TO_VOIDP (conn->header.req_id));
          conn->fasyn->cb_request (fd, req,
                                   conn->fasyn->cb_request_user_data);
        }

        conn->cbuf->pos = 0;
      }
      else // When receiving content is complete
      {
        c_log_info ("-------------------");
        c_log_info ("Receiving the content has been completed.");
        switch (conn->header.type)
        {
          case FCGI_BEGIN_REQUEST: // 1
            {
              FasynReq* req = fasyn_req_new (conn->header.req_id, conn);
              c_hash_map_insert (conn->reqs, C_UINT_TO_VOIDP (conn->header.req_id), req);
              FCGI_BeginRequestBody* body = (FCGI_BeginRequestBody*) conn->cbuf->data;
              req->role  = (body->roleB1 << 8) + body->roleB0;
              req->flags = body->flags;
              c_log_info ("role:  %hu",  req->role);
              c_log_info ("flags: %hhu", req->flags);
              conn->state = FASYN_CONN_STATE_RECV_HEADER;
              conn->cbuf->pos = 0;
            }

            break;

          case FCGI_PARAMS: // 4
            {
              c_log_info ("FCGI_PARAMS");
              // FIXME: acording to https://fastcgi-archives.github.io/FastCGI_Specification.html
              uint8_t name_len;
              uint8_t value_len;
              uint8_t* p = conn->cbuf->data;

              while (p < conn->cbuf->data + conn->header.content_len)
              {
                name_len  = *p; p++;
                value_len = *p; p++;
                printf ("%.*s: %.*s\n",
                        name_len, p,
                        value_len, p + name_len);
                p = p + name_len + value_len;
              }

              conn->state = FASYN_CONN_STATE_RECV_HEADER;
              conn->cbuf->pos = 0;
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
            c_log_warning ("programming error: type id: %hu",
                           conn->header.type);
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
    c_loop_remove_fd (conn->fasyn->loop, fd);
    fasyn_conn_free (conn);
    close (fd);
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
      c_loop_remove_fd (conn->fasyn->loop, fd);
      fasyn_conn_free (conn);
      close (fd);
    }
  }
}

void fasyn_req_free (FasynReq* req)
{
  puts ("fasyn_req_free");
  free (req);
}

static void cb_send_complete (FasynConn* conn, FasynReq* req)
{
  if (req->state == FASYN_REQ_STATE_SEND_END_REQ) // type 변수로 교체하면 된다.
  {
    if ((req->flags & FCGI_KEEP_CONN) == 0) // 이것이 문제로다.
    {
      c_log_info ("(req->flags & FCGI_KEEP_CONN) == 0");

      c_hash_map_remove (conn->reqs, req);
      fasyn_req_free (req);

      if (c_hash_map_size (conn->reqs) == 0)
      {
        c_loop_remove_fd (conn->fasyn->loop, conn->fd);
        fasyn_conn_free (conn);
        close (conn->fd);
      }
    }

    return;
  }

  c_loop_mod_fd (conn->fasyn->loop, conn->fd, POLLIN);
}

static void cb_send (FasynConn* conn, int fd, short revents)
{
  printf ("%ld cb_send: %d\n", time (nullptr), fd);

  if (revents & (POLLHUP | POLLERR))
  {
    c_log_critical ("POLLHUP | POLLERR");
    c_loop_remove_fd (conn->fasyn->loop, fd);
    fasyn_conn_free (conn);
    close (fd);
    return;
  }

  if (conn->cbuf2 == nullptr)
  {
    puts ("if (conn->cbuf2 == nullptr)");
    printf ("evq count: %d, conn->cbuf2: %p\n",
            (int) conn->evq->q->count, conn->cbuf2);
    conn->cbuf2 = c_evq_dequeue (conn->evq);
    printf ("evq count: %d, conn->cbuf2: %p\n",
            (int) conn->evq->q->count, conn->cbuf2);
  }

  ssize_t n_bytes;
  printf ("pos: %d, len: %d\n", (int) conn->cbuf2->pos, (int) conn->cbuf2->len);
  n_bytes = send (fd, conn->cbuf2->data + conn->cbuf2->pos,
                  conn->cbuf2->len - conn->cbuf2->pos, 0);
  printf ("n_bytes: %d\n", (int) n_bytes);
  if (n_bytes >= 0)
  {
    puts ("if (n_bytes >= 0)");
    conn->cbuf2->pos += n_bytes;

    if (conn->cbuf2->pos == conn->cbuf2->len)
    {
      puts ("if (conn->cbuf2->pos == conn->cbuf2->len)");
      conn->cbuf2 = nullptr;
      uint16_t req_id = (conn->cbuf->data[2] << 8) + conn->cbuf->data[3];
      FasynReq* req = c_hash_map_lookup (conn->reqs, C_UINT_TO_VOIDP (req_id));
      cb_send_complete (conn, req);
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
      c_loop_remove_fd (conn->fasyn->loop, fd);
      fasyn_conn_free (conn);
      close (fd);
    }
  }
}

static void cb_conn_event (int fd, short revents, void* user_data)
{
  c_log_info ("cb_conn_event from fd: %d", fd);
  FasynConn* conn = user_data;

  if (revents & (POLLHUP | POLLERR | POLLNVAL))
  {
    c_log_critical ("POLLHUP | POLLERR | POLLNVAL");
    c_loop_remove_fd (conn->fasyn->loop, fd);
    fasyn_conn_free (conn);
    close (fd);
    return;
  }

  if (revents & POLLIN)
  {
    cb_incoming (fd, revents, user_data);
  }
  else if (revents & POLLOUT)
  {
    cb_send (conn, fd, revents);
  }
}

static void cb_new_conn (int sockfd, short revents, void* user_data)
{
  printf ("%ld cb_new_conn\n", time (nullptr));
  Fasyn* fasyn = user_data;

  if (revents & (POLLHUP | POLLERR))
  {
    c_log_critical ("A connection could not be established.");
    c_loop_remove_fd (fasyn->loop, sockfd);
    return;
  }

  int conn_fd;
  socklen_t addr_len = sizeof (fasyn->addr);

  if ((conn_fd = accept4 (sockfd, (struct sockaddr*) &fasyn->addr,
                          &addr_len, SOCK_NONBLOCK)) < 0)
  {
    c_log_critical ("accept4() failed");
    c_loop_remove_fd (fasyn->loop, sockfd);
    return;
  }

  FasynConn* conn = fasyn_conn_new (fasyn, conn_fd);
  c_loop_add_fd (fasyn->loop, conn_fd, POLLIN, cb_conn_event, conn);
  c_loop_add_fd (fasyn->loop, conn->evq->fd, POLLIN, cb_send, conn);
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
      FasynReq* req;
      CURLcode code2;
      CURL *easy = msg->easy_handle;
      code2 = curl_easy_getinfo (easy, CURLINFO_PRIVATE, &req);
      if (code2 != CURLE_OK)
      {
        c_log_critical ("%s", curl_easy_strerror (code2));
        break;
      }

      code2 = msg->data.result;
      if (code2 != CURLE_OK)
      {
        c_log_info ("%s", curl_easy_strerror (code2));
        break;
      }

      curl_multi_remove_handle (fasyn->multi, easy);
      curl_easy_cleanup (easy);

      if (req->complete_func)
        req->complete_func (req);
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
    c_loop_mod_fd (fasyn->loop, s, cond);
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
  c_loop_remove_timer (fasyn->loop, fasyn->timer_fd);
  c_log_info ("c_loop_add_timer: %ld ms", timeout_ms);
  // FIXME: mod timer
  fasyn->timer_fd = c_loop_add_timer (fasyn->loop, timeout_ms, cb_timeout,
                                      fasyn);
  return 0;
}

Fasyn* fasyn_new (int argc, char** argv)
{
  Fasyn* fasyn = c_calloc (1, sizeof (Fasyn));

  if ((fasyn->listen_fd = socket (AF_UNIX, SOCK_STREAM, 0)) < 0)
  {
    c_log_critical ("socket() failed: %s", strerror (errno));
    goto FAIL;
  }

  int opt = 1;
  if (setsockopt (fasyn->listen_fd, SOL_SOCKET, SO_REUSEADDR, (char*) &opt,
      sizeof (opt)) < 0)
  {
    c_log_critical ("setsockopt() failed: %s", strerror (errno));
    goto FAIL;
  }

  fasyn->addr.sun_family = AF_UNIX;
  snprintf (fasyn->addr.sun_path, sizeof (fasyn->addr.sun_path), "%s",
            SOCK_PATH);
  unlink (SOCK_PATH);

  if (bind (fasyn->listen_fd, (struct sockaddr*) &fasyn->addr,
      sizeof (fasyn->addr)) < 0)
  {
    c_log_critical ("bind() failed: %s", strerror (errno));
    goto FAIL;
  }

  if (listen (fasyn->listen_fd, SOMAXCONN) < 0)
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
  c_loop_add_fd (fasyn->loop, fasyn->listen_fd, POLLIN, cb_new_conn, fasyn);

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
    c_loop_remove_fd (fasyn->loop, fasyn->listen_fd);

  if (fasyn->listen_fd > -1)
    close (fasyn->listen_fd);

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

void fasyn_set_cb_request (Fasyn* fasyn,
                           FasynCallback cb_request,
                           void* cb_request_user_data)
{
  fasyn->cb_request = cb_request;
  fasyn->cb_request_user_data = cb_request_user_data;
}

void fasyn_req_stdout (FasynReq* req)
{
  puts ("fasyn_req_stdout");

    req->state = FASYN_REQ_STATE_SEND_STDOUT;
    //// FIXME
    char content[] =
           "Content-type: text/html\r\n"
           "\r\n"
           "<title>FastCGI echo (fcgiapp version)</title>"
           "<h1>FastCGI echo (fcgiapp version)</h1>\n";
    int content_len = sizeof (content) - 1;
    int padding_len = PADDING (content_len, 8);
    printf ("content len: %d, padding_len: %d\n", content_len, padding_len);
    CBuf* cbuf = c_buf_new (16);
    c_buf_resize_capa (cbuf,
      FCGI_HEADER_LEN + content_len + padding_len + FCGI_HEADER_LEN);

    FCGI_Header* header = (FCGI_Header*) cbuf->data;
    header->version = FCGI_VERSION_1;
    header->type = FCGI_STDOUT;
    header->requestIdB1 = (uint8_t) ((req->id >> 8) & 0xff);
    header->requestIdB0 = (uint8_t) (req->id & 0xff);
    header->contentLengthB1 = (uint8_t) ((content_len >> 8) & 0xff);
    header->contentLengthB0 = (uint8_t) (content_len & 0xff);
    header->paddingLength = padding_len;
    header->reserved = 0;

    memcpy (cbuf->data + FCGI_HEADER_LEN, content, content_len);
    memset (cbuf->data + FCGI_HEADER_LEN + content_len, 0, padding_len);

    header = (FCGI_Header*) (cbuf->data + FCGI_HEADER_LEN + content_len + padding_len);
    header->version = FCGI_VERSION_1;
    header->type = FCGI_STDOUT;
    header->requestIdB1 = (uint8_t) ((req->id >> 8) & 0xff);
    header->requestIdB0 = (uint8_t) (req->id & 0xff);
    header->contentLengthB1 = 0;
    header->contentLengthB0 = 0;
    header->paddingLength = 0;
    header->reserved = 0;
  cbuf->len = FCGI_HEADER_LEN + content_len + padding_len + FCGI_HEADER_LEN;
  c_evq_enqueue (req->conn->evq, cbuf);
  c_loop_mod_fd (req->conn->fasyn->loop, req->conn->fd, POLLOUT);
}

void fasyn_req_end (FasynReq* req)
{
  puts ("fasyn_req_end");
  FasynConn* conn = req->conn;
  CBuf* cbuf = c_buf_new (16);
  c_buf_resize_capa (cbuf, sizeof (FCGI_EndRequestRecord));
  printf ("sizeof (FCGI_EndRequestRecord): %d, capa: %d\n",
          (int) sizeof (FCGI_EndRequestRecord), (int) cbuf->capa);
  FCGI_EndRequestRecord* end = (FCGI_EndRequestRecord*) cbuf->data;
  end->header.version = FCGI_VERSION_1;
  end->header.type = FCGI_END_REQUEST;

  end->header.requestIdB1 = (uint8_t) ((req->id >> 8) & 0xff);
  end->header.requestIdB0 = (uint8_t) (req->id & 0xff);

  c_log_info ("end->body len: %d", (int) sizeof (end->body));

  end->header.contentLengthB1 = (uint8_t) ((8 >> 8) & 0xff);
  end->header.contentLengthB0 = (uint8_t) (8 & 0xff);

  end->header.paddingLength = 8;
  end->header.reserved = 0;

  // The appStatus component is an application-level status code.
  // Each role documents its usage of appStatus.
  uint32_t appStatus = 0;
  // The protocolStatus component is a protocol-level status code.
  uint8_t  protocolStatus = FCGI_REQUEST_COMPLETE;
  end->body.appStatusB3    = (uint8_t) ((appStatus >> 24) & 0xff);
  end->body.appStatusB2    = (uint8_t) ((appStatus >> 16) & 0xff);
  end->body.appStatusB1    = (uint8_t) ((appStatus >>  8) & 0xff);
  end->body.appStatusB0    = (uint8_t) ((appStatus      ) & 0xff);
  end->body.protocolStatus = (uint8_t) protocolStatus;
  memset (end->body.reserved, 0, sizeof (end->body.reserved));
  req->state = FASYN_REQ_STATE_SEND_END_REQ;
  cbuf->len = sizeof (FCGI_EndRequestRecord);
  req->state = FASYN_REQ_STATE_SEND_END_REQ;
  c_evq_enqueue (conn->evq, cbuf);
  c_loop_mod_fd (conn->fasyn->loop, conn->fd, POLLOUT);
}
