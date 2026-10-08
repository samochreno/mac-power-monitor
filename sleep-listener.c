#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

static io_connect_t root_port;
static char monitor_path[PATH_MAX];

static void run_monitor(const char *mode) {
  pid_t child = fork();

  if (child == 0) {
    execl("/bin/zsh", "/bin/zsh", monitor_path, mode, NULL);
    _exit(127);
  }

  if (child < 0) {
    perror("fork");
    return;
  }

  int status;
  while (waitpid(child, &status, 0) < 0) {
  }
}

static void power_source_changed(void *context) {
  (void)context;
  run_monitor("--power-source-change");
}

static void power_message(
    void *context,
    io_service_t service,
    natural_t message_type,
    void *message_argument
) {
  (void)context;
  (void)service;

  switch (message_type) {
    case kIOMessageCanSystemSleep:
      IOAllowPowerChange(root_port, (long)(intptr_t)message_argument);
      break;
    case kIOMessageSystemWillSleep:
      run_monitor("--pre-sleep");
      IOAllowPowerChange(root_port, (long)(intptr_t)message_argument);
      break;
    default:
      break;
  }
}

static int resolve_monitor_path(const char *executable) {
  char resolved[PATH_MAX];
  char *separator;

  if (realpath(executable, resolved) == NULL) {
    return -1;
  }

  separator = strrchr(resolved, '/');
  if (separator == NULL) {
    return -1;
  }

  *separator = '\0';
  if (snprintf(monitor_path, sizeof(monitor_path), "%s/monitor.zsh", resolved) >=
      (int)sizeof(monitor_path)) {
    return -1;
  }

  return 0;
}

int main(int argc, char **argv) {
  (void)argc;

  if (resolve_monitor_path(argv[0]) != 0) {
    fprintf(stderr, "Could not resolve monitor.zsh next to the listener.\n");
    return 1;
  }

  IONotificationPortRef notification_port = NULL;
  io_object_t notifier = IO_OBJECT_NULL;
  root_port = IORegisterForSystemPower(
      NULL,
      &notification_port,
      power_message,
      &notifier
  );

  if (root_port == IO_OBJECT_NULL || notification_port == NULL) {
    fprintf(stderr, "Could not register for system power notifications.\n");
    return 1;
  }

  CFRunLoopSourceRef sleep_source =
      IONotificationPortGetRunLoopSource(notification_port);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), sleep_source, kCFRunLoopDefaultMode);

  CFRunLoopSourceRef power_source =
      IOPSNotificationCreateRunLoopSource(power_source_changed, NULL);
  if (power_source == NULL) {
    fprintf(stderr, "Could not register for power-source notifications.\n");
    return 1;
  }

  CFRunLoopAddSource(CFRunLoopGetCurrent(), power_source, kCFRunLoopDefaultMode);
  CFRunLoopRun();

  CFRelease(power_source);
  IODeregisterForSystemPower(&notifier);
  IOServiceClose(root_port);
  IONotificationPortDestroy(notification_port);
  return 0;
}
