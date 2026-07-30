#include "RelayCodeLinuxRuntime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OUTPUT_CAPACITY (2u * 1024u * 1024u)

static unsigned char *read_file(const char *path, size_t *size) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long length = ftell(file);
    if (length <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    unsigned char *bytes = malloc((size_t)length);
    if (bytes == NULL || fread(bytes, (size_t)length, 1, file) != 1) {
        free(bytes);
        fclose(file);
        return NULL;
    }
    fclose(file);
    *size = (size_t)length;
    return bytes;
}

static int send_text(RCLinuxVM *vm, const char *value) {
    return rc_linux_vm_send_input(
        vm,
        (const uint8_t *)value,
        strlen(value)
    ) ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: linux-runtime-smoke <linux-image>\n");
        return 2;
    }

    size_t image_size = 0;
    unsigned char *image = read_file(argv[1], &image_size);
    if (image == NULL) {
        fprintf(stderr, "could not read Linux image\n");
        return 3;
    }

    RCLinuxVM *vm = rc_linux_vm_create(
        image,
        image_size,
        64u * 1024u * 1024u,
        "console=ttyS0 quiet"
    );
    free(image);
    if (vm == NULL) {
        fprintf(stderr, "could not create Linux VM\n");
        return 4;
    }

    char *output = calloc(OUTPUT_CAPACITY, 1);
    if (output == NULL) {
        rc_linux_vm_destroy(vm);
        return 5;
    }
    size_t output_count = 0;
    int sent_login = 0;
    int sent_probe = 0;
    int passed = 0;

    for (int iteration = 0; iteration < 30000; iteration += 1) {
        RCLinuxStepResult result = rc_linux_vm_step(vm, 65536, 1000);

        if (output_count < OUTPUT_CAPACITY - 1) {
            output_count += rc_linux_vm_read_output(
                vm,
                (uint8_t *)output + output_count,
                OUTPUT_CAPACITY - output_count - 1
            );
            output[output_count] = '\0';
        }

        if (!sent_login && strstr(output, "buildroot login:") != NULL) {
            if (send_text(vm, "root\n") != 0) {
                break;
            }
            sent_login = 1;
        }
        if (sent_login
            && !sent_probe
            && strstr(output, "root login on") != NULL
            && strstr(output, "~ # ") != NULL) {
            if (send_text(
                    vm,
                    "printf RELAYCODE_FILE_OK > /tmp/relaycode.txt; "
                    "cat /tmp/relaycode.txt; "
                    "uname -a; echo RELAYCODE_LINUX_OK; poweroff\n"
                ) != 0) {
                break;
            }
            sent_probe = 1;
        }
        if (strstr(output, "Linux buildroot 6.1.14") != NULL
            && strstr(output, "RELAYCODE_FILE_OK") != NULL
            && strstr(output, "RELAYCODE_LINUX_OK") != NULL) {
            passed = 1;
        }
        if (result == RC_LINUX_STEP_POWERED_OFF) {
            break;
        }
        if (result == RC_LINUX_STEP_FAULTED
            || result == RC_LINUX_STEP_REBOOT_REQUESTED) {
            break;
        }
    }

    if (!passed) {
        fprintf(stderr, "Linux runtime smoke test failed:\n%s\n", output);
    } else {
        printf(
            "Linux runtime smoke test passed: Linux 6.1.14 riscv32 "
            "executed BusyBox shell and file commands.\n"
        );
    }

    free(output);
    rc_linux_vm_destroy(vm);
    return passed ? 0 : 6;
}
