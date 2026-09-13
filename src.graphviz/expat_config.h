#pragma once
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define BYTEORDER 4321
#else
#define BYTEORDER 1234
#endif
#define HAVE_UNISTD_H 1
#define HAVE_FCNTL_H 1
#define XML_DEV_URANDOM 1
#define XML_CONTEXT_BYTES 1024
#define XML_NS 1
#define XML_GE 1
