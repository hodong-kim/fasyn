DEPS_CFLAGS = `pkg-config --cflags jansson libcurl`
DEPS_LIBS   = `pkg-config --libs jansson libcurl` -L/usr/local/lib -lintl

CFLAGS = -Wall -Werror -std=c2x \
	-I/usr/local/include -I/home/hodong/projects/nimf/clair/src \
	$(DEPS_CFLAGS)

LIBADD = \
	/home/hodong/projects/nimf/clair/src/libclair.a

TARGET = fasyn

C_SOURCES = $(TARGET).c main.c
C_HEADERS = fastcgi.h fasyn.h

$(TARGET): Makefile $(C_SOURCES) $(C_HEADERS)
	$(CC) $(CFLAGS) $(C_SOURCES) $(LIBADD) $(DEPS_LIBS) -o $(TARGET)

clean:
	rm -f $(TARGET) $(TARGET).sock
