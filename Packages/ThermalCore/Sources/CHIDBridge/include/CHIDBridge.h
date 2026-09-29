#ifndef CHID_BRIDGE_H
#define CHID_BRIDGE_H

#include <CoreFoundation/CoreFoundation.h>

/*
 IOHID 私有 API 声明。

 Apple Silicon 无公开温度 API。Stats / Hot / SMCKit 等开源软件均通过
 IOHIDEventSystem 私有接口读取 HID 温度传感器
 （PrimaryUsagePage 0xFF00, PrimaryUsage 0x0005）。

 通过本 C shim 隔离私有符号：Swift 侧只依赖 TemperatureProvider 协议，
 将来若 Apple 提供公开 API，仅需替换 IOHIDTemperatureProvider。
 */

CFTypeRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);
void IOHIDEventSystemClientSetMatching(CFTypeRef client, CFDictionaryRef matching);
CFArrayRef _Nullable IOHIDEventSystemClientCopyServices(CFTypeRef client);
CFTypeRef _Nullable IOHIDServiceClientCopyEvent(CFTypeRef service, long long type, int options, long long timeout);
CFTypeRef _Nullable IOHIDServiceClientCopyProperty(CFTypeRef service, CFTypeRef key);
double IOHIDEventGetFloatValue(CFTypeRef event, int field);

#endif /* CHID_BRIDGE_H */
