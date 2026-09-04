#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

// A tiny unbuffered PTY relay for the native GUI.  macOS's `script` command
// can retain a small first chunk when launched by a GUI process whose stdout
// is a Foundation Pipe.  forkpty gives the CLI a real controlling terminal;
// this relay copies bytes with read/write so prompts reach Swift immediately.
static volatile sig_atomic_t child_pid = -1;

static void forward_signal(int signal_number) {
    pid_t child = (pid_t)child_pid;
    if (child > 0) {
        // forkpty makes the child a session leader.  Forward to its process
        // group so OpenSSH and any helper it spawned are stopped together.
        (void)kill(-child, signal_number);
        (void)kill(child, signal_number);
    }
}

static int write_all(int fd, const unsigned char *buffer, ssize_t length) {
    ssize_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, buffer + offset, (size_t)(length - offset));
        if (written > 0) {
            offset += written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return 64;

    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_col = 160;
    size.ws_row = 48;

    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) return 70;
    child_pid = child;

    if (child == 0) {
        // Keep the terminal deterministic for the CLI's framed output. The
        // parent already supplied PNA_GUI_MODE and all other environment.
        setenv("TERM", "dumb", 1);
        // The GUI sends secrets through this PTY. Disable terminal echo from
        // the moment the CLI starts so a password can never come back through
        // the output pipe or appear in the native log.
        struct termios terminal;
        if (tcgetattr(STDIN_FILENO, &terminal) == 0) {
            terminal.c_lflag &= (tcflag_t)~(ECHO | ECHONL);
            (void)tcsetattr(STDIN_FILENO, TCSANOW, &terminal);
        }
        execvp(argv[1], &argv[1]);
        _exit(127);
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = forward_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);

    unsigned char buffer[8192];
    int input_open = 1;
    for (;;) {
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(master, &readable);
        int highest = master;
        if (input_open) {
            FD_SET(STDIN_FILENO, &readable);
            if (STDIN_FILENO > highest) highest = STDIN_FILENO;
        }

        int ready = select(highest + 1, &readable, NULL, NULL, NULL);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (input_open && FD_ISSET(STDIN_FILENO, &readable)) {
            ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
            if (count > 0) {
                if (write_all(master, buffer, count) < 0) input_open = 0;
            } else if (count == 0 || (count < 0 && errno != EINTR)) {
                input_open = 0;
            }
        }

        if (FD_ISSET(master, &readable)) {
            ssize_t count = read(master, buffer, sizeof(buffer));
            if (count > 0) {
                if (write_all(STDOUT_FILENO, buffer, count) < 0) break;
            } else if (count == 0 || (count < 0 && errno != EINTR)) {
                break;
            }
        }
    }

    close(master);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    child_pid = -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
