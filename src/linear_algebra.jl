function nterms(t)
    if istree(t)
        return reduce(+, map(nterms, arguments(t)), init=0)
    else
        return 1
    end
end

# Soft pivoted
# Note: we call this function with a matrix of Union{SymbolicUtils.Symbolic, Any}
function sym_lu(A; check=true)
    SINGULAR = typemax(Int)
    m, n = size(A)
    F = map(x->x isa Num ? x : Num(x), A)
    minmn = min(m, n)
    p = Vector{LinearAlgebra.BlasInt}(undef, minmn)
    info = 0
    for k = 1:minmn
        kp = k
        amin = SINGULAR
        for i in k:m
            absi = _iszero(F[i, k]) ? SINGULAR : nterms(F[i,k])
            if absi < amin
                kp = i
                amin = absi
            end
        end

        p[k] = kp

        if amin == SINGULAR && !(amin isa Symbolic) && (amin isa Number) && iszero(info)
            info = k
        end

        # swap
        for j in 1:n
            F[k, j], F[kp, j] = F[kp, j], F[k, j]
        end

        for i in k+1:m
            F[i, k] = F[i, k] / F[k, k]
        end
        for j = k+1:n
            for i in k+1:m
                F[i, j] = F[i, j] - F[i, k] * F[k, j]
            end
        end
    end
    check && LinearAlgebra.checknonsingular(info, Val{true}())
    LU(F, p, convert(LinearAlgebra.BlasInt, info))
end

# Given a vector of equations and a
# list of independent variables,
# return the coefficient matrix `A` and a
# vector of constants (possibly symbolic) `b` such that
# A \ b will solve the equations for the vars
function A_b(eqs::AbstractArray, vars::AbstractArray, check)
    exprs = rhss(eqs) .- lhss(eqs)
    if check
        for ex in exprs
            @assert isaffine(ex, vars)
        end
    end
    A = jacobian(exprs, vars)
    b = A * vars - exprs
    A, b
end
function A_b(eq, var, check)
    ex = eq.rhs - eq.lhs
    check && @assert isaffine(ex, [var])
    a = expand_derivatives(Differential(var)(ex))
    b = a * var - ex
    a, b
end

"""
    solve_for(eqs::Vector, vars::Vector; simplify=true, check=true)

Solve the vector of equations `eqs` for a set of variables `vars`.

Assumes `length(eqs) == length(vars)`

Currently only works if all equations are linear. `check` if the expr is linear
w.r.t `vars`.
"""
function solve_for(eqs, vars; simplify=true, check=true)
    A, b = A_b(eqs, vars, check)
    #TODO: we need to make sure that `solve_for(eqs, vars)` contains no `vars`
    sol = _solve(A, b, simplify)
    sol isa AbstractArray ? map(Num, sol) : Num(sol)
end

function _solve(A::AbstractMatrix, b::AbstractArray, do_simplify)
    A = SymbolicUtils.simplify.(Num.(A), expand=true)
    b = SymbolicUtils.simplify.(Num.(b), expand=true)
    sol = value.(sym_lu(A) \ b)
    do_simplify ? SymbolicUtils.simplify.(sol, expand=true) : sol
end

function _solve(a, b, do_simplify)
    sol = value(b/a)
    do_simplify ? SymbolicUtils.simplify(sol, expand=true) : sol
end

# ldiv below

LinearAlgebra.ldiv!(A::UpperTriangular{<:Union{Symbolic,Num}}, b::AbstractVector{<:Union{Symbolic,Num}}, x::AbstractVector{<:Union{Symbolic,Num}} = b) = symsub!(A, b, x)
function symsub!(A::UpperTriangular, b::AbstractVector, x::AbstractVector = b)
    LinearAlgebra.require_one_based_indexing(A, b, x)
    n = size(A, 2)
    if !(n == length(b) == length(x))
        throw(DimensionMismatch("second dimension of left hand side A, $n, length of output x, $(length(x)), and length of right hand side b, $(length(b)), must be equal"))
    end
    @inbounds for j in n:-1:1
        _iszero(A.data[j,j]) && throw(SingularException(j))
        xj = x[j] = b[j] / A.data[j,j]
        for i in j-1:-1:1
            sub = _isone(xj) ? A.data[i,j] : A.data[i,j] * xj
            if !_iszero(sub)
                b[i] -= sub
            end
        end
    end
    x
end

LinearAlgebra.ldiv!(A::UnitLowerTriangular{<:Union{Symbolic,Num}}, b::AbstractVector{<:Union{Symbolic,Num}}, x::AbstractVector{<:Union{Symbolic,Num}} = b) = symsub!(A, b, x)
function symsub!(A::UnitLowerTriangular, b::AbstractVector, x::AbstractVector = b)
    LinearAlgebra.require_one_based_indexing(A, b, x)
    n = size(A, 2)
    if !(n == length(b) == length(x))
        throw(DimensionMismatch("second dimension of left hand side A, $n, length of output x, $(length(x)), and length of right hand side b, $(length(b)), must be equal"))
    end
    @inbounds for j in 1:n
        xj = x[j] = b[j]
        for i in j+1:n
            sub = _isone(xj) ? A.data[i,j] : A.data[i,j] * xj
            if !_iszero(sub)
                b[i] -= sub
            end
        end
    end
    x
end

function LinearAlgebra.det(A::AbstractMatrix{<:Num}; laplace=true)
    if laplace
        n = LinearAlgebra.checksquare(A)
        if n == 1
            return A[1, 1]
        elseif n == 2
            return A[1, 1] * A[2, 2] - A[1, 2] * A[2, 1]
        else
            temp = 0
            # Laplace expansion along the first column
            M′ = A[:, 2:end]
            for i in axes(A, 1)
                M = M′[(1:n) .!= i, :]
                d′ = A[i, 1] * det(M)
                if iseven(i)
                    temp = iszero(temp) ? d′ : temp - d′
                else
                    temp = iszero(temp) ? d′ : temp + d′
                end
            end
        end
        return temp
    else
        if istriu(A) || istril(A)
            return det(UpperTriangular(A))
        end
        return det(lu(A; check = false))
    end
end

function LinearAlgebra.norm(x::AbstractArray{Num}, p::Real=2)
    p = value(p)
    issym = p isa Symbolic
    if !issym && p == 2
        sqrt(sum(x->abs2(x), x))
    elseif !issym && isone(p)
        sum(abs, x)
    elseif !issym && isinf(p)
        mapreduce(abs, max, x)
    else
        sum(x->abs(x)^p, x)^inv(p)
    end
end

"""
    (a, b, islinear) = linear_expansion(t, x)

When `islinear`, return `a` and `b` such that `a * x + b == t`.
"""
linear_expansion(t::Num, x) = linear_expansion(value(t), value(x))
_linear_expansion(t, x) = isequal(t, x) ? (1, 0, true) : (0, t, true) # trival case
function linear_expansion(t, x)
    t isa Symbolic || return (0, t, true)
    x = value(x)
    istree(t) || return _linear_expansion(t, x)

    op, args = operation(t), arguments(t)
    op isa Differential && _linear_expansion(t, x)

    if op === (+)
        a₁ = b₁ = 0
        islinear = true
        # (a₁ x + b₁) + (a₂ x + b₂) = (a₁ + a₂) x + (b₁ + b₂)
        for (i, arg) in enumerate(args)
            a₂, b₂, islinear = linear_expansion(arg, x)
            islinear || return (a₁, b₁, false)
            a₁ += a₂
            b₁ += b₂
        end
        return (a₁, b₁, true)
    elseif op === (-)
        @assert length(args) == 1
        a, b, islinear = linear_expansion(args[1], x)
        return (-a, -b, islinear)
    elseif op === (*)
        # (a₁ x + b₁) (a₂ x + b₂) = a₁ a₂ x² + (a₁ b₂ + a₂ b₁) x + b₁ b₂
        a₁ = 0
        b₁ = 1
        islinear = true
        for (i, arg) in enumerate(args)
            a₂, b₂, islinear = linear_expansion(arg, x)
            (islinear && _iszero(a₁ * a₂)) || return (a₁, b₁, false)
            a₁ = a₁ * b₂ + a₂ * b₁
            b₁ *= b₂
        end
        return (a₁, b₁, true)
    elseif op === (^)
        # (a₁ x + b₁)^(a₂ x + b₂) is linear => a₂ = 0 && (b₂ == 1 || a₁ == 0)
        a₂, b₂, islinear = linear_expansion(args[2], x)
        (islinear && _iszero(a₂)) || return (0, 0, false)
        a₁, b₁, islinear = linear_expansion(args[1], x)
        _isone(b₂) && (a₁, b₁, islinear)
        (islinear && _iszero(a₁)) || return (0, 0, false)
        return (0, b₁^b₂, islinear)
    else
        for (i, arg) in enumerate(args)
            a, b, islinear = linear_expansion(arg, x)
            (_iszero(b) && islinear) || return (0, 0, false)
        end
        return (0, t, true)
    end
end
