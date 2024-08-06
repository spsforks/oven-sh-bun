#include "node.h"

#include "JavaScriptCore/ObjectConstructor.h"
#include "CommonJSModuleRecord.h"

using v8::Context;
using v8::HandleScope;
using v8::Isolate;
using v8::Local;
using v8::Object;
using v8::Value;

using JSC::JSObject;
using JSC::jsUndefined;
using JSC::JSValue;

namespace node {

void AddEnvironmentCleanupHook(v8::Isolate* isolate,
    void (*fun)(void* arg),
    void* arg)
{
    // TODO
}

void RemoveEnvironmentCleanupHook(v8::Isolate* isolate,
    void (*fun)(void* arg),
    void* arg)
{
    // TODO
}

void node_module_register(void* opaque_mod)
{
    auto* globalObject = Bun__getDefaultGlobalObject();
    auto& vm = globalObject->vm();
    auto* mod = reinterpret_cast<struct node_module*>(opaque_mod);
    auto keyStr = WTF::String::fromUTF8(mod->nm_modname);
    globalObject->napiModuleRegisterCallCount++;
    JSValue pendingNapiModule = globalObject->pendingNapiModule;
    JSObject* object = (pendingNapiModule && pendingNapiModule.isObject()) ? pendingNapiModule.getObject()
                                                                           : nullptr;

    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::Strong<JSC::JSObject> strongExportsObject;

    if (!object) {
        auto* exportsObject = JSC::constructEmptyObject(globalObject);
        RETURN_IF_EXCEPTION(scope, void());

        object = Bun::JSCommonJSModule::create(globalObject, keyStr, exportsObject, false, jsUndefined());
        strongExportsObject = { vm, exportsObject };
    } else {
        globalObject->pendingNapiModule = JSC::JSValue();
        JSValue exportsObject = object->getIfPropertyExists(globalObject, WebCore::builtinNames(vm).exportsPublicName());
        RETURN_IF_EXCEPTION(scope, void());

        if (exportsObject && exportsObject.isObject()) {
            strongExportsObject = { vm, exportsObject.getObject() };
        } else {
            auto* exportsObject = JSC::constructEmptyObject(globalObject);
            JSC::PutPropertySlot slot(object, false);
            object->put(object, globalObject, WebCore::builtinNames(vm).exportsPublicName(), exportsObject, slot);
            strongExportsObject = { vm, exportsObject };
        }
    }

    JSC::Strong<JSC::JSObject> strongObject = { vm, object };

    HandleScope hs(reinterpret_cast<Isolate*>(globalObject));

    // TODO(@190n) check if version is correct?

    // exports, module
    Local<Object> exports = hs.createLocal<Object>(*strongExportsObject);
    Local<Value> module = hs.createLocal<Value>(object);
    Local<Context> context = hs.createLocal<Context>(globalObject);
    if (mod->nm_context_register_func) {
        mod->nm_context_register_func(exports, module, context, mod->nm_priv);
    } else if (mod->nm_register_func) {
        mod->nm_register_func(exports, module, mod->nm_priv);
    } else {
        BUN_PANIC("v8 module has no entrypoint");
    }

    RETURN_IF_EXCEPTION(scope, void());

    globalObject->pendingNapiModule = *strongExportsObject;
}

}
