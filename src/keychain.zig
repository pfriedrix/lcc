const std = @import("std");

const c = @cImport({
    @cInclude("CoreFoundation/CFBase.h");
    @cInclude("CoreFoundation/CFString.h");
    @cInclude("CoreFoundation/CFData.h");
    @cInclude("CoreFoundation/CFDictionary.h");
    @cInclude("CoreFoundation/CFNumber.h");
    @cInclude("Security/SecItem.h");
});

pub const Error = error{
    KeychainFailed,
    CoreFoundationFailed,
    OutOfMemory,
};

const err_sec_success: c.OSStatus = 0;
const err_sec_item_not_found: c.OSStatus = -25300;
const err_sec_duplicate_item: c.OSStatus = -25299;
const err_sec_auth_failed: c.OSStatus = -25293;
const err_sec_user_canceled: c.OSStatus = -128;

pub var last_status: c.OSStatus = err_sec_success;

fn cfString(s: []const u8) Error!c.CFStringRef {
    return c.CFStringCreateWithBytes(
        null,
        s.ptr,
        @intCast(s.len),
        c.kCFStringEncodingUTF8,
        0,
    ) orelse Error.CoreFoundationFailed;
}

fn cfData(bytes: []const u8) Error!c.CFDataRef {
    return c.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse
        Error.CoreFoundationFailed;
}

fn opaquePtr(ref: anytype) ?*const anyopaque {
    return @ptrCast(ref);
}

fn identityQuery(service: c.CFStringRef, account: c.CFStringRef) Error!c.CFMutableDictionaryRef {
    const dict = c.CFDictionaryCreateMutable(
        null,
        0,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return Error.CoreFoundationFailed;
    c.CFDictionarySetValue(dict, opaquePtr(c.kSecClass), opaquePtr(c.kSecClassGenericPassword));
    c.CFDictionarySetValue(dict, opaquePtr(c.kSecAttrService), opaquePtr(service));
    c.CFDictionarySetValue(dict, opaquePtr(c.kSecAttrAccount), opaquePtr(account));
    return dict;
}

pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
    const service_ref = try cfString(service);
    defer c.CFRelease(opaquePtr(service_ref));
    const account_ref = try cfString(account);
    defer c.CFRelease(opaquePtr(account_ref));

    const query = try identityQuery(service_ref, account_ref);
    defer c.CFRelease(opaquePtr(query));
    c.CFDictionarySetValue(query, opaquePtr(c.kSecReturnData), opaquePtr(c.kCFBooleanTrue));
    c.CFDictionarySetValue(query, opaquePtr(c.kSecMatchLimit), opaquePtr(c.kSecMatchLimitOne));

    var result: c.CFTypeRef = null;
    const status = c.SecItemCopyMatching(query, &result);
    last_status = status;
    if (status == err_sec_item_not_found) return null;
    if (status != err_sec_success) return Error.KeychainFailed;

    const data: c.CFDataRef = @ptrCast(result);
    defer c.CFRelease(result);

    const len: usize = @intCast(c.CFDataGetLength(data));
    const ptr = c.CFDataGetBytePtr(data);
    if (len == 0 or ptr == null) return try gpa.alloc(u8, 0);

    const out = try gpa.alloc(u8, len);
    @memcpy(out, ptr[0..len]);
    return out;
}

pub fn set(service: []const u8, account: []const u8, secret: []const u8) Error!void {
    const service_ref = try cfString(service);
    defer c.CFRelease(opaquePtr(service_ref));
    const account_ref = try cfString(account);
    defer c.CFRelease(opaquePtr(account_ref));
    const secret_ref = try cfData(secret);
    defer c.CFRelease(opaquePtr(secret_ref));

    const query = try identityQuery(service_ref, account_ref);
    defer c.CFRelease(opaquePtr(query));

    const attrs = c.CFDictionaryCreateMutable(
        null,
        0,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return Error.CoreFoundationFailed;
    defer c.CFRelease(opaquePtr(attrs));
    c.CFDictionarySetValue(attrs, opaquePtr(c.kSecValueData), opaquePtr(secret_ref));

    const update_status = c.SecItemUpdate(query, attrs);
    last_status = update_status;
    if (update_status == err_sec_success) return;
    if (update_status != err_sec_item_not_found) return Error.KeychainFailed;

    const add_query = try identityQuery(service_ref, account_ref);
    defer c.CFRelease(opaquePtr(add_query));
    c.CFDictionarySetValue(add_query, opaquePtr(c.kSecValueData), opaquePtr(secret_ref));

    const add_status = c.SecItemAdd(add_query, null);
    last_status = add_status;
    if (add_status != err_sec_success) return Error.KeychainFailed;
}

pub fn delete(service: []const u8, account: []const u8) Error!void {
    const service_ref = try cfString(service);
    defer c.CFRelease(opaquePtr(service_ref));
    const account_ref = try cfString(account);
    defer c.CFRelease(opaquePtr(account_ref));

    const query = try identityQuery(service_ref, account_ref);
    defer c.CFRelease(opaquePtr(query));

    const status = c.SecItemDelete(query);
    last_status = status;
    if (status == err_sec_success or status == err_sec_item_not_found) return;
    return Error.KeychainFailed;
}

pub fn describeStatus(status: c.OSStatus) []const u8 {
    return switch (status) {
        err_sec_success => "success",
        err_sec_item_not_found => "item not found",
        err_sec_duplicate_item => "duplicate item",
        err_sec_auth_failed => "authorization failed (keychain prompt denied?)",
        err_sec_user_canceled => "user canceled the keychain prompt",
        else => "unmapped OSStatus",
    };
}
