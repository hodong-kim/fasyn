CFLAGS = -Wall -I/usr/local/include -I/home/hodong/projects/nimf/clair/src
LIBADD = /home/hodong/projects/nimf/clair/src/libclair.a
TARGET = checkout

C_SOURCES = $(TARGET).c
C_HEADERS = fastcgi.h

checkout: Makefile $(C_SOURCES) $(C_HEADERS)
	$(CC) $(CFLAGS) $(C_SOURCES) $(LIBADD) -o $(TARGET)

clean:
	rm -f $(TARGET) $(TARGET).sock
