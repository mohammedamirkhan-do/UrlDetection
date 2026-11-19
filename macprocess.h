#pragma once

#import <Foundation/Foundation.h>
#include <sys/types.h>

pid_t applicationProcessId(pid_t reportedPid, NSString *executablePath);
