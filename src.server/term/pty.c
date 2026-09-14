#include <errno.h>
#include <limits.h>
#include <sys/ioctl.h>

int visualize_pty_resize(int fd, int rows, int cols) {
    if (rows < 1 || cols < 1 || rows > USHRT_MAX || cols > USHRT_MAX) return EINVAL;
    struct winsize size = {0};
    size.ws_row = (unsigned short)rows;
    size.ws_col = (unsigned short)cols;
    int result;
    do {
        result = ioctl(fd, TIOCSWINSZ, &size);
    } while (result < 0 && errno == EINTR);
    return result < 0 ? errno : 0;
}
