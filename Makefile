CFLAGS = -Wall -I/usr/local/include -I/home/hodong/projects/nimf/clair/src
LIBADD = /home/hodong/projects/nimf/clair/src/libclair.a

C_SOURCES = checkout.c
C_HEADERS =

checkout: Makefile $(C_SOURCES) $(C_HEADERS)
	$(CC) $(CFLAGS) $(C_SOURCES) $(LIBADD) -o checkout
