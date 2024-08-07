#pragma once

#include "v8.h"
#include "v8/Context.h"
#include "v8/Isolate.h"
#include "v8/Local.h"
#include "v8/MaybeLocal.h"
#include "v8/Value.h"
#include "v8/Signature.h"
#include "v8/Template.h"

namespace v8 {

class Function;

struct ImplicitArgs {
    // v8-function-callback.h:168
    void* holder;
    Isolate* isolate;
    Context* context;
    // overwritten by the callback
    TaggedPointer return_value;
    // holds the value passed for data in FunctionTemplate::New
    TaggedPointer target;
    void* new_target;
};

// T = return value
template<typename T>
class FunctionCallbackInfo {
    // V8 treats this as an array of pointers
    ImplicitArgs* implicit_args;
    // index -1 is this
    TaggedPointer* values;
    size_t length;

public:
    FunctionCallbackInfo(ImplicitArgs* implicit_args_, TaggedPointer* values_, size_t length_)
        : implicit_args(implicit_args_)
        , values(values_)
        , length(length_)
    {
    }
};

using FunctionCallback = void (*)(const FunctionCallbackInfo<Value>&);

enum class ConstructorBehavior {
    kThrow,
    kAllow,
};

enum class SideEffectType {
    kHasSideEffect,
    kHasNoSideEffect,
    kHasSideEffectToReceiver,
};

class CFunction {
private:
    const void* address;
    const void* type_info;
};

class FunctionTemplate : public Template, public JSC::InternalFunction {
public:
    using Base = JSC::InternalFunction;

    BUN_EXPORT static Local<FunctionTemplate> New(
        Isolate* isolate,
        FunctionCallback callback = nullptr,
        Local<Value> data = Local<Value>(),
        Local<Signature> signature = Local<Signature>(),
        int length = 0,
        ConstructorBehavior behavior = ConstructorBehavior::kAllow,
        SideEffectType side_effect_type = SideEffectType::kHasSideEffect,
        const CFunction* c_function = nullptr,
        uint16_t instance_type = 0,
        uint16_t allowed_receiver_instance_type_range_start = 0,
        uint16_t allowed_receiver_instance_type_range_end = 0);

    BUN_EXPORT MaybeLocal<Function> GetFunction(Local<Context> context);

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject);

    template<typename, JSC::SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<FunctionTemplate, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForFunctionTemplate.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForFunctionTemplate = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForFunctionTemplate.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForFunctionTemplate = std::forward<decltype(space)>(space); });
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    friend class Function;

    FunctionCallback callback() const
    {
        return __internals.callback;
    }

private:
    class Internals {
    private:
        FunctionCallback callback;
        JSC::JSValue data;

        Internals(FunctionCallback callback_, JSC::JSValue data_)
            : callback(callback_)
            , data(data_)
        {
        }

        friend class FunctionTemplate;
    };

    // only use from functions called directly on FunctionTemplate
    Internals __internals;

    FunctionTemplate* localToObjectPointer()
    {
        ASSERT(this == static_cast<Data*>(this));
        return Data::localToObjectPointer<FunctionTemplate>();
    }

    const FunctionTemplate* localToObjectPointer() const
    {
        ASSERT(this == static_cast<const Data*>(this));
        return Data::localToObjectPointer<FunctionTemplate>();
    }

    // only use from functions called on Local<FunctionTemplate>
    Internals& internals()
    {
        return localToObjectPointer()->__internals;
    }

    static JSC::EncodedJSValue JSC_HOST_CALL_ATTRIBUTES functionCall(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame);

    FunctionTemplate(JSC::VM& vm, JSC::Structure* structure, FunctionCallback callback, JSC::JSValue data)
        : __internals(callback, data)
        , Base(vm, structure, functionCall, JSC::callHostFunctionAsConstructor)
    {
    }

    // some kind of static trampoline
};

}
