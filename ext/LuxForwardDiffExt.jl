module LuxForwardDiffExt

using ADTypes: AutoForwardDiff
using ChainRulesCore: ChainRulesCore
using Lux: Lux
using FastClosures: @closure
using ForwardDiff: ForwardDiff
using Functors: fmap

const CRC = ChainRulesCore

@inline Lux._is_extension_loaded(::Val{:ForwardDiff}) = true

# Low-Level functions
@inline function Lux.__partials(::Type{Tag}, x, i) where {Tag}
    x isa ForwardDiff.Dual && return ForwardDiff.partials(Tag, x, i)
    x isa AbstractArray && return ForwardDiff.partials.(Tag, x, i)
    map_fn = @closure(xᵢ->Lux.__partials(Tag, xᵢ, i))
    x isa Tuple && return map(map_fn, x)
    x isa NamedTuple && return NamedTuple{keys(x)}(map(map_fn, values(x)))
    x isa CRC.AbstractTangent && return Lux.__partials(Tag, CRC.backing(x), i)
    x === nothing && return nothing
    return fmap(map_fn, x)
end

@inline function Lux.__dualify(::Type{Tag}, ::Type{T}, x, u) where {Tag, T}
    if x isa AbstractArray
        return ForwardDiff.Dual{
            Tag, T, 1}.(x, ForwardDiff.Partials{1, T}.(tuple.(reshape(u, size(x)))))
    end
    x isa Tuple && return map((xᵢ, uᵢ) -> Lux.__dualify(Tag, T, xᵢ, uᵢ), x, u)
    x isa NamedTuple &&
        return NamedTuple{keys(x)}(map((xᵢ, uᵢ) -> Lux.__dualify(Tag, T, xᵢ, uᵢ), x, u))
    return fmap((xᵢ, uᵢ) -> Lux.__dualify(Tag, T, xᵢ, uᵢ), x, u)
end

# This is not a general jvp code, but rather meant to be efficient for nested AD calls
function Lux.__forwarddiff_jvp(f::F, x, Δx, y) where {F}
    T = promote_type(Lux.__recursive_eltype(x), Lux.__recursive_eltype(Δx))
    Tag = typeof(ForwardDiff.Tag(f, T))
    res1_dual, res2_dual = f(Lux.__dualify(Tag, T, x, Δx), y)
    return (Lux.__partials(Tag, res1_dual, 1), Lux.__partials(Tag, res2_dual, 1))
end

# jvp
function Lux.__jacobian_vector_product_impl(f::F, ::AutoForwardDiff, x, u) where {F}
    T = promote_type(Lux.__recursive_eltype(x), Lux.__recursive_eltype(u))
    Tag = typeof(ForwardDiff.Tag(f, T))
    y_dual = f(Lux.__dualify(Tag, T, x, u))
    return Lux.__partials(Tag, y_dual, 1)
end

function __jacobian_vector_product_ad_impl(f::F, x, u, y) where {F}
    return Lux.__jacobian_vector_product_impl(Base.Fix2(f, y), AutoForwardDiff(), x, u)
end

for fType in Lux.AD_CONVERTIBLE_FUNCTIONS
    @eval @inline function Lux.__jacobian_vector_product_impl(
            f::$(fType), ::AutoForwardDiff, x, u)
        f_internal, y = Lux.__rewrite_ad_call(f)
        return __jacobian_vector_product_ad_impl(f_internal, x, u, y)
    end
end

function CRC.rrule(cfg::CRC.RuleConfig{>:CRC.HasReverseMode},
        ::typeof(__jacobian_vector_product_ad_impl), f::F, x, u, y) where {F}
    res = __jacobian_vector_product_ad_impl(f, x, u, y)

    pullback_fn = (f_internal, x, args...) -> begin
        res, ∂f = CRC.rrule_via_ad(cfg, f_internal, x, args...)
        ∂f_internal(Δ) = ∂f(Δ)[2:end]
        return res, ∂f_internal
    end

    ∇internal_nested_pushforward_capture = Δ -> begin
        _, pb_f = CRC.rrule_via_ad(
            cfg, Lux.__internal_ad_pullback_call, pullback_fn, f, x, y, Δ)
        _, _, _, ∂x, ∂y, _ = pb_f(u)
        return CRC.NoTangent(), CRC.NoTangent(), ∂x, CRC.NoTangent(), ∂y
    end

    return res, ∇internal_nested_pushforward_capture
end

# Capture ForwardDiff.jacobian call and replace it with forward over reverse mode AD
for cfg in (:JacobianConfig, :GradientConfig)
    @eval @inline function __updated_forwarddiff_config(
            ::ForwardDiff.$(cfg){T, V, N, D}, f::F,
            x::AbstractArray{V}) where {T, V, N, D, F}
        return ForwardDiff.$(cfg)(f, x, ForwardDiff.Chunk{N}())
    end
end

for fType in Lux.AD_CONVERTIBLE_FUNCTIONS, type in (:Gradient, :Jacobian)
    cfgname = Symbol(type, :Config)
    fname = Symbol(lowercase(string(type)))
    internal_fname = Symbol(:__internal_forwarddiff_, fname)

    @eval begin
        @inline function ForwardDiff.$(fname)(f::$fType, x::AbstractArray,
                cfg::ForwardDiff.$(cfgname)=ForwardDiff.$(cfgname)(f, x),
                chk::Val=Val(true))
            f_internal, y = Lux.__rewrite_ad_call(f)
            return $(internal_fname)(f_internal, cfg, chk, x, y)
        end
    end
end

for type in (:Gradient, :Jacobian)
    cfgname = Symbol(type, :Config)
    fname = Symbol(lowercase(string(type)))
    internal_fname = Symbol(:__internal_forwarddiff_, fname)

    @eval @inline function $(internal_fname)(
            f::F, cfg::ForwardDiff.$(cfgname), chk::Val, x::AbstractArray, y) where {F}
        __f = Base.Fix2(f, y)
        return ForwardDiff.$(fname)(__f, x, __updated_forwarddiff_config(cfg, __f, x), chk)
    end

    rrule_call = if type == :Gradient
        :((res, pb_f) = CRC.rrule_via_ad(
            cfg, Lux.__internal_ad_gradient_call, grad_fn, f, x, y))
    else
        :((res, pb_f) = CRC.rrule_via_ad(
            cfg, Lux.__internal_ad_jacobian_call, ForwardDiff.$(fname), grad_fn, f, x, y))
    end
    ret_expr = type == :Gradient ? :(only(res)) : :(res)
    @eval begin
        function CRC.rrule(cfg::CRC.RuleConfig{>:CRC.HasReverseMode},
                ::typeof($(internal_fname)), f::F, jc_cfg::ForwardDiff.$(cfgname),
                chk::Val, x::AbstractArray, y) where {F}
            grad_fn = (f_internal, x, args...) -> begin
                res, ∂f = CRC.rrule_via_ad(cfg, f_internal, x, args...)
                return ∂f(one(res))[2:end]
            end

            $(rrule_call)
            ∇internal_nested_ad_capture = Δ -> begin
                ∂x, ∂y = pb_f(tuple(Δ))[(end - 1):end]
                return (ntuple(Returns(CRC.NoTangent()), 4)..., ∂x, ∂y)
            end
            return $(ret_expr), ∇internal_nested_ad_capture
        end
    end
end

end
