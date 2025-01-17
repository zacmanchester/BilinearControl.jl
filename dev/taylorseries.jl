using Symbolics
using LinearAlgebra
using SparseArrays
using Symbolics
using Symbolics.SymbolicUtils
using Symbolics: value, istree

getpow(num::Num) = getpow(Symbolics.value(num))
getpow(x::Real) = 0
getpow(::Union{<:SymbolicUtils.Term,SymbolicUtils.Sym}) = 1
getpow(sym::SymbolicUtils.Pow{<:Any,<:Any,<:Integer}) = getpow(sym.base) * sym.exp
getpow(sym::SymbolicUtils.Pow) = error("Expression has a non-integer power") 
getpow(sym::SymbolicUtils.Mul) = mapreduce(getpow, +, arguments(sym))
getpow(sym::SymbolicUtils.Add) = maximum(getpow, arguments(sym))

"""
    taylorexpansion(f::Function, nargs, order=:x)

Create a symbolic Taylor expansion of `f` to order `order`, where `f` has `nargs` arguments.
The resulting expression will contain `Symbolics` array variables of length `nargs`, with
names `name` and `name0` (e.g. `x` and `x0`). 
"""
function taylorexpansion(f::Function, nargs, order; name::Symbol=:x)
    # x, x0 = @variables $name[nargs] $name0[nargs]
    x0 = [Symbolics.variable(Symbol(string(name) * "0"), i) for i = 1:nargs]
    x = [Symbolics.variable(Symbol(string(name)), i) for i = 1:nargs]
    
    f0 = f(x0...)

    # Assign first term in the series
    e = f0
    prevterms = [f0]
    for k = 1:order
        newterms = Num[]
        for term in prevterms
            for i = 1:nargs
                ddx = Differential(x0[i])(term)
                push!(newterms, ddx)
                e += ddx/factorial(k) * (x[i] - x0[i])^k
            end
        end
        prevterms = copy(newterms)
    end
    return e
end

"""
    taylorexpand(f::Symbolics.Symbolic, vars, vars0, order)
"""
function taylorexpand(f::SymbolicUtils.Term, vars, vars0, order)
    # Check if the term is one of the variables (e.g. a dependent variable)
    for i = 1:length(vars)
        if hash(f) == hash(value(vars[i]))
            return f
        end
    end

    # Generate a symbolic expression representing the Taylor expansion of the called function
    op = operation(f)
    args = arguments(f)
    nargs = length(args)
    f_approx = expand_derivatives(taylorexpansion(op, nargs, order, name=:_x))
    # @variables _x[1:nargs] _x0[1:nargs]
    
    _x0 = [Symbolics.variable(Symbol("_x0"), i) for i = 1:nargs]
    _x = [Symbolics.variable(Symbol("_x"), i) for i = 1:nargs]

    # Taylor expand the arguments
    subs = Dict(value(vars[i])=>value(vars0[i]) for i = 1:length(vars))
    for i = 1:nargs
        # Taylor expand the argument
        arg_approx = taylorexpand(args[i], vars, vars0, order)

        # Substitute vars0 into original argument expression
        arg0 = substitute(args[i], subs)

        # Replace arguments to Taylor series function with argument expressions
        f_approx = substitute(f_approx, Dict(_x[i]=>arg_approx, _x0[i]=>arg0))
    end
    return f_approx
end

taylorexpand(num::Num, args...) = taylorexpand(value(num), args...) 
taylorexpand(x::Number, args...) = x
taylorexpand(sym::SymbolicUtils.Sym, args...) = sym

function taylorexpand(sym::SymbolicUtils.Add, args...)
    mapreduce(+, arguments(sym)) do arg
        taylorexpand(arg, args...)
    end
end

function taylorexpand(sym::SymbolicUtils.Mul, args...)
    mapreduce(*, arguments(sym)) do arg
        taylorexpand(arg, args...) 
    end
end

function taylorexpand(sym::SymbolicUtils.Pow{<:Real,<:Any,<:Real}, args...)
    taylorexpand(sym.base, args...)^sym.exp
end

function taylorexpand(sym::SymbolicUtils.Div, args...)
    newterm = SymbolicUtils.Term((x,y)->x/y, [sym.num, sym.den])
    taylorexpand(newterm, args...)
end

"""
    getconstant(e, vars)

Return a version of the sybolic expression `e` that is constant with respect 
to the variables in `vars`. The resulting expression can still have other variables 
inside of it, as long as they aren't any of the ones given in `vars`. For a summation 
of terms, the non-constant terms are dropped.
"""
getconstant(e::Real, vars) = e

function getconstant(e::SymbolicUtils.Symbolic, vars)
    termvars = Symbolics.get_variables(e)
    isconstant = !any(termvars) do tvar
        any(vars) do var
            hash(value(var)) === hash(value(tvar))
        end
    end
    if isconstant
        return e
    else
        return 0
    end
end

function getconstant(e::SymbolicUtils.Add, vars)
    mapreduce(+, arguments(e)) do arg
        getconstant(arg, vars)
    end
end

"""
    getdifferential(var::SymbolicUtils.Symbolic)

Get the differential for the variable `var`. For compound variables (i.e. multiplied 
variables, not powers of the same variable), the result is the composition of the individual
differentials. The effect of applying the resulting differential is the derivative with 
respect to the joint term.

If `D` is the output of `getdifferential`, then

    getdifferential(x*y)(x^2 + 2x*y) = 2
    getdifferential(x^2)(x^2 + 2x*y) = 1
    getdifferential(x*y^2)(x*(3y^2 + 4y) + y*x*(4 - 2y)) = 3 - 2 = 1

Note you will usually need to call `Symbolics.value` prior to calling this function.
"""
getdifferential(var::SymbolicUtils.Mul) = mapreduce(Differential, *, arguments(value(var)))
getdifferential(var::SymbolicUtils.Pow) = Differential(var)
getdifferential(var::SymbolicUtils.Sym) = Differential(var)
getdifferential(var::SymbolicUtils.Term) = Differential(var)

function hasvar(e::SymbolicUtils.Symbolic, var)
    vars = Symbolics.get_variables(e)
    h = hash(value(var))
    for evar in vars
        if hash(evar) == h 
            return true
        end
    end
    return false
end

"""
    getcoeffs(exprs, var, basevars)

Get the linear coefficients with respect to `var` for each symbolic expression in `exprs`.
Any symbolic variable not in `basevars` is considered a constant and will be included in
the expression for the coefficients.

If `iszero(var)` (e.g. `Num(0)`), the constant coefficients are extracted.
"""
function getcoeffs(exprs::Vector{Num}, var, basevars)
    rowvals = Int[]
    terms = Num[]
    for (i,e) in enumerate(exprs)
        # if !hasvar(value(e), value(var))
        #     continue
        # end
        # Expand the expression to get all terms as multiplications
        e_expanded = Symbolics.expand(e)

        # Take the derivative with respect to the current variable
        if !iszero(var)
            D = getdifferential(value(var))
            dvar = Symbolics.expand(expand_derivatives(D(e_expanded)))
        else
            dvar = e_expanded
        end

        # Extract out the constant part of the expression
        coeff = getconstant(value(dvar), basevars)

        # If it's not zero, add to results
        if hash(coeff) != hash(Num(0))
            push!(rowvals, i)
            push!(terms, coeff)
        end
    end
    return terms, rowvals 
end

function _buildsparsematrix(exprs, vars, basevars)
    n = length(exprs)  # number of rows
    m = length(vars)   # number of columns
    nzval = Num[]
    rowval = Int[]
    colptr = zeros(Int, m+1)
    colptr[1] = 1
    for i = 1:m
        coeffs, rvals = getcoeffs(exprs, vars[i], basevars)
        nterms = length(coeffs)
        colptr[i+1] = colptr[i] + nterms
        append!(nzval, coeffs)
        append!(rowval, rvals)
    end
    return SparseMatrixCSC(n, m, colptr, rowval, nzval)
end

function getAsym(ydot, y)
    basevars = filter(x->getpow(x)==1, y)
    _buildsparsematrix(ydot, y, basevars)
end

function getAsym(ydot, y, u)
    basevars = filter(x->getpow(x)==1, y)
    append!(basevars, u)  # must be constant wrt to both original state and control
    _buildsparsematrix(ydot, y, basevars)
end

function getBsym(ydot, y, u)
    basevars = filter(x->getpow(x)==1, y)
    append!(basevars, u)  # must be constant wrt to both original state and control
    _buildsparsematrix(ydot, u, basevars)
end

function getCsym(ydot, y, u)
    basevars = filter(x->getpow(x)==1, y)
    append!(basevars, u)  # must be constant wrt to both original state and control
    map(u) do uk
        # Differentiate the dynamics wrt the current control variable
        dydotdu = Differential(uk).(ydot)

        # Get the coefficients now that the current control has been differentiated out
        _buildsparsematrix(dydotdu, y, basevars)
    end
end

function getDsym(ydot, y, u)
    basevars = filter(x->getpow(x)==1, y)
    append!(basevars, u)  # must be constant wrt to both original state and control
    _buildsparsematrix(ydot, [Num(0)], basevars)
end

function buildstatevector(x, order)
    iters = ceil(Int, log2(order))
    y = copy(x)
    for i = 1:iters
        y_ = trilvec(y*y')
        y = unique([y; y_])
    end
    filter(x->getpow(x) <= order, y)
end


function trilvec(A::AbstractMatrix)
    n = minimum(size(A))
    numel = n * (n + 1) ÷ 2
    v = zeros(eltype(A), numel)
    cnt = 1
    for j = 1:size(A,2)
        for i = j:size(A,1)
            v[cnt] = A[i,j]
            cnt += 1
        end
    end
    return v
end

struct SymbolicBilinearDynamics
    n0::Int
    n::Int
    m::Int
    A::SparseMatrixCSC{Num,Int}
    B::SparseMatrixCSC{Num,Int}
    C::Vector{SparseMatrixCSC{Num,Int}}
    D::SparseMatrixCSC{Num,Int}
    dynamics::Function
    states::Vector{Num}
    controls::Vector{Num}
    states0::Vector{Num}
    constants::Vector{Num}
    expandedstates::Vector{Num}
end

function bilinearize_dynamics(dynamics::Function, states, controls, t, order; constants=Num[])
    @assert !istree(value(t)) "Independent variable must be independent!"
    Dt = Differential(t)
    n0 = length(states)
    m = length(controls)

    # Evaluate the continuous dynamics
    statederivative = dynamics(states, controls)

    # Get Taylor approximation of the dynamics
    states0 = [Symbolics.variable(Symbol("_x0"), i) for i = 1:n0]
    approx_dynamics = map(statederivative) do xdot
        Num(taylorexpand(xdot, states, states0, order))
    end

    # Form the expanded state vector
    y = buildstatevector(states, order)
    n = length(y)  # new state dimension

    # Form the expanded state derivative
    ydot = expand_derivatives.(Dt.(y)) 

    # Substitute in the approximate dynamics
    subs = Dict(Dt(value(states[i]))=>value(approx_dynamics[i]) for i = 1:n0)
    ydot_approx = map(ydot) do yi
        substitute(yi, subs)
    end

    # Build symbolic sparse matrices
    #   These store symbolic expressions for the nonzero elements
    #   Each is only a function of the linearization state or provided constants
    Asym = getAsym(ydot_approx, y, controls)
    Bsym = getBsym(ydot_approx, y, controls)
    Csym = getCsym(ydot_approx, y, controls)
    Dsym = getDsym(ydot_approx, y, controls)

    # Build struct
    SymbolicBilinearDynamics(n0, n, m, Asym, Bsym, Csym, Dsym, dynamics, states, controls, states0, constants, y)
end

function build_expanded_vector_function(sbd::SymbolicBilinearDynamics)
    build_expanded_vector_function(sbd.expandedstates)
end

function build_expanded_vector_function(y)
    vars = filter(x->getpow(x)==1, y)
    n0 = length(vars)
    @variables x[n0]
    # x = [Symbolics.variable(Symbol("x"), i) for i = 1:n0]

    subs = Dict(value(y[i])=>value(x[i]) for i = 1:n0)
    exprs = map(enumerate(y)) do (i,yk)
        y_ = substitute(yk, subs)
        y_expr = Symbolics.toexpr(y_)
        :(y[$i] = $y_expr) 
    end
    
    quote
        function expand!(y, x)
            $(exprs...)
            return y
        end
    end
end

function build_bilinear_dynamics_functions(sbd::SymbolicBilinearDynamics)
    build_bilinear_dynamics_functions(sbd.A, sbd.B, sbd.C, sbd.D, sbd.states0, sbd.controls)
end

function build_bilinear_dynamics_functions(Asym, Bsym, Csym, Dsym, vars0, controls)
    n0 = length(vars0)
    m = length(controls)

    # Rename states and controls to _x, _u array variables
    @variables _x0[n0] _u[m]  # use underscore to avoid potential naming conflicts
    subs = Dict{Num,Num}(value(vars0[i])=>value(_x0[i]) for i = 1:n0)
    merge!(subs, Dict(controls[i]=>_u[i] for i = 1:m))

    function genexprs(A, subs)
        map(enumerate(A.nzval)) do (i,e)
            # Substitute in new state and control variable names 
            e_sub = substitute(e, subs)

            # Convert to expression
            expr = Symbolics.toexpr(e_sub)
            :(nzval[$i] = $expr)
        end
    end
    Aexprs = genexprs(Asym, subs)
    Bexprs = genexprs(Bsym, subs)
    Cexprs = map(1:m) do i
        Cexpr = genexprs(Csym[i], subs)
        quote
            nzval = C[$i].nzval
            $(Cexpr...)
        end
    end
    Dexprs = genexprs(Dsym, subs)
    updateA! = quote
        function updateA!(A, x0)
            _x0 = x0
            # _u = u
            nzval = A.nzval
            $(Aexprs...)
            return A
        end
    end
    updateB! = quote
        function updateB!(B, x0)
            _x0 = x0
            # _u = u
            nzval = B.nzval
            $(Bexprs...)
            return B
        end
    end
    updateC! = quote
        function updateC!(C, x0)
            _x0 = x0
            # _u = u
            $(Cexprs...)
            return C
        end
    end
    updateD! = quote
        function updateD!(D, x0)
            _x0 = x0
            # _u = u
            nzval = D.nzval
            $(Dexprs...)
            return D
        end
    end
    return updateA!, updateB!, updateC!, updateD!
end

function build_bilinearsparsity_fucntions(sbd::SymbolicBilinearDynamics)
    
    Asym,Bsym,Csym,Dsym = sbd.A, sbd.B, sbd.C, sbd.D
    Cexprs = map(Csym) do Ci
        quote
            SparseMatrixCSC(n, n,
                $(Ci.colptr), 
                $(Ci.rowval),
                zeros($(nnz(Ci)))
            )
        end
    end
    Cexpr = :(C = [$(Cexprs...)])
    quote 
        function getsparsearrays()
            n = $(size(Asym, 1))
            m = $(length(Csym))
            A = SparseMatrixCSC(n, n,
                $(Asym.colptr), 
                $(Asym.rowval),
                zeros($(nnz(Asym)))
            )
            B = SparseMatrixCSC(n, m,
                $(Bsym.colptr), 
                $(Bsym.rowval),
                zeros($(nnz(Bsym)))
            )
            $Cexpr
            D = SparseMatrixCSC(n, 1,
                $(Dsym.colptr), 
                $(Dsym.rowval),
                zeros($(nnz(Dsym)))
            )
            return A,B,C,D
        end
    end
end