DEPS_CFLAGS = `pkg-config --cflags jansson libcurl`
DEPS_LIBS   = -L/usr/local/lib -lintl

CFLAGS = -Wall -Werror \
	-I/usr/local/include -I/home/hodong/projects/nimf/clair/src \
	$(DEPS_CFLAGS)

LIBADD = \
	/home/hodong/projects/nimf/clair/src/libclair.a \
	/usr/local/lib/libjansson.a \
	/usr/local/lib/libcurl.a

TARGET = fcgi

C_SOURCES = $(TARGET).c main.c
C_HEADERS = fastcgi.h fcgi.h

$(TARGET): Makefile $(C_SOURCES) $(C_HEADERS) $(TARGET).sock
	$(CC) $(CFLAGS) $(C_SOURCES) $(LIBADD) $(DEPS_LIBS) -o $(TARGET)
	sudo chown www:www fcgi.sock

clean:
	rm -f $(TARGET)
