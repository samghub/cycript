/* Cyrker - Remove Execution Server and Disassembler
 * Copyright (C) 2009  Jay Freeman (saurik)
*/

/* Modified BSD License {{{ */
/*
 *        Redistribution and use in source and binary
 * forms, with or without modification, are permitted
 * provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer in the documentation
 *    and/or other materials provided with the
 *    distribution.
 * 3. The name of the author may not be used to endorse
 *    or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
/* }}} */

#include <substrate.h>

#include "sig/parse.hpp"
#include "sig/ffi_type.hpp"

#include <apr-1/apr_pools.h>
#include <apr-1/apr_strings.h>

#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFLogUtilities.h>

#include <CFNetwork/CFNetwork.h>
#include <Foundation/Foundation.h>

#include <JavaScriptCore/JSBase.h>
#include <JavaScriptCore/JSValueRef.h>
#include <JavaScriptCore/JSObjectRef.h>
#include <JavaScriptCore/JSContextRef.h>
#include <JavaScriptCore/JSStringRef.h>
#include <JavaScriptCore/JSStringRefCF.h>

#include <WebKit/WebScriptObject.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>

#undef _assert
#undef _trace

/* XXX: bad _assert */
#define _assert(test) do { \
    if ((test)) break; \
    CFLog(kCFLogLevelNotice, CFSTR("_assert(%s):%u"), #test, __LINE__); \
    throw; \
} while (false)

#define _trace() do { \
    CFLog(kCFLogLevelNotice, CFSTR("_trace():%u"), __LINE__); \
} while (false)

/* Objective-C Handle<> {{{ */
template <typename Type_>
class _H {
    typedef _H<Type_> This_;

  private:
    Type_ *value_;

    _finline void Retain_() {
        if (value_ != nil)
            [value_ retain];
    }

    _finline void Clear_() {
        if (value_ != nil)
            [value_ release];
    }

  public:
    _finline _H(const This_ &rhs) :
        value_(rhs.value_ == nil ? nil : [rhs.value_ retain])
    {
    }

    _finline _H(Type_ *value = NULL, bool mended = false) :
        value_(value)
    {
        if (!mended)
            Retain_();
    }

    _finline ~_H() {
        Clear_();
    }

    _finline operator Type_ *() const {
        return value_;
    }

    _finline This_ &operator =(Type_ *value) {
        if (value_ != value) {
            Type_ *old(value_);
            value_ = value;
            Retain_();
            if (old != nil)
                [old release];
        } return *this;
    }
};
/* }}} */

#define _pooled _H<NSAutoreleasePool> _pool([[NSAutoreleasePool alloc] init], true);

static JSContextRef Context_;

static JSClassRef ffi_;
static JSClassRef joc_;
static JSClassRef ptr_;
static JSClassRef sel_;

static JSObjectRef Array_;

static JSStringRef name_;
static JSStringRef message_;
static JSStringRef length_;

static Class NSCFBoolean_;

struct Client {
    CFHTTPMessageRef message_;
    CFSocketRef socket_;
};

@interface NSMethodSignature (Cyrver)
- (NSString *) _typeString;
@end

@interface NSObject (Cyrver)
- (NSString *) cy$toJSON;
- (JSValueRef) cy$JSValueInContext:(JSContextRef)context;
@end

@implementation NSObject (Cyrver)

- (NSString *) cy$toJSON {
    return [self description];
}

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context {
    return JSObjectMake(context, joc_, [self retain]);
}

@end

@implementation WebUndefined (Cyrver)

- (NSString *) cy$toJSON {
    return @"undefined";
}

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context {
    return JSValueMakeUndefined(context);
}

@end

@implementation NSArray (Cyrver)

- (NSString *) cy$toJSON {
    NSMutableString *json([[[NSMutableString alloc] init] autorelease]);
    [json appendString:@"["];

    bool comma(false);
    for (id object in self) {
        if (comma)
            [json appendString:@","];
        else
            comma = true;
        [json appendString:[object cy$toJSON]];
    }

    [json appendString:@"]"];
    return json;
}

@end

@implementation NSDictionary (Cyrver)

- (NSString *) cy$toJSON {
    NSMutableString *json([[[NSMutableString alloc] init] autorelease]);
    [json appendString:@"("];
    [json appendString:@"{"];

    bool comma(false);
    for (id key in self) {
        if (comma)
            [json appendString:@","];
        else
            comma = true;
        [json appendString:[key cy$toJSON]];
        [json appendString:@":"];
        NSObject *object([self objectForKey:key]);
        [json appendString:[object cy$toJSON]];
    }

    [json appendString:@"})"];
    return json;
}

@end

@implementation NSNumber (Cyrver)

- (NSString *) cy$toJSON {
    return [self class] != NSCFBoolean_ ? [self stringValue] : [self boolValue] ? @"true" : @"false";
}

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context {
    return [self class] != NSCFBoolean_ ? JSValueMakeNumber(context, [self doubleValue]) : JSValueMakeBoolean(context, [self boolValue]);
}

@end

@implementation NSString (Cyrver)

- (NSString *) cy$toJSON {
    CFMutableStringRef json(CFStringCreateMutableCopy(kCFAllocatorDefault, 0, (CFStringRef) self));

    CFStringFindAndReplace(json, CFSTR("\\"), CFSTR("\\\\"), CFRangeMake(0, CFStringGetLength(json)), 0);
    CFStringFindAndReplace(json, CFSTR("\""), CFSTR("\\\""), CFRangeMake(0, CFStringGetLength(json)), 0);
    CFStringFindAndReplace(json, CFSTR("\t"), CFSTR("\\t"), CFRangeMake(0, CFStringGetLength(json)), 0);
    CFStringFindAndReplace(json, CFSTR("\r"), CFSTR("\\r"), CFRangeMake(0, CFStringGetLength(json)), 0);
    CFStringFindAndReplace(json, CFSTR("\n"), CFSTR("\\n"), CFRangeMake(0, CFStringGetLength(json)), 0);

    CFStringInsert(json, 0, CFSTR("\""));
    CFStringAppend(json, CFSTR("\""));

    return [reinterpret_cast<const NSString *>(json) autorelease];
}

@end

@interface CY$JSObject : NSDictionary {
    JSObjectRef object_;
    JSContextRef context_;
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context;

- (NSUInteger) count;
- (id) objectForKey:(id)key;
- (NSEnumerator *) keyEnumerator;
- (void) setObject:(id)object forKey:(id)key;
- (void) removeObjectForKey:(id)key;

@end

@interface CY$JSArray : NSArray {
    JSObjectRef object_;
    JSContextRef context_;
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context;

- (NSUInteger) count;
- (id) objectAtIndex:(NSUInteger)index;

@end

JSContextRef JSGetContext() {
    return Context_;
}

void CYThrow(JSContextRef context, JSValueRef value);

id JSObjectToNSObject(JSContextRef context, JSObjectRef object) {
    if (JSValueIsObjectOfClass(context, object, joc_))
        return reinterpret_cast<id>(JSObjectGetPrivate(object));
    JSValueRef exception(NULL);
    bool array(JSValueIsInstanceOfConstructor(context, object, Array_, &exception));
    CYThrow(context, exception);
    if (array)
        return [[[CY$JSArray alloc] initWithJSObject:object inContext:context] autorelease];
    return [[[CY$JSObject alloc] initWithJSObject:object inContext:context] autorelease];
}

CFStringRef CYCopyCFString(JSStringRef value) {
    return JSStringCopyCFString(kCFAllocatorDefault, value);
}

CFStringRef CYCopyCFString(JSContextRef context, JSValueRef value) {
    JSValueRef exception(NULL);
    JSStringRef string(JSValueToStringCopy(context, value, &exception));
    CYThrow(context, exception);
    CFStringRef object(CYCopyCFString(string));
    JSStringRelease(string);
    return object;
}

NSString *CYCastNSString(JSStringRef value) {
    return [reinterpret_cast<const NSString *>(CYCopyCFString(value)) autorelease];
}

CFTypeRef CYCopyCFType(JSContextRef context, JSValueRef value) {
    JSType type(JSValueGetType(context, value));

    switch (type) {
        case kJSTypeUndefined:
            return CFRetain([WebUndefined undefined]);
        break;

        case kJSTypeNull:
            return nil;
        break;

        case kJSTypeBoolean:
            return CFRetain(JSValueToBoolean(context, value) ? kCFBooleanTrue : kCFBooleanFalse);
        break;

        case kJSTypeNumber: {
            JSValueRef exception(NULL);
            double number(JSValueToNumber(context, value, &exception));
            CYThrow(context, exception);
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &number);
        } break;

        case kJSTypeString:
            return CYCopyCFString(context, value);
        break;

        case kJSTypeObject:
            return CFRetain((CFTypeRef) JSObjectToNSObject(context, (JSObjectRef) value));
        break;

        default:
            _assert(false);
        break;
    }
}

NSArray *CYCastNSArray(JSPropertyNameArrayRef names) {
    size_t size(JSPropertyNameArrayGetCount(names));
    NSMutableArray *array([NSMutableArray arrayWithCapacity:size]);
    for (size_t index(0); index != size; ++index)
        [array addObject:CYCastNSString(JSPropertyNameArrayGetNameAtIndex(names, index))];
    return array;
}

id CYCastNSObject(JSContextRef context, JSValueRef value) {
    const NSObject *object(reinterpret_cast<const NSObject *>(CYCopyCFType(context, value)));
    return object == nil ? nil : [object autorelease];
}

void CYThrow(JSContextRef context, JSValueRef value) {
    if (value == NULL)
        return;
    @throw CYCastNSObject(context, value);
}

JSValueRef CYCastJSValue(JSContextRef context, id value) {
    return value == nil ? JSValueMakeNull(context) : [value cy$JSValueInContext:context];
}

JSStringRef CYCopyJSString(id value) {
    return JSStringCreateWithCFString(reinterpret_cast<CFStringRef>([value description]));
}

JSStringRef CYCopyJSString(const char *value) {
    return JSStringCreateWithUTF8CString(value);
}

JSStringRef CYCopyJSString(JSStringRef value) {
    return JSStringRetain(value);
}

// XXX: this is not a safe handle
class CYString {
  private:
    JSStringRef string_;

  public:
    template <typename Type_>
    CYString(Type_ value) {
        string_ = CYCopyJSString(value);
    }

    ~CYString() {
        JSStringRelease(string_);
    }

    operator JSStringRef() const {
        return string_;
    }
};

void CYThrow(JSContextRef context, id error, JSValueRef *exception) {
    *exception = CYCastJSValue(context, error);
}

@implementation CY$JSObject

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context {
    if ((self = [super init]) != nil) {
        object_ = object;
        context_ = context;
    } return self;
}

- (NSUInteger) count {
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context_, object_));
    size_t size(JSPropertyNameArrayGetCount(names));
    JSPropertyNameArrayRelease(names);
    return size;
}

- (id) objectForKey:(id)key {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetProperty(context_, object_, CYString(key), &exception));
    CYThrow(context_, exception);
    return CYCastNSObject(context_, value);
}

- (NSEnumerator *) keyEnumerator {
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context_, object_));
    NSEnumerator *enumerator([CYCastNSArray(names) objectEnumerator]);
    JSPropertyNameArrayRelease(names);
    return enumerator;
}

- (void) setObject:(id)object forKey:(id)key {
    JSValueRef exception(NULL);
    JSObjectSetProperty(context_, object_, CYString(key), CYCastJSValue(context_, object), kJSPropertyAttributeNone, &exception);
    CYThrow(context_, exception);
}

- (void) removeObjectForKey:(id)key {
    JSValueRef exception(NULL);
    // XXX: this returns a bool
    JSObjectDeleteProperty(context_, object_, CYString(key), &exception);
    CYThrow(context_, exception);
}

@end

@implementation CY$JSArray

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context {
    if ((self = [super init]) != nil) {
        object_ = object;
        context_ = context;
    } return self;
}

- (NSUInteger) count {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetProperty(context_, object_, length_, &exception));
    CYThrow(context_, exception);
    double number(JSValueToNumber(context_, value, &exception));
    CYThrow(context_, exception);
    return number;
}

- (id) objectAtIndex:(NSUInteger)index {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetPropertyAtIndex(context_, object_, index, &exception));
    CYThrow(context_, exception);
    id object(CYCastNSObject(context_, value));
    return object == nil ? [NSNull null] : object;
}

@end

CFStringRef JSValueToJSONCopy(JSContextRef context, JSValueRef value) {
    id object(CYCastNSObject(context, value));
    return reinterpret_cast<CFStringRef>([(object == nil ? @"null" : [object cy$toJSON]) retain]);
}

static void OnData(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *value, void *info) {
    switch (type) {
        case kCFSocketDataCallBack:
            CFDataRef data(reinterpret_cast<CFDataRef>(value));
            Client *client(reinterpret_cast<Client *>(info));

            if (client->message_ == NULL)
                client->message_ = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE);

            if (!CFHTTPMessageAppendBytes(client->message_, CFDataGetBytePtr(data), CFDataGetLength(data)))
                CFLog(kCFLogLevelError, CFSTR("CFHTTPMessageAppendBytes()"));
            else if (CFHTTPMessageIsHeaderComplete(client->message_)) {
                CFURLRef url(CFHTTPMessageCopyRequestURL(client->message_));
                Boolean absolute;
                CFStringRef path(CFURLCopyStrictPath(url, &absolute));
                CFRelease(client->message_);

                CFStringRef code(CFURLCreateStringByReplacingPercentEscapes(kCFAllocatorDefault, path, CFSTR("")));
                CFRelease(path);

                JSStringRef script(JSStringCreateWithCFString(code));
                CFRelease(code);

                JSValueRef result(JSEvaluateScript(JSGetContext(), script, NULL, NULL, 0, NULL));
                JSStringRelease(script);

                CFHTTPMessageRef response(CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1));
                CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), CFSTR("application/json; charset=utf-8"));

                CFStringRef json(JSValueToJSONCopy(JSGetContext(), result));
                CFDataRef body(CFStringCreateExternalRepresentation(kCFAllocatorDefault, json, kCFStringEncodingUTF8, NULL));
                CFRelease(json);

                CFStringRef length(CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%u"), CFDataGetLength(body)));
                CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), length);
                CFRelease(length);

                CFHTTPMessageSetBody(response, body);
                CFRelease(body);

                CFDataRef serialized(CFHTTPMessageCopySerializedMessage(response));
                CFRelease(response);

                CFSocketSendData(socket, NULL, serialized, 0);
                CFRelease(serialized);

                CFRelease(url);
            }
        break;
    }
}

static void OnAccept(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *value, void *info) {
    switch (type) {
        case kCFSocketAcceptCallBack:
            Client *client(new Client());

            client->message_ = NULL;

            CFSocketContext context;
            context.version = 0;
            context.info = client;
            context.retain = NULL;
            context.release = NULL;
            context.copyDescription = NULL;

            client->socket_ = CFSocketCreateWithNative(kCFAllocatorDefault, *reinterpret_cast<const CFSocketNativeHandle *>(value), kCFSocketDataCallBack, &OnData, &context);

            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFSocketCreateRunLoopSource(kCFAllocatorDefault, client->socket_, 0), kCFRunLoopDefaultMode);
        break;
    }
}

static JSValueRef joc_getProperty(JSContextRef context, JSObjectRef object, JSStringRef propertyName, JSValueRef *exception) {
    return NULL;
}

typedef id jocData;

static void joc_finalize(JSObjectRef object) {
    id data(reinterpret_cast<jocData>(JSObjectGetPrivate(object)));
    [data release];
}

static JSValueRef obc_getProperty(JSContextRef context, JSObjectRef object, JSStringRef propertyName, JSValueRef *exception) {
    NSString *name([(NSString *) JSStringCopyCFString(kCFAllocatorDefault, propertyName) autorelease]);
    if (Class _class = NSClassFromString(name))
        return JSObjectMake(context, joc_, [_class retain]);
    return NULL;
}

void CYSetProperty(JSContextRef context, JSObjectRef object, const char *name, JSValueRef value) {
    JSValueRef exception(NULL);
    JSObjectSetProperty(context, object, CYString(name), value, kJSPropertyAttributeNone, &exception);
    CYThrow(context, exception);
}

struct ffiData {
    apr_pool_t *pool_;
    void (*function_)();
    const char *type_;
    sig::Signature signature_;
    ffi_cif cif_;
};

char *CYPoolCString(apr_pool_t *pool, JSStringRef value) {
    size_t size(JSStringGetMaximumUTF8CStringSize(value));
    char *string(reinterpret_cast<char *>(apr_palloc(pool, size)));
    JSStringGetUTF8CString(value, string, size);
    JSStringRelease(value);
    return string;
}

SEL CYCastSEL(JSContextRef context, JSValueRef value) {
    if (JSValueIsNull(context, value))
        return NULL;
    else if (JSValueIsObjectOfClass(context, value, sel_))
        return reinterpret_cast<SEL>(JSObjectGetPrivate((JSObjectRef) value));
    else {
        JSValueRef exception(NULL);
        JSStringRef string(JSValueToStringCopy(context, value, &exception));
        CYThrow(context, exception);
        size_t size(JSStringGetMaximumUTF8CStringSize(string));
        char utf8[size];
        JSStringGetUTF8CString(string, utf8, size);
        JSStringRelease(string);
        return sel_registerName(utf8);
    }
}

void CYToFFI(apr_pool_t *pool, JSContextRef context, sig::Type *type, void *data, JSValueRef value) {
    switch (type->primitive) {
        case sig::boolean_P:
            *reinterpret_cast<bool *>(data) = JSValueToBoolean(context, value);
        break;

#define CYToFFI_(primitive, native) \
        case sig::primitive ## _P: { \
            JSValueRef exception(NULL); \
            double number(JSValueToNumber(context, value, &exception)); \
            CYThrow(context, exception); \
            *reinterpret_cast<native *>(data) = number; \
        } break;

        CYToFFI_(uchar, unsigned char)
        CYToFFI_(char, char)
        CYToFFI_(ushort, unsigned short)
        CYToFFI_(short, short)
        CYToFFI_(ulong, unsigned long)
        CYToFFI_(long, long)
        CYToFFI_(uint, unsigned int)
        CYToFFI_(int, int)
        CYToFFI_(ulonglong, unsigned long long)
        CYToFFI_(longlong, long long)
        CYToFFI_(float, float)
        CYToFFI_(double, double)

        case sig::object_P:
        case sig::typename_P:
            *reinterpret_cast<id *>(data) = CYCastNSObject(context, value);
        break;

        case sig::selector_P:
            *reinterpret_cast<SEL *>(data) = CYCastSEL(context, value);
        break;

        case sig::pointer_P: {
            void *&pointer(*reinterpret_cast<void **>(data));
            if (JSValueIsNull(context, value))
                pointer = NULL;
            else if (JSValueIsObjectOfClass(context, value, ptr_))
                pointer = JSObjectGetPrivate((JSObjectRef) value);
            else {
                JSValueRef exception(NULL);
                double number(JSValueToNumber(context, value, &exception));
                CYThrow(context, exception);
                pointer = reinterpret_cast<void *>(static_cast<uintptr_t>(number));
            }
        } break;

        case sig::string_P: {
            JSValueRef exception(NULL);
            JSStringRef string(JSValueToStringCopy(context, value, &exception));
            CYThrow(context, exception);
            size_t size(JSStringGetMaximumUTF8CStringSize(string));
            char *utf8(reinterpret_cast<char *>(apr_palloc(pool, size)));
            JSStringGetUTF8CString(string, utf8, size);
            JSStringRelease(string);
            *reinterpret_cast<char **>(data) = utf8;
        } break;

        case sig::struct_P:
            goto fail;

        case sig::void_P:
        break;

        default: fail:
            NSLog(@"CYToFFI(%c)\n", type->primitive);
            _assert(false);
    }
}

JSValueRef CYFromFFI(apr_pool_t *pool, JSContextRef context, sig::Type *type, void *data) {
    JSValueRef value;

    switch (type->primitive) {
        case sig::boolean_P:
            value = JSValueMakeBoolean(context, *reinterpret_cast<bool *>(data));
        break;

#define CYFromFFI_(primitive, native) \
        case sig::primitive ## _P: \
            value = JSValueMakeNumber(context, *reinterpret_cast<native *>(data)); \
        break;

        CYFromFFI_(uchar, unsigned char)
        CYFromFFI_(char, char)
        CYFromFFI_(ushort, unsigned short)
        CYFromFFI_(short, short)
        CYFromFFI_(ulong, unsigned long)
        CYFromFFI_(long, long)
        CYFromFFI_(uint, unsigned int)
        CYFromFFI_(int, int)
        CYFromFFI_(ulonglong, unsigned long long)
        CYFromFFI_(longlong, long long)
        CYFromFFI_(float, float)
        CYFromFFI_(double, double)

        case sig::object_P:
        case sig::typename_P: {
            value = CYCastJSValue(context, *reinterpret_cast<id *>(data));
        } break;

        case sig::selector_P: {
            SEL sel(*reinterpret_cast<SEL *>(data));
            value = sel == NULL ? JSValueMakeNull(context) : JSObjectMake(context, sel_, sel);
        } break;

        case sig::pointer_P: {
            void *pointer(*reinterpret_cast<void **>(data));
            value = pointer == NULL ? JSValueMakeNull(context) : JSObjectMake(context, ptr_, pointer);
        } break;

        case sig::string_P: {
            char *utf8(*reinterpret_cast<char **>(data));
            value = utf8 == NULL ? JSValueMakeNull(context) : JSValueMakeString(context, CYString(utf8));
        } break;

        case sig::struct_P:
            goto fail;

        case sig::void_P:
            value = NULL;
        break;

        default: fail:
            NSLog(@"CYFromFFI(%c)\n", type->primitive);
            _assert(false);
    }

    return value;
}

class CYPool {
  private:
    apr_pool_t *pool_;

  public:
    CYPool() {
        apr_pool_create(&pool_, NULL);
    }

    ~CYPool() {
        apr_pool_destroy(pool_);
    }

    operator apr_pool_t *() const {
        return pool_;
    }
};

static JSValueRef CYCallFunction(JSContextRef context, size_t count, const JSValueRef *arguments, JSValueRef *exception, sig::Signature *signature, ffi_cif *cif, void (*function)()) {
    @try {
        if (count != signature->count - 1)
            [NSException raise:NSInvalidArgumentException format:@"incorrect number of arguments to ffi function"];

        CYPool pool;
        void *values[count];

        for (unsigned index(0); index != count; ++index) {
            sig::Element *element(&signature->elements[index + 1]);
            values[index] = apr_palloc(pool, cif->arg_types[index]->size);
            CYToFFI(pool, context, element->type, values[index], arguments[index]);
        }

        uint8_t value[cif->rtype->size];
        ffi_call(cif, function, value, values);

        return CYFromFFI(pool, context, signature->elements[0].type, value);
    } @catch (id error) {
        CYThrow(context, error, exception);
        return NULL;
    }
}

static JSValueRef $objc_msgSend(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { _pooled
    const char *type;

    @try {
        if (count < 2)
            [NSException raise:NSInvalidArgumentException format:@"too few arguments to objc_msgSend"];

        id self(CYCastNSObject(context, arguments[0]));
        if (self == nil)
            return JSValueMakeNull(context);

        SEL _cmd(CYCastSEL(context, arguments[1]));
        NSMethodSignature *method([self methodSignatureForSelector:_cmd]);
        if (method == nil)
            [NSException raise:NSInvalidArgumentException format:@"unrecognized selector %s sent to object %p", sel_getName(_cmd), self];

        type = [[method _typeString] UTF8String];
    } @catch (id error) {
        CYThrow(context, error, exception);
        return NULL;
    }

    CYPool pool;

    sig::Signature signature;
    sig::Parse(pool, &signature, type);

    void (*function)() = reinterpret_cast<void (*)()>(&objc_msgSend);

    ffi_cif cif;
    sig::sig_ffi_cif(pool, &sig::sig_objc_ffi_type, &signature, &cif);

    return CYCallFunction(context, count, arguments, exception, &signature, &cif, function);
}

static JSValueRef ffi_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    ffiData *data(reinterpret_cast<ffiData *>(JSObjectGetPrivate(object)));
    return CYCallFunction(context, count, arguments, exception, &data->signature_, &data->cif_, data->function_);
}

static void ffi_finalize(JSObjectRef object) {
    ffiData *data(reinterpret_cast<ffiData *>(JSObjectGetPrivate(object)));
    apr_pool_destroy(data->pool_);
}

void CYSetFunction(JSContextRef context, JSObjectRef object, const char *name, void (*function)(), const char *type) {
    apr_pool_t *pool;
    apr_pool_create(&pool, NULL);

    ffiData *data(reinterpret_cast<ffiData *>(apr_palloc(pool, sizeof(ffiData))));

    data->pool_ = pool;
    data->function_ = function;
    data->type_ = apr_pstrdup(pool, type);

    sig::Parse(pool, &data->signature_, type);
    sig::sig_ffi_cif(pool, &sig::sig_objc_ffi_type, &data->signature_, &data->cif_);

    JSObjectRef value(JSObjectMake(context, ffi_, data));
    CYSetProperty(context, object, name, value);
}

MSInitialize { _pooled
    apr_initialize();

    NSCFBoolean_ = objc_getClass("NSCFBoolean");

    pid_t pid(getpid());

    struct sockaddr_in address;
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(10000 + pid);

    CFDataRef data(CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&address), sizeof(address)));

    CFSocketSignature signature;
    signature.protocolFamily = AF_INET;
    signature.socketType = SOCK_STREAM;
    signature.protocol = IPPROTO_TCP;
    signature.address = data;

    CFSocketRef socket(CFSocketCreateWithSocketSignature(kCFAllocatorDefault, &signature, kCFSocketAcceptCallBack, &OnAccept, NULL));
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0), kCFRunLoopDefaultMode);

    JSClassDefinition definition;

    definition = kJSClassDefinitionEmpty;
    definition.getProperty = &obc_getProperty;
    JSClassRef obc(JSClassCreate(&definition));

    definition = kJSClassDefinitionEmpty;
    definition.className = "ffi";
    definition.callAsFunction = &ffi_callAsFunction;
    definition.finalize = &ffi_finalize;
    ffi_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "ptr";
    ptr_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "sel";
    sel_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "joc";
    definition.getProperty = &joc_getProperty;
    definition.finalize = &joc_finalize;
    joc_ = JSClassCreate(&definition);

    JSContextRef context(JSGlobalContextCreate(obc));
    Context_ = context;

    JSObjectRef global(JSContextGetGlobalObject(context));

#define CYSetFunction_(name, type) \
    CYSetFunction(context, global, #name, reinterpret_cast<void (*)()>(&name), type)

    CYSetFunction_(class_createInstance, "@#L");
    CYSetFunction_(class_getInstanceSize, "L#");
    CYSetFunction_(class_getIvarLayout, "*#");
    CYSetFunction_(class_getName, "*#");
    CYSetFunction_(class_getSuperclass, "##");
    CYSetFunction_(class_getVersion, "i#");
    CYSetFunction_(class_isMetaClass, "B#");
    CYSetFunction_(class_respondsToSelector, "B#:");
    CYSetFunction_(class_setSuperclass, "###");
    CYSetFunction_(class_setVersion, "v#i");
    CYSetFunction_(objc_allocateClassPair, "##*L");
    CYSetFunction_(objc_getClass, "#*");
    CYSetFunction_(objc_getFutureClass, "#*");
    CYSetFunction_(objc_getMetaClass, "@*");
    CYSetFunction_(objc_getRequiredClass, "@*");
    CYSetFunction_(objc_lookUpClass, "@*");
    CYSetFunction_(objc_registerClassPair, "v#");
    CYSetFunction_(objc_setFutureClass, "v#*");
    CYSetFunction_(object_copy, "@@L");
    CYSetFunction_(object_dispose, "@@");
    CYSetFunction_(object_getClass, "#@");
    CYSetFunction_(object_getClassName, "*@");
    CYSetFunction_(object_setClass, "#@#");
    CYSetFunction_(sel_getName, "*:");
    CYSetFunction_(sel_getUid, ":*");
    CYSetFunction_(sel_isEqual, "B::");
    CYSetFunction_(sel_registerName, ":*");

    CYSetProperty(context, global, "objc_msgSend", JSObjectMakeFunctionWithCallback(context, CYString("objc_msgSend"), &$objc_msgSend));

    CYSetProperty(context, global, "YES", JSValueMakeBoolean(context, true));
    CYSetProperty(context, global, "NO", JSValueMakeBoolean(context, false));
    CYSetProperty(context, global, "nil", JSValueMakeNull(context));

    name_ = JSStringCreateWithUTF8CString("name");
    message_ = JSStringCreateWithUTF8CString("message");
    length_ = JSStringCreateWithUTF8CString("length");

    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetProperty(JSGetContext(), global, CYString("Array"), &exception));
    CYThrow(context, exception);
    Array_ = JSValueToObject(JSGetContext(), value, &exception);
    CYThrow(context, exception);
}