/* -*- Mode: C; indent-tabs-mode: nil; c-basic-offset: 2; tab-width: 2 -*- */
/*
 * fcgi.h
 * This file is part of Fcgi.
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
#ifndef __FCGI_H__
#define __FCGI_H__

#include "c-macros.h"
#include "c-loop.h"
#include <sys/un.h>

C_BEGIN_DECLS

typedef struct _Fcgi Fcgi;
struct _Fcgi {
  CLoop* loop;
  int    sockfd;
  struct sockaddr_un addr;
};

Fcgi* fcgi_new  (int argc, char** argv);
void  fcgi_free (Fcgi* fcgi);
int   fcgi_run  (Fcgi* fcgi);
void  fcgi_quit (Fcgi* fcgi);

C_END_DECLS

#endif /* __FCGI_H__ */
