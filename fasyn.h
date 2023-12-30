/* -*- Mode: C; indent-tabs-mode: nil; c-basic-offset: 2; tab-width: 2 -*- */
/*
 * fasyn.h
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
#ifndef __FASYN_H__
#define __FASYN_H__

#include "c-macros.h"
#include "c-loop.h"
#include <sys/un.h>
#include <curl/curl.h>
#include "c-evq.h"

C_BEGIN_DECLS

#define FASYN_MAX_BUF_SIZE  4096

enum _FasynConnState : uint8_t {
  FASYN_CONN_STATE_RECV_HEADER,
  FASYN_CONN_STATE_RECV_CONTENT
};
typedef enum _FasynConnState FasynConnState;

enum _FasynReqState : uint8_t {
  FASYN_REQ_STATE_NONE = 0,
  FASYN_REQ_STATE_RECV_HEADER  = 1 << 0,
  FASYN_REQ_STATE_RECV_CONTENT = 1 << 1,
  FASYN_REQ_STATE_SEND_STDOUT  = 1 << 2,
  FASYN_REQ_STATE_SEND_END_REQ = 1 << 3,
  FASYN_REQ_STATE_USER_FUNC    = 1 << 4
};
typedef enum _FasynReqState FasynReqState;

typedef struct _CBuf  CBuf;
struct _CBuf {
  uint8_t* data;
  size_t   capa;
  size_t   len;
  size_t   pos;
  size_t   min;
};

typedef struct _FasynConn FasynConn;
typedef struct _FasynReq FasynReq;
struct _FasynReq {
  FasynConn* conn;

  uint16_t id;
  uint16_t role;
  uint8_t  flags;

  FasynReqState state; /* uint8_t */ /* FIXME 없어도 될 지도 모른다 */
  void (*recv_func)     (FasynReq* req);
  void (*complete_func) (FasynReq* req);
  void (*error_func)    (FasynReq* req);
};

typedef void (*FasynCallback) (int fd, FasynReq* req, void* user_data);

typedef struct _Fasyn Fasyn;
struct _Fasyn {
  CLoop* loop;
  int    listen_fd;
  struct sockaddr_un addr;
  CURLM* multi;
  int    n_runnings;
  int    timer_fd;
  FasynCallback cb_request;
  void* cb_request_user_data;
};

typedef struct _FasynHeader FasynHeader;
struct _FasynHeader {
  uint8_t  version;
  uint8_t  type;
  uint16_t req_id;
  uint16_t content_len;
  uint8_t  padding_len;
  uint8_t  reserved;
};

struct _FasynConn {
  Fasyn*   fasyn;
  CHashMap* reqs;
  FasynHeader header; // 받기만 한다
  CBuf* cbuf; // 받기만 한다
  CBuf* cbuf2; // 송신 큐에서 가져온 버퍼를 임시로 가지고 있는다.
  CEvQueue* evq; // 송신 큐
  int fd;
  FasynConnState state; /* uint8_t */
};

Fasyn* fasyn_new  (int argc, char** argv);
void   fasyn_free (Fasyn* fasyn);
int    fasyn_run  (Fasyn* fasyn);
void   fasyn_quit (Fasyn* fasyn);
void   fasyn_set_cb_request (Fasyn* fasyn,
                             FasynCallback cb_request,
                             void* cb_request_user_data);

// FIXME
void   fasyn_req_stdout (FasynReq* req);
void   fasyn_req_end (FasynReq* req);

C_END_DECLS

#endif /* __FASYN_H__ */
