#include "PFMemory.h"
// This translation unit deliberately uses no Objective-C/Foundation calls.
#include <dlfcn.h>
#include <errno.h>
#include <unistd.h>
#include <mach/mach.h>

enum { PFSetMemlimitProperties = 7, PFGetMemlimitProperties = 8, PFFatalLimit = 1 };
_Static_assert(sizeof(PFMemoryLimits) == 16, "Unexpected memorystatus ABI");

static PFMemoryControl PFControl(void) {
    return (PFMemoryControl)dlsym(RTLD_DEFAULT, "memorystatus_control");
}

static int PFRead(PFMemoryControl control, pid_t pid, PFMemoryLimits *limits) {
    if (!control) return ENOSYS;
    if (control(PFGetMemlimitProperties, pid, 0, limits, sizeof(*limits)) < 0) return errno ? errno : EIO;
    return 0;
}

static int PFEnough(PFMemoryLimits limits) {
    return limits.activeMB >= PF_MEMORY_BUDGET_MB && limits.inactiveMB >= PF_MEMORY_BUDGET_MB;
}

PFMemoryStatus PFMemoryConfigureUsing(PFMemoryControl control, pid_t pid) {
    PFMemoryStatus status = { .pid = pid };
    status.beforeError = PFRead(control, pid, &status.before);
    if (!status.beforeError && PFEnough(status.before)) {
        status.after = status.before;
        status.verified = 1;
        return status;
    }
    if (!control) { status.afterError = ENOSYS; return status; }
    PFMemoryLimits requested = {
        .activeMB = status.before.activeMB > PF_MEMORY_BUDGET_MB ? status.before.activeMB : PF_MEMORY_BUDGET_MB,
        .inactiveMB = status.before.inactiveMB > PF_MEMORY_BUDGET_MB ? status.before.inactiveMB : PF_MEMORY_BUDGET_MB,
        .activeAttributes = PFFatalLimit, .inactiveAttributes = PFFatalLimit
    };
    status.attemptedSet = 1;
    if (control(PFSetMemlimitProperties, pid, 0, &requested, sizeof(requested)) < 0) status.setError = errno ? errno : EIO;
    status.afterError = PFRead(control, pid, &status.after);
    // SET returning zero is insufficient: Dopamine may intercept some commands.
    status.verified = !status.afterError && PFEnough(status.after);
    return status;
}

PFMemoryStatus PFConfigureCurrentProcessMemory(void) { return PFMemoryConfigureUsing(PFControl(), getpid()); }

PFMemoryStatus PFReadProcessMemory(pid_t pid) {
    PFMemoryStatus status = { .pid = pid };
    if (pid <= 0) { status.afterError = EINVAL; return status; }
    status.afterError = PFRead(PFControl(), pid, &status.after);
    status.verified = !status.afterError && PFEnough(status.after);
    return status;
}

uint64_t PFCurrentFootprintBytes(void) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}
