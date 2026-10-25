#include <napi/native_api.h>
#include <dlfcn.h>
#include <string>

static void* library = nullptr;
static char* (*runCore)(const char*) = nullptr;
static char* (*startTun)(int, const char*) = nullptr;
static void (*stopTun)() = nullptr;
static void (*stopCore)() = nullptr;
static void (*freeError)(char*) = nullptr;
static char* (*takeOwners)() = nullptr;
static void (*resolveOwner)(unsigned int, int, const char*) = nullptr;

struct Work {
    napi_async_work work;
    napi_deferred deferred;
    std::string argument;
    std::string error;
    int fd = -1;
    int operation = 0;
};

static std::string Text(napi_env env, napi_value value) {
    size_t size = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &size);
    std::string text(size + 1, '\0');
    napi_get_value_string_utf8(env, value, text.data(), text.size(), &size);
    text.resize(size);
    return text;
}

static void Execute(napi_env, void* data) {
    auto* work = static_cast<Work*>(data);
    char* error = nullptr;
    if (work->operation == 0) error = runCore(work->argument.c_str());
    else if (work->operation == 1) error = startTun(work->fd, work->argument.c_str());
    else stopTun();
    if (error) { work->error = error; freeError(error); }
}

static void Complete(napi_env env, napi_status status, void* data) {
    auto* work = static_cast<Work*>(data);
    napi_value value;
    if (work->error.empty() && status == napi_ok) {
        napi_get_undefined(env, &value);
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message;
        napi_create_string_utf8(env, work->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &value);
        napi_reject_deferred(env, work->deferred, value);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

static napi_value Queue(napi_env env, napi_callback_info info, int operation) {
    if (!library) {
        library = dlopen("libflclash.so", RTLD_NOW | RTLD_LOCAL);
        if (!library) { napi_throw_error(env, nullptr, dlerror()); return nullptr; }
        runCore = reinterpret_cast<char*(*)(const char*)>(dlsym(library, "FlClashRun"));
        startTun = reinterpret_cast<char*(*)(int,const char*)>(dlsym(library, "FlClashStartTun"));
        stopTun = reinterpret_cast<void(*)()>(dlsym(library, "FlClashStopTun"));
        stopCore = reinterpret_cast<void(*)()>(dlsym(library, "FlClashStopCore"));
        freeError = reinterpret_cast<void(*)(char*)>(dlsym(library, "FlClashFree"));
        takeOwners = reinterpret_cast<char*(*)()>(dlsym(library, "FlClashTakeOwners"));
        resolveOwner = reinterpret_cast<void(*)(unsigned int,int,const char*)>(dlsym(library, "FlClashResolveOwner"));
    }
    if (!runCore || !startTun || !stopTun || !stopCore || !freeError) {
        napi_throw_error(env, nullptr, "Missing HarmonyOS Core entrypoint");
        return nullptr;
    }
    size_t count = 2;
    napi_value arguments[2];
    napi_get_cb_info(env, info, &count, arguments, nullptr, nullptr);
    auto* work = new Work();
    work->operation = operation;
    if (operation == 0) work->argument = Text(env, arguments[0]);
    if (operation == 1) {
        napi_get_value_int32(env, arguments[0], &work->fd);
        work->argument = Text(env, arguments[1]);
    }
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "FlClash Core", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, Execute, Complete, work, &work->work);
    napi_queue_async_work(env, work->work);
    return promise;
}

static napi_value Run(napi_env env, napi_callback_info info) { return Queue(env, info, 0); }
static napi_value Start(napi_env env, napi_callback_info info) { return Queue(env, info, 1); }
static napi_value Stop(napi_env env, napi_callback_info info) { return Queue(env, info, 2); }
static napi_value Close(napi_env env, napi_callback_info) {
    if (stopCore) stopCore();
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

static napi_value TakeOwners(napi_env env, napi_callback_info) {
    char* data = takeOwners ? takeOwners() : nullptr;
    napi_value value;
    napi_create_string_utf8(env, data ? data : "[]", NAPI_AUTO_LENGTH, &value);
    if (data) freeError(data);
    return value;
}

static napi_value ResolveOwner(napi_env env, napi_callback_info info) {
    size_t count = 3;
    napi_value arguments[3];
    napi_get_cb_info(env, info, &count, arguments, nullptr, nullptr);
    unsigned int id = 0;
    int uid = -1;
    napi_get_value_uint32(env, arguments[0], &id);
    napi_get_value_int32(env, arguments[1], &uid);
    if (resolveOwner) resolveOwner(id, uid, Text(env, arguments[2]).c_str());
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"runCore", nullptr, Run, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startTun", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopTun", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCore", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeOwners", nullptr, TakeOwners, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resolveOwner", nullptr, ResolveOwner, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, 6, properties);
    return exports;
}

static napi_module module = {1, 0, nullptr, Init, "flclash_vpn", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterVpnModule() { napi_module_register(&module); }
