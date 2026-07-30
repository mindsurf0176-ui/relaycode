#include "RelayCodeLinuxRuntime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "default64mbdtc.h"

#define RC_INPUT_CAPACITY (16u * 1024u)
#define RC_OUTPUT_CAPACITY (1024u * 1024u)
#define RC_DEFAULT_RAM_SIZE (64u * 1024u * 1024u)
#define RC_MINIMUM_RAM_SIZE (16u * 1024u * 1024u)
#define RC_MAXIMUM_RAM_SIZE (256u * 1024u * 1024u)
#define RC_COMMAND_LINE_OFFSET 0xc0u
#define RC_COMMAND_LINE_CAPACITY 54u

struct MiniRV32IMAState;

typedef struct RCRingBuffer {
    uint8_t *bytes;
    size_t capacity;
    size_t read_index;
    size_t count;
} RCRingBuffer;

struct RCLinuxVM {
    uint8_t *ram;
    size_t ram_size;
    struct MiniRV32IMAState *core;
    RCRingBuffer input;
    RCRingBuffer output;
    bool running;
};

static _Thread_local RCLinuxVM *rc_active_vm;

static uint32_t rc_handle_exception(uint32_t instruction, uint32_t code);
static uint32_t rc_handle_control_store(uint32_t address, uint32_t value);
static uint32_t rc_handle_control_load(uint32_t address);
static void rc_handle_csr_write(
    uint8_t *image,
    uint16_t csr_number,
    uint32_t value
);
static int32_t rc_handle_csr_read(
    uint8_t *image,
    uint16_t csr_number
);

#define MINIRV32WARN(...)
#define MINIRV32_DECORATE static
#define MINI_RV32_RAM_SIZE (rc_active_vm->ram_size)
#define MINIRV32_IMPLEMENTATION
#define MINIRV32_POSTEXEC(pc, ir, retval) \
    do { \
        if ((retval) > 0) { \
            (retval) = rc_handle_exception((ir), (retval)); \
        } \
    } while (0)
#define MINIRV32_HANDLE_MEM_STORE_CONTROL(address, value) \
    do { \
        if (rc_handle_control_store((address), (value))) { \
            return (value); \
        } \
    } while (0)
#define MINIRV32_HANDLE_MEM_LOAD_CONTROL(address, result) \
    do { \
        (result) = rc_handle_control_load((address)); \
    } while (0)
#define MINIRV32_OTHERCSR_WRITE(csr_number, value) \
    rc_handle_csr_write(image, (csr_number), (value))
#define MINIRV32_OTHERCSR_READ(csr_number, value) \
    do { \
        (value) = rc_handle_csr_read(image, (csr_number)); \
    } while (0)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "mini-rv32ima.h"
#pragma clang diagnostic pop

static bool rc_ring_create(RCRingBuffer *ring, size_t capacity) {
    ring->bytes = calloc(capacity, 1);
    if (ring->bytes == NULL) {
        return false;
    }
    ring->capacity = capacity;
    ring->read_index = 0;
    ring->count = 0;
    return true;
}

static void rc_ring_destroy(RCRingBuffer *ring) {
    free(ring->bytes);
    memset(ring, 0, sizeof(*ring));
}

static bool rc_ring_write_exact(
    RCRingBuffer *ring,
    const uint8_t *bytes,
    size_t count
) {
    if (bytes == NULL || count > ring->capacity - ring->count) {
        return false;
    }
    size_t write_index = (ring->read_index + ring->count) % ring->capacity;
    for (size_t index = 0; index < count; index += 1) {
        ring->bytes[write_index] = bytes[index];
        write_index = (write_index + 1) % ring->capacity;
    }
    ring->count += count;
    return true;
}

static void rc_ring_write_lossy(
    RCRingBuffer *ring,
    const uint8_t *bytes,
    size_t count
) {
    if (bytes == NULL || count == 0) {
        return;
    }
    if (count >= ring->capacity) {
        bytes += count - ring->capacity;
        count = ring->capacity;
        ring->read_index = 0;
        ring->count = 0;
    }
    while (count > ring->capacity - ring->count) {
        ring->read_index = (ring->read_index + 1) % ring->capacity;
        ring->count -= 1;
    }
    (void)rc_ring_write_exact(ring, bytes, count);
}

static size_t rc_ring_read(
    RCRingBuffer *ring,
    uint8_t *buffer,
    size_t capacity
) {
    if (buffer == NULL || capacity == 0) {
        return 0;
    }
    size_t count = ring->count < capacity ? ring->count : capacity;
    for (size_t index = 0; index < count; index += 1) {
        buffer[index] = ring->bytes[ring->read_index];
        ring->read_index = (ring->read_index + 1) % ring->capacity;
    }
    ring->count -= count;
    return count;
}

static int rc_input_available(void) {
    return rc_active_vm != NULL && rc_active_vm->input.count > 0;
}

static int rc_read_input(void) {
    uint8_t value = 0;
    if (rc_active_vm == NULL
        || rc_ring_read(&rc_active_vm->input, &value, 1) != 1) {
        return -1;
    }
    return value;
}

static void rc_write_output_byte(uint8_t value) {
    if (rc_active_vm != NULL) {
        rc_ring_write_lossy(&rc_active_vm->output, &value, 1);
    }
}

static void rc_write_output_string(
    const uint8_t *image,
    uint32_t guest_address
) {
    if (rc_active_vm == NULL
        || guest_address < MINIRV32_RAM_IMAGE_OFFSET) {
        return;
    }
    uint32_t start = guest_address - MINIRV32_RAM_IMAGE_OFFSET;
    if ((size_t)start >= rc_active_vm->ram_size) {
        return;
    }
    uint32_t end = start;
    while ((size_t)end < rc_active_vm->ram_size && image[end] != 0) {
        end += 1;
    }
    if (end > start) {
        rc_ring_write_lossy(
            &rc_active_vm->output,
            image + start,
            end - start
        );
    }
}

RCLinuxVM *rc_linux_vm_create(
    const uint8_t *kernel_image,
    size_t kernel_size,
    size_t ram_size,
    const char *kernel_command_line
) {
    if (kernel_image == NULL || kernel_size == 0) {
        return NULL;
    }
    if (ram_size == 0) {
        ram_size = RC_DEFAULT_RAM_SIZE;
    }
    if (ram_size < RC_MINIMUM_RAM_SIZE || ram_size > RC_MAXIMUM_RAM_SIZE) {
        return NULL;
    }
    if (ram_size <= sizeof(default64mbdtb) + sizeof(struct MiniRV32IMAState)
        || kernel_size > ram_size - sizeof(default64mbdtb)
            - sizeof(struct MiniRV32IMAState)) {
        return NULL;
    }

    RCLinuxVM *vm = calloc(1, sizeof(*vm));
    if (vm == NULL) {
        return NULL;
    }
    vm->ram = calloc(ram_size, 1);
    if (vm->ram == NULL
        || !rc_ring_create(&vm->input, RC_INPUT_CAPACITY)
        || !rc_ring_create(&vm->output, RC_OUTPUT_CAPACITY)) {
        rc_linux_vm_destroy(vm);
        return NULL;
    }
    vm->ram_size = ram_size;
    memcpy(vm->ram, kernel_image, kernel_size);

    size_t device_tree_offset = ram_size
        - sizeof(default64mbdtb)
        - sizeof(struct MiniRV32IMAState);
    memcpy(
        vm->ram + device_tree_offset,
        default64mbdtb,
        sizeof(default64mbdtb)
    );

    const char *command_line = kernel_command_line;
    if (command_line == NULL || command_line[0] == '\0') {
        command_line = "console=ttyS0 quiet";
    }
    if (device_tree_offset + RC_COMMAND_LINE_OFFSET
        + RC_COMMAND_LINE_CAPACITY <= ram_size) {
        char *destination = (char *)(
            vm->ram + device_tree_offset + RC_COMMAND_LINE_OFFSET
        );
        memset(destination, 0, RC_COMMAND_LINE_CAPACITY);
        strncpy(destination, command_line, RC_COMMAND_LINE_CAPACITY - 1);
    }

    uint32_t *device_tree = (uint32_t *)(vm->ram + device_tree_offset);
    if (device_tree[0x13c / 4] == 0x00c0ff03) {
        uint32_t valid_ram = (uint32_t)device_tree_offset;
        device_tree[0x13c / 4] =
            (valid_ram >> 24)
            | (((valid_ram >> 16) & 0xff) << 8)
            | (((valid_ram >> 8) & 0xff) << 16)
            | ((valid_ram & 0xff) << 24);
    }

    vm->core = (struct MiniRV32IMAState *)(
        vm->ram + ram_size - sizeof(struct MiniRV32IMAState)
    );
    vm->core->pc = MINIRV32_RAM_IMAGE_OFFSET;
    vm->core->regs[10] = 0;
    vm->core->regs[11] = (uint32_t)(
        device_tree_offset + MINIRV32_RAM_IMAGE_OFFSET
    );
    vm->core->extraflags |= 3;
    vm->running = true;
    return vm;
}

void rc_linux_vm_destroy(RCLinuxVM *vm) {
    if (vm == NULL) {
        return;
    }
    if (rc_active_vm == vm) {
        rc_active_vm = NULL;
    }
    rc_ring_destroy(&vm->input);
    rc_ring_destroy(&vm->output);
    free(vm->ram);
    memset(vm, 0, sizeof(*vm));
    free(vm);
}

RCLinuxStepResult rc_linux_vm_step(
    RCLinuxVM *vm,
    uint32_t instruction_budget,
    uint32_t elapsed_microseconds
) {
    if (vm == NULL || !vm->running || instruction_budget == 0) {
        return RC_LINUX_STEP_FAULTED;
    }
    rc_active_vm = vm;
    int result = MiniRV32IMAStep(
        vm->core,
        vm->ram,
        0,
        elapsed_microseconds,
        instruction_budget
    );
    rc_active_vm = NULL;

    switch (result) {
    case 0:
        return RC_LINUX_STEP_RUNNING;
    case 1: {
        uint64_t *cycle_count = (uint64_t *)&vm->core->cyclel;
        *cycle_count += instruction_budget;
        return RC_LINUX_STEP_IDLE;
    }
    case 0x5555:
        vm->running = false;
        return RC_LINUX_STEP_POWERED_OFF;
    case 0x7777:
        vm->running = false;
        return RC_LINUX_STEP_REBOOT_REQUESTED;
    default:
        vm->running = false;
        return RC_LINUX_STEP_FAULTED;
    }
}

bool rc_linux_vm_send_input(
    RCLinuxVM *vm,
    const uint8_t *bytes,
    size_t count
) {
    if (vm == NULL || !vm->running || bytes == NULL || count == 0) {
        return false;
    }
    return rc_ring_write_exact(&vm->input, bytes, count);
}

size_t rc_linux_vm_read_output(
    RCLinuxVM *vm,
    uint8_t *buffer,
    size_t capacity
) {
    if (vm == NULL) {
        return 0;
    }
    return rc_ring_read(&vm->output, buffer, capacity);
}

bool rc_linux_vm_is_running(const RCLinuxVM *vm) {
    return vm != NULL && vm->running;
}

const char *rc_linux_runtime_version(void) {
    return "mini-rv32ima/Linux-riscv32";
}

static uint32_t rc_handle_exception(
    uint32_t instruction,
    uint32_t code
) {
    (void)instruction;
    return code;
}

static uint32_t rc_handle_control_store(
    uint32_t address,
    uint32_t value
) {
    if (rc_active_vm == NULL) {
        return 0;
    }
    if (address == 0x10000000) {
        rc_write_output_byte((uint8_t)value);
    } else if (address == 0x11004004) {
        rc_active_vm->core->timermatchh = value;
    } else if (address == 0x11004000) {
        rc_active_vm->core->timermatchl = value;
    } else if (address == 0x11100000) {
        rc_active_vm->core->pc += 4;
        return value;
    }
    return 0;
}

static uint32_t rc_handle_control_load(uint32_t address) {
    if (rc_active_vm == NULL) {
        return 0;
    }
    if (address == 0x10000005) {
        return 0x60 | (uint32_t)rc_input_available();
    }
    if (address == 0x10000000 && rc_input_available()) {
        return (uint32_t)rc_read_input();
    }
    if (address == 0x1100bffc) {
        return rc_active_vm->core->timerh;
    }
    if (address == 0x1100bff8) {
        return rc_active_vm->core->timerl;
    }
    return 0;
}

static void rc_handle_csr_write(
    uint8_t *image,
    uint16_t csr_number,
    uint32_t value
) {
    if (csr_number == 0x136) {
        char digits[16];
        int length = snprintf(digits, sizeof(digits), "%u", value);
        if (length > 0 && rc_active_vm != NULL) {
            rc_ring_write_lossy(
                &rc_active_vm->output,
                (const uint8_t *)digits,
                (size_t)length
            );
        }
    } else if (csr_number == 0x137) {
        char digits[16];
        int length = snprintf(digits, sizeof(digits), "%08x", value);
        if (length > 0 && rc_active_vm != NULL) {
            rc_ring_write_lossy(
                &rc_active_vm->output,
                (const uint8_t *)digits,
                (size_t)length
            );
        }
    } else if (csr_number == 0x138) {
        rc_write_output_string(image, value);
    } else if (csr_number == 0x139) {
        rc_write_output_byte((uint8_t)value);
    }
}

static int32_t rc_handle_csr_read(
    uint8_t *image,
    uint16_t csr_number
) {
    (void)image;
    if (csr_number == 0x140) {
        return rc_input_available() ? rc_read_input() : -1;
    }
    return 0;
}
