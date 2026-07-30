#ifndef RELAYCODE_LINUX_RUNTIME_H
#define RELAYCODE_LINUX_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RCLinuxVM RCLinuxVM;

typedef enum RCLinuxStepResult {
    RC_LINUX_STEP_RUNNING = 0,
    RC_LINUX_STEP_IDLE = 1,
    RC_LINUX_STEP_POWERED_OFF = 2,
    RC_LINUX_STEP_REBOOT_REQUESTED = 3,
    RC_LINUX_STEP_FAULTED = 4,
} RCLinuxStepResult;

RCLinuxVM *rc_linux_vm_create(
    const uint8_t *kernel_image,
    size_t kernel_size,
    size_t ram_size,
    const char *kernel_command_line
);

void rc_linux_vm_destroy(RCLinuxVM *vm);

RCLinuxStepResult rc_linux_vm_step(
    RCLinuxVM *vm,
    uint32_t instruction_budget,
    uint32_t elapsed_microseconds
);

bool rc_linux_vm_send_input(
    RCLinuxVM *vm,
    const uint8_t *bytes,
    size_t count
);

size_t rc_linux_vm_read_output(
    RCLinuxVM *vm,
    uint8_t *buffer,
    size_t capacity
);

bool rc_linux_vm_is_running(const RCLinuxVM *vm);
const char *rc_linux_runtime_version(void);

#ifdef __cplusplus
}
#endif

#endif
