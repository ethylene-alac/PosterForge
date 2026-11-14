#pragma once
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#define PF_MEMORY_BUDGET_MB 192
// ABI from Apple's xnu-8796.141.3 bsd/sys/kern_memorystatus.h.
typedef struct {
    int32_t activeMB;
    uint32_t activeAttributes;
    int32_t inactiveMB;
    uint32_t inactiveAttributes;
} PFMemoryLimits;
typedef int (*PFMemoryControl)(uint32_t, int32_t, uint32_t, void *, size_t);
typedef struct {
    pid_t pid;
    PFMemoryLimits before, after;
    int beforeError, setError, afterError;
    int attemptedSet, verified;
} PFMemoryStatus;

// Production setters ALWAYS target getpid(). No CLI can change another PID.
PFMemoryStatus PFConfigureCurrentProcessMemory(void);
PFMemoryStatus PFReadProcessMemory(pid_t pid);
// Injectable transport for host tests; does not call the real kernel API.
PFMemoryStatus PFMemoryConfigureUsing(PFMemoryControl control, pid_t pid);
uint64_t PFCurrentFootprintBytes(void);
