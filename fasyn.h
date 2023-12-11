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

C_BEGIN_DECLS

typedef struct _Fasyn Fasyn;
typedef struct _FasynConn FasynConn;
typedef void (*FasynCallback) (int fd, FasynConn* conn, void* user_data);

Fasyn* fasyn_new  (int argc, char** argv);
void   fasyn_free (Fasyn* fasyn);
int    fasyn_run  (Fasyn* fasyn);
void   fasyn_quit (Fasyn* fasyn);
void   fasyn_set_cb_outgoing (Fasyn* fasyn,
                              FasynCallback cb_outgoing,
                              void* cb_outgoing_user_data);

C_END_DECLS

#endif /* __FASYN_H__ */
